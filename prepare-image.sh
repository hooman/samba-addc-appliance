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
# Design rule: this script prepares an image, but it does not decide the
# domain. Anything that depends on the eventual realm, source DC, client
# subnet, or deployment role belongs in samba-sconfig.sh. That is why files
# such as krb5.conf and chrony.conf are skeletons here and are completed
# later during provision or join.
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
# This is a special-purpose AD DC appliance: LDAP, Kerberos, SMB, DNS, and
# domain time. Administration is SSH plus samba-sconfig. The package purge
# below removes general-purpose Debian extras that add attack surface, boot
# noise, or image size but do not help a VM domain controller. Keep this list
# conservative; predictable image preparation matters more than shaving every
# possible package.
log "Removing unnecessary packages to minimize image size..."

REMOVE_PKGS=(
    # Spell-check stack
    ispell iamerican ibritish ienglish-common wamerican
    dictionaries-common emacsen-common
    # Post-install / installer artifacts
    installation-report
    tasksel tasksel-data task-english
    # Multi-boot GRUB probing (useless in VM)
    os-prober
    # Laptop / desktop detection
    laptop-detect
    # Desktop-oriented hooks
    xdg-user-dirs shared-mime-info

    # Mail stack — the appliance sends no mail. apt-listchanges / mailutils
    # pull exim4 in as a Recommends, so explicitly purge the lot. The
    # unattended-upgrades install below uses --no-install-recommends to
    # keep them from sneaking back in.
    exim4 exim4-base exim4-config exim4-daemon-light
    bsd-mailx mailutils
    apt-listchanges

    # Debian community / end-user tooling that has no place on a server
    # appliance we don't hand out to end users.
    reportbug python3-reportbug
    popularity-contest
    debian-faq doc-debian

    # debconf prompts only run in English on this appliance (locale is set
    # to en_US.UTF-8 below); the ~2 MB of translation catalogs aren't used.
    debconf-i18n

    # Real-hardware bits that never apply to a VM DC.
    eject
    discover discover-data
    # Wireless — VMs don't have radios. The regulatory DB alone is ~1 MB.
    wpasupplicant wireless-regdb crda iw
    # Bluetooth
    bluez bluetooth
    # Audio
    alsa-utils pulseaudio
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
    whiptail \
    nftables \
    ldap-utils

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
# --no-install-recommends: the default Recommends are apt-listchanges (which
# drags in bsd-mailx → exim4), needrestart, powermgmt-base, python3-gi — all
# purged above or irrelevant to a headless DC. Admin can tail
# /var/log/unattended-upgrades/ directly; no mail pathway needed.
apt-get install -y --no-install-recommends unattended-upgrades

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

PWSH_INSTALLED=false

# Debian 13 (Trixie) switched apt signature verification to sqv/Sequoia, which
# rejects Microsoft's current repo metadata signature because the published
# keyring is missing the subkey used to sign it. Installing the direct GitHub
# .deb is less elegant than an apt repo, but it is deterministic in this image
# build and avoids leaving a half-configured Microsoft source behind.
rm -f /etc/apt/sources.list.d/microsoft.list /usr/share/keyrings/microsoft-archive-keyring.gpg

PWSH_VER="7.6.0"
PWSH_DEB="powershell_${PWSH_VER}-1.deb_amd64.deb"
if wget -q "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VER}/${PWSH_DEB}" -O "/tmp/${PWSH_DEB}"; then
    dpkg -i "/tmp/${PWSH_DEB}" 2>/dev/null || true
    apt-get install -f -y
    rm -f "/tmp/${PWSH_DEB}"
    if command -v pwsh &>/dev/null; then
        PWSH_INSTALLED=true
        log "PowerShell installed: $(pwsh --version 2>/dev/null)"
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
log "Stopping and disabling Samba services until samba-sconfig takes over..."
systemctl stop samba winbind nmbd smbd samba-ad-dc 2>/dev/null || true
systemctl disable samba winbind nmbd smbd samba-ad-dc 2>/dev/null || true
# Mask only the member/file-server daemons. Do NOT mask samba.service itself:
# on Debian it is also an alias path used by samba-ad-dc.service. A /dev/null
# mask there makes later `systemctl enable samba-ad-dc` look broken even after
# a successful domain provision or join.
systemctl mask winbind nmbd smbd 2>/dev/null || true

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
# Deliberately no NTP servers here. AD time has topology rules: a joined DC
# should follow the domain source, while a first DC may need to serve the
# client subnet. samba-sconfig knows which case applies; the image builder
# does not. Baking public pools into the golden image also breaks isolated labs.
cat > /etc/chrony/chrony.conf << 'CHRONEOF'
# Time sources are configured per deployment by samba-sconfig.
# Until sconfig runs, this host relies on the hypervisor time-sync service
# (hyperv-daemons / vmware-tools / qemu-guest-agent) if present.

driftfile /var/lib/chrony/drift
ntpsigndsocket /var/lib/samba/ntp_signd
makestep 1.0 3
#allow 192.168.0.0/16   # enabled by samba-sconfig after provision/join
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
#
# sysvol-sync — periodic SYSVOL replication for Samba AD DC deployments.
#
# Samba has no native DFSR, so ongoing /var/lib/samba/sysvol replication
# is this script's responsibility. Two transports are supported:
#
#   ssh: rsync-over-SSH. Samba ↔ Samba only (Windows DCs typically have no
#        sshd). Primary runs SYNC_ROLE=push, replicas run SYNC_ROLE=pull.
#   smb: smbclient pull from //REMOTE_DC/sysvol. Pull-only; works against
#        Windows or Samba. Not usable for pushing INTO a Windows DC —
#        DFSR owns the source of truth on the Windows side.
#
# Configuration lives in /etc/samba/sysvol-sync.conf (written by
# samba-sconfig). This script intentionally never prompts and never writes that
# file, so it is safe to run from cron/systemd and easy for tests to reason
# about.

set -u -o pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

CONF="/etc/samba/sysvol-sync.conf"
LOCKFILE="/run/sysvol-sync.lock"
LOGFILE="/var/log/samba/sysvol-sync.log"

[[ -f "$CONF" ]] || { echo "ERROR: $CONF not found. Run samba-sconfig." >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

mkdir -p "$(dirname "$LOGFILE")"
log()   { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }
fatal() { log "ERROR: $*"; exit 1; }

exec 200>"$LOCKFILE"
if ! flock -n 200; then
    log "skip: another sysvol-sync is already running"
    exit 0
fi

: "${SYNC_TRANSPORT:=ssh}"
: "${REMOTE_DC:?REMOTE_DC not set in $CONF}"

log "start: transport=${SYNC_TRANSPORT} remote=${REMOTE_DC}"

case "$SYNC_TRANSPORT" in
    ssh)
        : "${SYNC_ROLE:=pull}"
        : "${REMOTE_USER:?REMOTE_USER not set in $CONF}"
        : "${SSH_KEY:?SSH_KEY not set in $CONF}"
        [[ -f "$SSH_KEY" ]] || fatal "SSH key $SSH_KEY does not exist; re-run samba-sconfig"

        ssh_cmd="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o BatchMode=yes"
        case "$SYNC_ROLE" in
            pull)
                if rsync -avz --delete --max-delete=100 \
                        -e "$ssh_cmd" \
                        "${REMOTE_USER}@${REMOTE_DC}:/var/lib/samba/sysvol/" \
                        "/var/lib/samba/sysvol/" \
                        --exclude='*.tmp' >> "$LOGFILE" 2>&1; then
                    log "rsync pull OK"
                else
                    log "WARN: rsync pull returned $? (partial or transient failure)"
                fi
                ;;
            push)
                if rsync -avz --delete --max-delete=100 \
                        -e "$ssh_cmd" \
                        "/var/lib/samba/sysvol/" \
                        "${REMOTE_USER}@${REMOTE_DC}:/var/lib/samba/sysvol/" \
                        --exclude='*.tmp' >> "$LOGFILE" 2>&1; then
                    log "rsync push OK"
                else
                    log "WARN: rsync push returned $? (partial or transient failure)"
                fi
                ;;
            *) fatal "unknown SYNC_ROLE '$SYNC_ROLE' (expected: pull|push)" ;;
        esac
        ;;

    smb)
        : "${SMB_CRED_FILE:?SMB_CRED_FILE not set in $CONF}"
        [[ -f "$SMB_CRED_FILE" ]] || fatal "credentials file $SMB_CRED_FILE is missing"

        realm_lower=$(awk -F= '
            /^[[:space:]]*realm[[:space:]]*=/ {
                sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2)
                print tolower($2); exit
            }' /etc/samba/smb.conf)
        [[ -n "$realm_lower" ]] || fatal "could not determine realm from /etc/samba/smb.conf"

        tmpdir=$(mktemp -d)
        trap 'rm -rf "$tmpdir"' EXIT

        # mget preserves file content; NTACLs are NOT carried over SMB in a
        # form Samba's on-disk xattrs can consume. sysvolreset below rebuilds
        # them from AD, so that's the source of truth.
        if smbclient "//${REMOTE_DC}/sysvol" -A "$SMB_CRED_FILE" \
                -c "recurse ON; prompt OFF; lcd ${tmpdir}; mget ${realm_lower}" \
                >> "$LOGFILE" 2>&1; then

            if [[ -d "${tmpdir}/${realm_lower}" ]]; then
                mkdir -p "/var/lib/samba/sysvol/${realm_lower}"
                if rsync -a --delete --max-delete=100 \
                        "${tmpdir}/${realm_lower}/" \
                        "/var/lib/samba/sysvol/${realm_lower}/" \
                        >> "$LOGFILE" 2>&1; then
                    log "smb pull OK from //${REMOTE_DC}/sysvol/${realm_lower}"
                else
                    log "WARN: local rsync returned $? after smb pull"
                fi
            else
                fatal "smbclient mget produced no ${realm_lower}/ under ${tmpdir}"
            fi
        else
            fatal "smbclient pull from //${REMOTE_DC}/sysvol failed"
        fi
        ;;

    *) fatal "unknown SYNC_TRANSPORT '$SYNC_TRANSPORT' (expected: ssh|smb)" ;;
esac

# Always re-derive NTACLs from AD so foreign SIDs / renamed principals in
# copied GPOs resolve correctly. This is the same call samba-sconfig's
# "Reset SYSVOL ACLs" menu item makes.
if ! samba-tool ntacl sysvolreset >> "$LOGFILE" 2>&1; then
    log "WARN: samba-tool ntacl sysvolreset failed"
fi

log "sync completed"
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
