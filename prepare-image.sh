#!/usr/bin/env bash
#===============================================================================
# prepare-image.sh — Samba AD DC Appliance Image Preparation
#
# Run ONCE on a fresh Debian 13 (Trixie) minimal install to:
#   - Remove unnecessary packages (spell check, X11, laptop detection, etc.)
#   - Install Samba AD DC, Kerberos, Chrony, PowerShell, and tooling
#   - Conditionally install VM guest agents (QEMU, VMware, Hyper-V)
#   - Pre-configure skeleton files for samba-sconfig deployment
#   - Install the unattended-upgrades framework (policy set by sconfig)
#
# After running, snapshot the VM. Use samba-sconfig for per-deployment config.
#
# Usage: sudo bash prepare-image.sh
#===============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

#===============================================================================
# 1. REMOVE UNNECESSARY PACKAGES
#===============================================================================
log "Removing unnecessary packages to minimize image size..."

REMOVE_PKGS=(
    # Spell-check stack
    ispell iamerican ibritish ienglish-common wamerican
    dictionaries-common emacsen-common
    # Post-install tools
    installation-report
    # Laptop/desktop detection
    laptop-detect
    # Multi-boot GRUB probing (useless in VM)
    os-prober
    # Task metapackages (only used during install)
    task-english tasksel tasksel-data
    # Desktop-oriented packages
    xdg-user-dirs shared-mime-info
)

for pkg in "${REMOVE_PKGS[@]}"; do
    if dpkg -l "$pkg" &>/dev/null 2>&1; then
        apt-get purge -y "$pkg" 2>/dev/null || true
    fi
done

apt-get autoremove -y --purge
apt-get clean
log "Package cleanup complete."

#===============================================================================
# 2. DETECT HYPERVISOR AND INSTALL GUEST AGENT
#===============================================================================
log "Detecting virtualization environment..."

VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "none")
log "  Detected: ${VIRT_TYPE}"

case "$VIRT_TYPE" in
    kvm|qemu)
        log "  Installing qemu-guest-agent..."
        apt-get install -y qemu-guest-agent
        systemctl enable qemu-guest-agent
        ;;
    vmware)
        log "  Installing open-vm-tools..."
        apt-get install -y open-vm-tools
        systemctl enable open-vm-tools
        ;;
    microsoft)
        log "  Installing Hyper-V guest daemons..."
        apt-get install -y hyperv-daemons
        ;;
    oracle)
        log "  VirtualBox detected. Install Guest Additions manually if needed."
        ;;
    none|*)
        warn "  No recognized hypervisor (bare metal or unknown). Skipping guest agent."
        ;;
esac

#===============================================================================
# 3. SYSTEM UPDATE
#===============================================================================
log "Updating package index and upgrading system..."
apt-get update -y
apt-get upgrade -y

#===============================================================================
# 4. BASE TOOLS (replaces manual post-install steps)
#===============================================================================
log "Installing base administration tools..."
apt-get install -y \
    sudo \
    nano \
    iputils-ping \
    net-tools \
    dnsutils \
    wget \
    curl \
    htop \
    tree \
    rsync \
    bash-completion \
    locales-all \
    whiptail

#===============================================================================
# 5. SAMBA AD DC PACKAGES
#===============================================================================
log "Installing Samba AD DC packages and dependencies..."
apt-get install -y \
    samba \
    samba-ad-dc \
    winbind \
    libnss-winbind \
    libpam-winbind \
    krb5-user \
    smbclient \
    ldb-tools \
    python3-cryptography \
    acl \
    attr

#===============================================================================
# 6. CHRONY NTP
#===============================================================================
log "Installing Chrony..."
apt-get install -y chrony

#===============================================================================
# 7. UNATTENDED-UPGRADES FRAMEWORK
#===============================================================================
log "Installing unattended-upgrades framework..."
apt-get install -y unattended-upgrades apt-listchanges

# Default to disabled — sconfig sets the policy per deployment
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'UAEOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "7";
UAEOF

#===============================================================================
# 8. POWERSHELL
#===============================================================================
log "Installing Microsoft PowerShell..."

curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor -o /usr/share/keyrings/microsoft-archive-keyring.gpg

echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/debian/13/prod trixie main" \
    > /etc/apt/sources.list.d/microsoft.list

apt-get update -y

PWSH_INSTALLED=false
if apt-get install -y powershell 2>/dev/null; then
    PWSH_INSTALLED=true
    log "PowerShell installed: $(pwsh --version 2>/dev/null)"
else
    warn "Repo install failed. Trying direct .deb download..."
    PWSH_VER="7.6.0"
    PWSH_DEB="powershell_${PWSH_VER}-1.deb_amd64.deb"
    if wget -q "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VER}/${PWSH_DEB}" -O "/tmp/${PWSH_DEB}"; then
        dpkg -i "/tmp/${PWSH_DEB}" 2>/dev/null || true
        apt-get install -f -y
        rm -f "/tmp/${PWSH_DEB}"
        command -v pwsh &>/dev/null && PWSH_INSTALLED=true
    fi
fi

if $PWSH_INSTALLED; then
    log "Configuring PowerShell SSH remoting subsystem..."
    SSHD_CONF="/etc/ssh/sshd_config"
    PWSH_PATH=$(command -v pwsh 2>/dev/null || echo "/usr/bin/pwsh")

    if ! grep -q 'Subsystem.*powershell' "$SSHD_CONF" 2>/dev/null; then
        echo "" >> "$SSHD_CONF"
        echo "# PowerShell SSH Remoting — added by prepare-image.sh" >> "$SSHD_CONF"
        echo "Subsystem powershell ${PWSH_PATH} -sshs -NoLogo -NoProfile" >> "$SSHD_CONF"
        log "  Added PowerShell subsystem to sshd_config"
    fi
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
else
    warn "PowerShell installation failed. Non-critical — install manually later."
fi

#===============================================================================
# 9. SET LOCALE
#===============================================================================
log "Setting system locale to en_US.UTF-8..."
update-locale LANG=en_US.UTF-8
export LANG=en_US.UTF-8

#===============================================================================
# 10. DISABLE AVAHI / mDNS
#===============================================================================
if systemctl is-enabled avahi-daemon.service &>/dev/null 2>&1; then
    log "Disabling avahi-daemon..."
    systemctl stop avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
    systemctl disable avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
fi

#===============================================================================
# 11. DISABLE SYSTEMD-RESOLVED
#===============================================================================
if systemctl is-active systemd-resolved &>/dev/null 2>&1; then
    log "Disabling systemd-resolved..."
    systemctl disable --now systemd-resolved
    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
        echo "nameserver 1.1.1.1" > /etc/resolv.conf
    fi
fi

#===============================================================================
# 12. MASK SAMBA FILE-SERVER SERVICES
#===============================================================================
log "Stopping and masking Samba file-server services..."
systemctl stop samba winbind nmbd smbd samba-ad-dc 2>/dev/null || true
systemctl disable samba winbind nmbd smbd samba-ad-dc 2>/dev/null || true
systemctl mask samba winbind nmbd smbd 2>/dev/null || true

#===============================================================================
# 13. REMOVE DEFAULT SMB.CONF
#===============================================================================
log "Removing default smb.conf..."
rm -f /etc/samba/smb.conf

#===============================================================================
# 14. SKELETON KRB5.CONF
#===============================================================================
log "Writing skeleton krb5.conf..."
cat > /etc/krb5.conf << 'KRBEOF'
[libdefaults]
  default_realm = YOURREALM.LAN
  dns_lookup_kdc = true
  dns_lookup_realm = false
KRBEOF

#===============================================================================
# 15. SKELETON CHRONY.CONF
#===============================================================================
log "Writing chrony skeleton..."
cat > /etc/chrony/chrony.conf << 'CHRONEOF'
server time.cloudflare.com iburst
server time.google.com iburst
pool 2.debian.pool.ntp.org iburst
driftfile /var/lib/chrony/drift
#allow 192.168.0.0/16
ntpsigndsocket /var/lib/samba/ntp_signd
makestep 1.0 3
CHRONEOF

#===============================================================================
# 16. BACKUP NSSWITCH.CONF
#===============================================================================
log "Backing up nsswitch.conf..."
cp /etc/nsswitch.conf /etc/nsswitch.conf.orig

#===============================================================================
# 17. NTP SIGNING SOCKET DIRECTORY
#===============================================================================
log "Creating NTP signing socket directory..."
mkdir -p /var/lib/samba/ntp_signd
chown root:_chrony /var/lib/samba/ntp_signd 2>/dev/null || \
chown root:chrony /var/lib/samba/ntp_signd 2>/dev/null || true
chmod 750 /var/lib/samba/ntp_signd

#===============================================================================
# 18. INSTALL SAMBA-SCONFIG
#===============================================================================
log "Installing samba-sconfig tool..."
for src in /root/samba-sconfig.sh /root/samba-sconfig; do
    if [[ -f "$src" ]]; then
        cp "$src" /usr/local/sbin/samba-sconfig
        chmod +x /usr/local/sbin/samba-sconfig
        log "  Installed from $src to /usr/local/sbin/samba-sconfig"
        break
    fi
done
[[ -x /usr/local/sbin/samba-sconfig ]] || warn "samba-sconfig not found — copy it manually to /usr/local/sbin/"

grep -q 'samba-sconfig' /root/.bashrc 2>/dev/null || \
    echo 'alias sconfig="sudo samba-sconfig"' >> /root/.bashrc

#===============================================================================
# 19. MOTD BANNER
#===============================================================================
log "Setting login banner..."
cat > /etc/motd << 'MOTDEOF'

  ╔═══════════════════════════════════════════════════════╗
  ║        Samba Active Directory Domain Controller       ║
  ║              Debian 13 (Trixie) Appliance             ║
  ╠═══════════════════════════════════════════════════════╣
  ║  Run 'sudo samba-sconfig' to configure this server.   ║
  ╚═══════════════════════════════════════════════════════╝

MOTDEOF

#===============================================================================
# 20. NFTABLES FIREWALL RULESET (inactive)
#===============================================================================
log "Writing AD DC firewall ruleset (inactive)..."
cat > /etc/nftables-samba-addc.conf << 'NFTEOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept
        tcp dport 22 accept
        tcp dport 53 accept
        udp dport 53 accept
        tcp dport 88 accept
        udp dport 88 accept
        udp dport 123 accept
        tcp dport 135 accept
        tcp dport 139 accept
        tcp dport 389 accept
        udp dport 389 accept
        tcp dport 445 accept
        tcp dport 464 accept
        udp dport 464 accept
        tcp dport 636 accept
        tcp dport { 3268, 3269 } accept
        tcp dport 49152-65535 accept
        log prefix "nft-drop: " limit rate 5/minute
        drop
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output priority 0; policy accept; }
}
NFTEOF

#===============================================================================
# 21. SYSVOL-SYNC HELPER
#===============================================================================
log "Installing sysvol-sync helper..."
cat > /usr/local/sbin/sysvol-sync << 'SYNCEOF'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/samba/sysvol-sync.conf"
[[ -f "$CONF" ]] || { echo "ERROR: $CONF not found. Run samba-sconfig." >&2; exit 1; }
source "$CONF"
LOCKFILE="/var/run/sysvol-sync.lock"
LOGFILE="/var/log/samba/sysvol-sync.log"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "$(date): Sync already running." >> "$LOGFILE"; exit 0; }
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }
log "Starting SYSVOL sync (role=${SYNC_ROLE:-pull})..."
case "${SYNC_ROLE:-pull}" in
    pull)
        rsync -avz --delete -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no" \
            "${REMOTE_USER}@${REMOTE_DC}:/var/lib/samba/sysvol/" \
            "/var/lib/samba/sysvol/" --exclude='*.tmp' >> "$LOGFILE" 2>&1 ;;
    push)
        rsync -avz --delete -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no" \
            "/var/lib/samba/sysvol/" \
            "${REMOTE_USER}@${REMOTE_DC}:/var/lib/samba/sysvol/" \
            --exclude='*.tmp' >> "$LOGFILE" 2>&1 ;;
esac
samba-tool ntacl sysvolreset 2>> "$LOGFILE" || true
log "SYSVOL sync completed."
SYNCEOF
chmod +x /usr/local/sbin/sysvol-sync

#===============================================================================
# 22. FINAL CLEANUP
#===============================================================================
log "Final cleanup..."
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/*
journalctl --vacuum-size=10M 2>/dev/null || true

unset DEBIAN_FRONTEND

#===============================================================================
# SUMMARY
#===============================================================================
echo ""
log "=========================================="
log " Image preparation complete."
log "=========================================="
echo ""
echo "  Hypervisor:   ${VIRT_TYPE}"
echo "  Samba:        $(samba --version 2>/dev/null || echo 'check manually')"
echo "  PowerShell:   $(pwsh --version 2>/dev/null || echo 'not installed')"
echo "  Chrony:       $(chronyc --version 2>/dev/null || echo 'check manually')"
echo ""
echo "  Removed:      ${REMOVE_PKGS[*]}"
echo ""
echo "  Next steps:"
echo "    1. Verify: /usr/local/sbin/samba-sconfig exists"
echo "    2. Shut down and snapshot this VM as 'golden-image'"
echo "    3. On deployment, run: sudo samba-sconfig"
echo ""
