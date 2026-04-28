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
# 0. REFRESH APT INDEXES
#===============================================================================
# Debian cloud images ship with /var/lib/apt/lists/ cleaned to keep the image
# small. Without an `apt-get update` first, any subsequent `apt-get install`
# of a package that wasn't in the build-time index — for example the
# hyperv-daemons install in section 2 — fails with "Unable to locate
# package". Section 3 also runs apt-get update + upgrade; the redundant
# update there is a no-op and not worth removing.
log "Refreshing apt indexes..."
apt-get update -y

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
# 2. PRE-DOWNLOAD GUEST AGENTS (no install)
#===============================================================================
# This image is host-agnostic: the same prepared snapshot must work on Hyper-V,
# KVM/QEMU, or VMware regardless of where it was mastered. Detecting the
# hypervisor here and installing only the matching agent would lock the image
# to that environment.
#
# Instead, pre-download a self-contained .deb bundle for each supported
# hypervisor into /var/cache/samba-appliance/vmtools/<pkg>/. At the deployed
# VM's first boot, samba-firstboot.service detects the actual hypervisor and
# does an offline `dpkg -i` from the matching cache directory, then deletes
# the rest. This works even if the deployment-side NIC isn't yet recognized,
# because no internet access is required at first boot.
#
# Manifest: /var/cache/samba-appliance/vmtools/manifest maps systemd-detect-virt
# return values to package names. Single source of truth for the firstboot
# script.
log "Pre-downloading guest agents and cloud helpers for all supported targets..."

VMTOOLS_CACHE="/var/cache/samba-appliance/vmtools"
mkdir -p "$VMTOOLS_CACHE"

# Per-virt package set installed by samba-firstboot when that virt-type is
# detected. Each value is a space-separated list. Everything below is in
# Debian's main archive and DFSG-free — freely redistributable.
#
# Notes on what's NOT pre-staged and why:
#   - virtualbox-guest-utils ships in contrib, not main, so the cloud
#     image's sources don't carry it. VirtualBox deployments can install
#     it manually after enabling contrib.
#   - walinuxagent isn't in Trixie main; modern Azure setups use cloud-init
#     for the things walinuxagent used to handle, so we just install
#     cloud-init on Azure.
#   - xe-guest-utilities isn't in Trixie main either; a kernel-level Xen
#     guest works without it.
declare -A VIRT_PKGS=(
    ["amazon"]="qemu-guest-agent cloud-init cloud-guest-utils"
    ["kvm"]="qemu-guest-agent cloud-guest-utils"
    ["qemu"]="qemu-guest-agent cloud-guest-utils"
    ["microsoft"]="hyperv-daemons cloud-guest-utils"
    ["vmware"]="open-vm-tools cloud-guest-utils"
    ["oracle"]="cloud-guest-utils"
    ["xen"]="qemu-guest-agent cloud-guest-utils"
)

# samba-firstboot may augment the install list dynamically based on DMI
# probes (e.g. add cloud-init when the chassis-asset-tag identifies Azure
# inside an otherwise generic 'microsoft' virt-type). Anything that may
# be promoted that way needs to be in the cache regardless of the static
# manifest, so we pre-fetch it as an extra here.
EXTRA_DOWNLOADS="cloud-init"

# Union of every package across every virt + the extras — what we actually
# need to fetch. Per-package directories give samba-firstboot a clean
# "install just this package's cache" target.
declare -A PKGS_SEEN
for virt in "${!VIRT_PKGS[@]}"; do
    for pkg in ${VIRT_PKGS[$virt]}; do
        PKGS_SEEN[$pkg]=1
    done
done
for pkg in $EXTRA_DOWNLOADS; do
    PKGS_SEEN[$pkg]=1
done

for pkg in "${!PKGS_SEEN[@]}"; do
    dest="$VMTOOLS_CACHE/$pkg"
    mkdir -p "$dest/partial"
    log "  pre-download $pkg -> $dest"
    # --download-only puts .debs in Dir::Cache::archives without installing.
    # --reinstall forces a re-download even when the package is already on
    # the prepared image (cloud-guest-utils is shipped on the Debian cloud
    # base; without --reinstall apt would say "nothing to do" and leave
    # us with an empty cache). --no-install-recommends keeps each bundle
    # small.
    if ! apt-get install -y --download-only --reinstall --no-install-recommends \
            -o "Dir::Cache::archives=$dest" \
            "$pkg" 2>&1 | tail -3; then
        warn "    WARN: download of $pkg failed (not in Debian main on this release; skipping)"
    fi
    rm -rf "$dest/partial"
done

# Manifest in a stable format the firstboot script can read.
{
    echo "# samba-appliance guest-agent / cloud-helper manifest"
    echo "# format: systemd-detect-virt-value=space-separated-package-list"
    echo "# (samba-firstboot may augment this list dynamically — e.g. on Azure)"
    for virt in "${!VIRT_PKGS[@]}"; do
        printf '%s=%s\n' "$virt" "${VIRT_PKGS[$virt]}"
    done | sort
} > "$VMTOOLS_CACHE/manifest"

log "  staged cache (per-package):"
du -sh "$VMTOOLS_CACHE"/* 2>/dev/null | sed 's|^|    |'

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
# sysvol-sync — multi-source, version-aware SYSVOL puller for Samba DCs.
#
# Samba doesn't implement DFSR. This helper keeps /var/lib/samba/sysvol/
# converged with peers (Windows or Samba) by, on each cycle:
#
#   1. discovering all DCs in the forest from the local Samba SAM
#      (objectClass=server under CN=Sites,CN=Configuration);
#   2. classifying each peer Windows vs Samba via the computer object's
#      operatingSystem attribute (Windows DCs get tier 1, Samba peers tier 2);
#   3. probing TCP/445 reachability with a short timeout — unreachable peers
#      are silently skipped, so a multi-day outage of any single DC is fine;
#   4. enumerating local GPOs (objectClass=groupPolicyContainer) and, for
#      each one whose on-disk GPT.INI Version is behind its AD versionNumber,
#      asking each candidate (highest tier first) whether IT has the version
#      we need AND its own LDAP versionNumber matches its on-disk GPT.INI
#      (settled, no DFSR mid-flight). The first peer that answers yes is
#      used as the source.
#   5. The chosen GPO is pulled into a staging tmpdir and rsync'd into place
#      atomically per-GPO, then `samba-tool ntacl sysvolreset` is run once at
#      the end if any GPO actually changed.
#
# Authentication uses smbclient -P (Privileged), which makes Samba's own
# tooling pick up this DC's machine credentials directly from
# /var/lib/samba/private/secrets.tdb. No admin password on disk, no separate
# keytab to manage, no kinit dance — Samba's machine identity is the same
# identity that AD already trusts for replication.
#
# Configuration: /etc/samba/sysvol-sync.conf  (managed by samba-sconfig)
#   PREFERRED_DCS=""    optional, space-separated FQDNs to try first (tier 0)
#   EXCLUDE_DCS=""      optional, space-separated FQDNs to never use as a source
#   SYNC_INTERVAL=15    minutes between cron firings (consumed by samba-sconfig)
#
# CLI:
#   sysvol-sync                  one normal sync cycle (the cron entrypoint)
#   sysvol-sync --status         print a freshness table; do not pull anything

set -u -o pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

CONF="/etc/samba/sysvol-sync.conf"
LOCKFILE="/run/sysvol-sync.lock"
LOGFILE="/var/log/samba/sysvol-sync.log"
SAMDB="/var/lib/samba/private/sam.ldb"
SMBCONF="/etc/samba/smb.conf"

MODE="${1:-sync}"   # sync (default) | --status

mkdir -p "$(dirname "$LOGFILE")"

if [[ "$MODE" == "--status" ]]; then
    say() { printf '%s\n' "$*"; }
else
    say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }
fi
fatal() { say "ERROR: $*"; exit 1; }

[[ -f "$SMBCONF" ]] || fatal "smb.conf not found"
[[ -f "$SAMDB"   ]] || fatal "Samba SAM not found at $SAMDB (DC not provisioned?)"
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF" || true   # config is optional; defaults are fine

PREFERRED_DCS="${PREFERRED_DCS:-}"
EXCLUDE_DCS="${EXCLUDE_DCS:-}"

# Single-instance lock for the sync mode; --status is read-only and skipped.
if [[ "$MODE" == "sync" ]]; then
    exec 200>"$LOCKFILE"
    flock -n 200 || { say "skip: another sysvol-sync is already running"; exit 0; }
fi

# --- environment from smb.conf -------------------------------------------------
read_smbconf_param() {
    awk -v key="$1" -F= '
        $1 ~ "^[[:space:]]*"key"[[:space:]]*$" {
            sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2)
            print $2; exit
        }
    ' "$SMBCONF"
}

REALM=$(read_smbconf_param "realm")
[[ -n "$REALM" ]] || fatal "could not read 'realm' from $SMBCONF"
REALM="${REALM^^}"
REALM_LC="${REALM,,}"
BASE_DN="DC=${REALM_LC//./,DC=}"

NETBIOS_SELF=$(read_smbconf_param "netbios name")
[[ -z "$NETBIOS_SELF" ]] && NETBIOS_SELF="$(hostname -s)"
NETBIOS_SELF="${NETBIOS_SELF^^}"

say "start: realm=$REALM self=$NETBIOS_SELF mode=$MODE"

# --- helpers ------------------------------------------------------------------
ldb() { ldbsearch -H "$SAMDB" "$@" 2>/dev/null; }

# Parse Version= out of a GPT.INI file. Echoes 0 if file missing or malformed.
parse_gpt_ini_version() {
    local ini="$1"
    [[ -f "$ini" ]] || { echo 0; return; }
    local v
    v=$(awk -F= 'tolower($1) ~ /^[[:space:]]*version[[:space:]]*$/ {
                     gsub(/[[:space:]\r]/, "", $2); print $2; exit }' "$ini")
    [[ -n "$v" ]] || v=0
    echo "$v"
}

# Read the local GPT.INI Version for a GPO directory. GPT.INI casing varies
# across GPO authoring tools — Windows serves the file case-insensitively
# over SMB, but Samba stores whichever case the original writer used.
read_local_gpt_version() {
    local dir="$1"          # /var/lib/samba/sysvol/<realm>/Policies/{GUID}
    for cand in "$dir/GPT.INI" "$dir/gpt.ini" "$dir/Gpt.ini"; do
        [[ -f "$cand" ]] && { parse_gpt_ini_version "$cand"; return; }
    done
    echo 0
}

# Pull a single file from a peer's sysvol share into a local destination.
# -P (Privileged) tells Samba's smbclient to authenticate using the local
# DC's machine credentials directly from secrets.tdb, no kinit / keytab /
# password file needed.
fetch_one_file() {
    local fqdn="$1" remote="$2" out="$3"
    smbclient "//${fqdn}/sysvol" -P --quiet \
        -c "get \"$remote\" \"$out\"" >/dev/null 2>&1
}

# Settled GPT version on a peer for a given GUID. Echoes -1 on any error.
# Probes both common GPT.INI casings (the SMB server normalizes case, but
# we don't know which spelling the file was actually written under until we
# ask — and `get GPT.INI` will only succeed for the actual stored name).
fetch_remote_gpt_version() {
    local fqdn="$1" guid="$2" tmp
    tmp=$(mktemp /tmp/gpt-probe-XXXXXX.ini)
    local got=0
    for fname in GPT.INI gpt.ini Gpt.ini; do
        if fetch_one_file "$fqdn" "$REALM_LC/Policies/$guid/$fname" "$tmp"; then
            got=1
            break
        fi
    done
    if [[ $got -eq 1 ]]; then
        parse_gpt_ini_version "$tmp"
    else
        echo "-1"
    fi
    rm -f "$tmp"
}

# TCP probe with a short timeout. /dev/tcp on bash is enough; we don't need nc.
probe_reachable() {
    timeout 2 bash -c "exec 9<>/dev/tcp/$1/445" >/dev/null 2>&1
}

# --- enumerate GPOs (local SAM, no network needed) ----------------------------
declare -A target_versions
while IFS=$'\t' read -r guid ver; do
    [[ -z "$guid" ]] && continue
    target_versions["$guid"]="$ver"
done < <(
    ldb -b "CN=Policies,CN=System,${BASE_DN}" \
        "(objectClass=groupPolicyContainer)" cn versionNumber \
    | awk '
        function reset() { cn=""; ver="" }
        BEGIN { reset() }
        /^[Dd][Nn]:/ { reset(); next }
        /^[^:]+:[[:space:]]/ {
            ix = index($0, ":")
            attr = tolower(substr($0, 1, ix - 1))
            val  = substr($0, ix + 2)
            if      (attr == "cn")            cn  = val
            else if (attr == "versionnumber") ver = val
            next
        }
        /^$/ {
            if (cn != "" && ver != "") printf "%s\t%s\n", cn, ver
            reset()
        }
        END { if (cn != "" && ver != "") printf "%s\t%s\n", cn, ver }
    '
)

# --- --status mode: print freshness table, no remote network calls -----------
if [[ "$MODE" == "--status" ]]; then
    printf '\n%-40s %10s %10s %s\n' "GPO GUID" "local" "AD" "status"
    printf -- '-%.0s' {1..78}; printf '\n'
    for guid in "${!target_versions[@]}"; do
        target_ver="${target_versions[$guid]}"
        local_ver=$(read_local_gpt_version "/var/lib/samba/sysvol/$REALM_LC/Policies/$guid")
        if [[ "$local_ver" -ge "$target_ver" ]]; then
            status="current"
        elif [[ "$local_ver" -eq 0 ]]; then
            status="MISSING"
        else
            status="STALE (-$((target_ver - local_ver)))"
        fi
        printf '%-40s %10s %10s %s\n' "$guid" "$local_ver" "$target_ver" "$status"
    done
    # Orphan section (local dirs with no AD object).
    if [[ -d "/var/lib/samba/sysvol/$REALM_LC/Policies" ]]; then
        for d in "/var/lib/samba/sysvol/$REALM_LC/Policies/"*/; do
            [[ -d "$d" ]] || continue
            bn=$(basename "$d")
            [[ "$bn" =~ ^\{.*\}$ ]] || continue
            [[ -z "${target_versions[$bn]+set}" ]] || continue
            printf '%-40s %10s %10s %s\n' "$bn" "?" "?" "ORPHAN"
        done
    fi
    exit 0
fi

# --- discover candidate peers (sync mode only) --------------------------------
candidates_raw=()
while IFS=$'\t' read -r tier fqdn; do
    [[ -z "$fqdn" ]] && continue
    candidates_raw+=("${tier}|${fqdn}")
done < <(
    ldb -b "CN=Sites,CN=Configuration,${BASE_DN}" \
        "(objectClass=server)" cn dnsHostName serverReference \
    | awk -v self="$NETBIOS_SELF" '
        # LDAP attribute names are case-insensitive; ldbsearch echoes them
        # in whatever case the schema declared. Normalize the attribute name
        # to lower case for matching, then take the value verbatim.
        function reset() { cn=""; fqdn=""; ref="" }
        BEGIN { reset() }
        /^[Dd][Nn]:/ { reset(); next }
        /^[^:]+:[[:space:]]/ {
            ix = index($0, ":")
            attr = tolower(substr($0, 1, ix - 1))
            val  = substr($0, ix + 2)
            if      (attr == "cn")              cn   = val
            else if (attr == "dnshostname")     fqdn = val
            else if (attr == "serverreference") ref  = val
            next
        }
        /^$/ {
            if (cn != "" && fqdn != "" && toupper(cn) != self)
                printf "%s\t%s\t%s\n", cn, fqdn, ref
            reset()
        }
        END {
            if (cn != "" && fqdn != "" && toupper(cn) != self)
                printf "%s\t%s\t%s\n", cn, fqdn, ref
        }
    ' \
    | while IFS=$'\t' read -r cn fqdn ref; do
        os=$(ldb -b "$ref" "(objectClass=computer)" operatingSystem \
              | awk 'BEGIN{IGNORECASE=1}
                     /^operatingSystem:[[:space:]]/ {
                         ix = index($0, ":")
                         val = substr($0, ix + 2)
                         sub(/\r$/, "", val)
                         print val; exit
                     }')
        case "$os" in
            *Samba*)   tier=2 ;;
            *Windows*) tier=1 ;;
            *)         tier=3 ;;
        esac
        skip=0
        for excl in $EXCLUDE_DCS; do
            [[ "${fqdn,,}" == "${excl,,}" ]] && skip=1
        done
        [[ $skip -eq 1 ]] && continue
        for pref in $PREFERRED_DCS; do
            [[ "${fqdn,,}" == "${pref,,}" ]] && tier=0
        done
        printf '%d\t%s\n' "$tier" "$fqdn"
    done \
    | sort -k1,1n -k2,2
)

candidates=()
for entry in "${candidates_raw[@]}"; do
    tier="${entry%%|*}"
    fqdn="${entry#*|}"
    if probe_reachable "$fqdn"; then
        candidates+=("${tier}|${fqdn}")
        say "candidate: tier=$tier $fqdn (reachable)"
    else
        say "candidate: tier=$tier $fqdn (unreachable, skipped)"
    fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
    say "no DCs reachable; nothing to do"
    exit 0
fi

# --- pull loop ----------------------------------------------------------------
new_count=0
update_count=0
delete_count=0
skip_count=0
no_source_count=0
any_pulled=0

# Orphan cleanup: local GPO dirs with no matching AD object.
if [[ -d "/var/lib/samba/sysvol/$REALM_LC/Policies" ]]; then
    for d in "/var/lib/samba/sysvol/$REALM_LC/Policies/"*/; do
        [[ -d "$d" ]] || continue
        bn=$(basename "$d")
        [[ "$bn" =~ ^\{.*\}$ ]] || continue
        if [[ -z "${target_versions[$bn]+set}" ]]; then
            say "delete orphan: $bn (no AD object)"
            rm -rf "$d"
            delete_count=$((delete_count + 1))
            any_pulled=1
        fi
    done
fi

for guid in "${!target_versions[@]}"; do
    target_ver="${target_versions[$guid]}"
    local_ver=$(read_local_gpt_version "/var/lib/samba/sysvol/$REALM_LC/Policies/$guid")

    if [[ "$local_ver" -ge "$target_ver" ]]; then
        skip_count=$((skip_count + 1))
        continue
    fi

    say "GPO $guid: local v$local_ver < target v$target_ver"

    chosen_fqdn=""
    chosen_ver=""
    for entry in "${candidates[@]}"; do
        fqdn="${entry#*|}"
        remote_gpt=$(fetch_remote_gpt_version "$fqdn" "$guid")
        # Settled-version gate: any peer that already has GPT version >=
        # what we want has definitionally finished writing it. DFSR (Windows)
        # and this script's own stage-then-swap (Samba peers) both update
        # the GPT.INI Version *after* the on-disk files settle, so seeing
        # remote_gpt >= target_ver is enough to know the peer's content is
        # internally consistent. No need to cross-check the peer's LDAP.
        if [[ "$remote_gpt" -lt "$target_ver" ]]; then
            say "  $fqdn: GPT v$remote_gpt < target v$target_ver, skip"
            continue
        fi
        chosen_fqdn="$fqdn"
        chosen_ver="$remote_gpt"
        break
    done

    if [[ -z "$chosen_fqdn" ]]; then
        say "GPO $guid: no peer has settled v$target_ver yet"
        no_source_count=$((no_source_count + 1))
        continue
    fi

    # Stage-then-swap: never leave the live tree half-written.
    # smbclient mget needs to be `cd <parent>; mget <name>` — passing a
    # path-with-slashes to mget directly produces a silent rc=0 with no
    # files. Use the `cd` form, which mirrors the directory tree under
    # $stage/<guid>/, then rsync that into place.
    stage=$(mktemp -d /tmp/sysvol-stage.XXXXXX)
    if smbclient "//${chosen_fqdn}/sysvol" -P --quiet \
            -c "recurse ON; prompt OFF; cd $REALM_LC/Policies; lcd $stage; mget $guid" \
            >>"$LOGFILE" 2>&1 \
        && [[ -d "$stage/$guid" ]]; then

        dst="/var/lib/samba/sysvol/$REALM_LC/Policies/$guid"
        mkdir -p "$dst"
        if rsync -a --delete --max-delete=100 \
                "$stage/$guid/" "$dst/" >>"$LOGFILE" 2>&1; then
            say "GPO $guid: pulled v$local_ver -> v$chosen_ver from $chosen_fqdn"
            if [[ "$local_ver" -eq 0 ]]; then
                new_count=$((new_count + 1))
            else
                update_count=$((update_count + 1))
            fi
            any_pulled=1
        else
            say "GPO $guid: local rsync into $dst failed"
        fi
    else
        say "GPO $guid: smbclient mget from $chosen_fqdn failed (no $stage/$guid produced)"
    fi
    rm -rf "$stage"
done

# A single whole-tree sysvolreset at the end is cheaper than per-GPO walks
# and matches what samba-tool exposes (no per-path scope).
if [[ $any_pulled -eq 1 ]]; then
    say "running ntacl sysvolreset"
    samba-tool ntacl sysvolreset >>"$LOGFILE" 2>&1 \
        || say "WARN: ntacl sysvolreset failed"
fi

say "done: new=$new_count updated=$update_count deleted=$delete_count current=$skip_count no-source=$no_source_count"
SYNCEOF
chmod +x /usr/local/sbin/sysvol-sync

#===============================================================================
# 22. FIRST-BOOT HOST INTEGRATION
#===============================================================================
# samba-firstboot detects which hypervisor we're running on AT FIRST BOOT
# (not at image-prep time), installs the matching guest agent offline from
# /var/cache/samba-appliance/vmtools/, prints host-specific recommendations,
# and disables itself. The marker file /var/lib/samba-firstboot.done makes
# subsequent boots a no-op.
log "Installing samba-firstboot helper + service..."

cat > /usr/local/sbin/samba-firstboot <<'FBEOF'
#!/usr/bin/env bash
#
# samba-firstboot — runs once on the first boot of a deployed Samba AD DC
# appliance. Detects the actual hypervisor (which is usually NOT the same as
# the one the image was mastered on), installs the matching guest agent from
# /var/cache/samba-appliance/vmtools/ offline, deletes the unused caches,
# prints recommended VM hardware, and disables itself.

set -u -o pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

LOGFILE="/var/log/samba-firstboot.log"
MARKER="/var/lib/samba-firstboot.done"
MOTD="/etc/motd.d/01-samba-firstboot"
CACHE="/var/cache/samba-appliance/vmtools"
MANIFEST="$CACHE/manifest"

mkdir -p /var/lib /etc/motd.d "$(dirname "$LOGFILE")"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOGFILE"; }

if [[ -f "$MARKER" ]]; then
    log "samba-firstboot already complete (marker present); nothing to do"
    exit 0
fi

VIRT=$(systemd-detect-virt 2>/dev/null || echo "none")
log "host environment: $VIRT"

# Look up the package list for this virt-type from the manifest.
PKG_LIST=""
if [[ -f "$MANIFEST" ]]; then
    PKG_LIST=$(awk -F= -v v="$VIRT" 'NF>=2 && $1==v {sub(/^[^=]+=/, "", $0); print; exit}' "$MANIFEST")
fi

# Azure runs on Hyper-V, so systemd-detect-virt reports 'microsoft'. Tell
# them apart by the chassis-asset-tag DMI string Azure sets to a fixed
# value. When matched, augment the install list with cloud-init so the
# Azure IMDS injection pathway (SSH keys, hostname, user-data) works.
# walinuxagent's old responsibilities are largely covered by cloud-init
# on modern Debian; we don't try to bundle walinuxagent itself because
# it's not in Trixie main.
AZURE_CHASSIS_TAG="7783-7084-3265-9085-8269-3286-77"
if [[ "$VIRT" == "microsoft" ]] && \
   [[ -r /sys/class/dmi/id/chassis_asset_tag ]] && \
   [[ "$(cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null)" == "$AZURE_CHASSIS_TAG" ]]; then
    log "Azure detected via DMI chassis-asset-tag; adding cloud-init"
    PKG_LIST="$PKG_LIST cloud-init"
fi

# Per-package systemd unit map. Empty means "no service to enable".
service_units_for() {
    case "$1" in
        qemu-guest-agent)  echo "qemu-guest-agent" ;;
        open-vm-tools)     echo "open-vm-tools" ;;
        # Trixie's hyperv-daemons ships hv-kvp-daemon + hv-vss-daemon as units.
        # The historical hv-fcopy-daemon was retired upstream — file copy now
        # happens via the in-kernel hv_fcopy module.
        hyperv-daemons)    echo "hv-kvp-daemon hv-vss-daemon" ;;
        # cloud-init enables its own 4-stage systemd units via postinst. We
        # don't enable here; on next boot cloud-init runs naturally.
        cloud-init)        echo "" ;;
        # cloud-guest-utils is just CLI tools (growpart etc.); no services.
        cloud-guest-utils) echo "" ;;
        *)                 echo "" ;;
    esac
}

INSTALLED_NOTE=""
INSTALLED_PKGS=""
FAILED_PKGS=""

if [[ -z "$PKG_LIST" ]]; then
    INSTALLED_NOTE="No guest-agent or cloud-helper package staged for '$VIRT'.\nThe DC will run without host-side integration; chrony handles time,\nACPI handles graceful shutdown — both work without an agent. Install\nany of /var/cache/samba-appliance/vmtools/<pkg>/*.deb by hand if you\nwant management-plane integration."
    log "$INSTALLED_NOTE"
else
    log "installing for $VIRT: $PKG_LIST"
    for pkg in $PKG_LIST; do
        deb_dir="$CACHE/$pkg"
        if [[ ! -d "$deb_dir" ]] || ! compgen -G "$deb_dir/*.deb" >/dev/null; then
            log "  WARN: $pkg has no .deb files in cache (skipping)"
            FAILED_PKGS="$FAILED_PKGS $pkg"
            continue
        fi
        log "  dpkg -i $pkg (offline from $deb_dir)"
        if dpkg -i "$deb_dir"/*.deb >>"$LOGFILE" 2>&1; then
            INSTALLED_PKGS="$INSTALLED_PKGS $pkg"
        else
            log "    ERROR: dpkg -i of $pkg failed; see $LOGFILE"
            FAILED_PKGS="$FAILED_PKGS $pkg"
        fi
    done

    systemctl daemon-reload || true

    for pkg in $INSTALLED_PKGS; do
        for svc in $(service_units_for "$pkg"); do
            if systemctl enable --now "$svc" >>"$LOGFILE" 2>&1; then
                log "  enabled+started: $svc ($pkg)"
            else
                log "  WARN: could not start $svc (from $pkg)"
            fi
        done
    done

    if [[ -n "$INSTALLED_PKGS" ]]; then
        INSTALLED_NOTE="Installed:$INSTALLED_PKGS"
        [[ -n "$FAILED_PKGS" ]] && INSTALLED_NOTE+=$'\n'"Failed:   $FAILED_PKGS (see $LOGFILE)"
    elif [[ -n "$FAILED_PKGS" ]]; then
        INSTALLED_NOTE="ERROR: nothing installed; failed:$FAILED_PKGS"
        log "$INSTALLED_NOTE"
    fi

    # If we just installed cloud-init, prompt the user to reboot. cloud-init
    # has a 4-stage state machine that's tied into systemd's boot sequence;
    # running it now from late in the current boot won't pick up everything
    # the way an early-boot run does. A reboot is the path of least surprise.
    if echo " $INSTALLED_PKGS " | grep -q ' cloud-init '; then
        INSTALLED_NOTE+=$'\n'"NOTE: reboot once to let cloud-init run from early boot and apply"
        INSTALLED_NOTE+=$'\n'"      IMDS data (SSH keys, hostname) from your cloud platform."
    fi
fi

# Host-specific recommendations. Echoed to log AND written to a motd snippet
# so they show up at every SSH login until an admin removes the file.
read -r -d '' RECS <<RECEOF || true
=== Recommended VM hardware/config for $VIRT ===
RECEOF

case "$VIRT" in
    kvm|qemu)
        RECS+=$'\n'"  Hypervisor: KVM/QEMU (Proxmox, libvirt, oVirt, ...)"
        RECS+=$'\n'"  vCPU:       2+ (Skylake-Client+ or host-passthrough for AES-NI)"
        RECS+=$'\n'"  RAM:        2 GiB minimum, 4 GiB+ for active DCs"
        RECS+=$'\n'"  Disk:       virtio-blk or virtio-scsi (NOT IDE/SATA)"
        RECS+=$'\n'"  NIC:        virtio-net (NOT e1000/rtl8139)"
        RECS+=$'\n'"  Agent:      qemu-guest-agent (this script just installed it)"
        RECS+=$'\n'"  Time:       enable virtio-rtc; chrony is authoritative for AD time"
        ;;
    vmware)
        RECS+=$'\n'"  Hypervisor: VMware (ESXi / vCenter / Workstation / Fusion)"
        RECS+=$'\n'"  vCPU:       2+, expose AES-NI in CPU/MMU virt settings"
        RECS+=$'\n'"  RAM:        2 GiB minimum, 4 GiB+ for active DCs (no ballooning)"
        RECS+=$'\n'"  Disk:       Paravirtual SCSI (PVSCSI) controller"
        RECS+=$'\n'"  NIC:        vmxnet3 (NOT e1000)"
        RECS+=$'\n'"  Agent:      open-vm-tools (this script just installed it)"
        RECS+=$'\n'"  Time:       disable VMware Tools time-sync; chrony manages domain time"
        ;;
    microsoft)
        if [[ "$(cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null)" == "$AZURE_CHASSIS_TAG" ]]; then
            RECS+=$'\n'"  Platform:   Microsoft Azure (Hyper-V-backed)"
            RECS+=$'\n'"  vCPU:       2+, AES-NI exposed (default on Standard SKUs)"
            RECS+=$'\n'"  RAM:        2 GiB+ (e.g. Standard_B2s for tests, _D2s_v5 for prod)"
            RECS+=$'\n'"  Disk:       Premium SSD; use a dedicated managed disk for /var/lib/samba"
            RECS+=$'\n'"  NIC:        Accelerated Networking ON if SKU supports it"
            RECS+=$'\n'"  Agents:     hyperv-daemons + cloud-init (just installed)"
            RECS+=$'\n'"  Time:       chrony is authoritative; disable Azure time-sync if it competes"
            RECS+=$'\n'"  Backups:    Azure Backup VM-level snapshots are application-consistent"
            RECS+=$'\n'"              via VSS — generally OK for an AD DC, but verify each release"
        else
            RECS+=$'\n'"  Hypervisor: Microsoft Hyper-V (on-prem)"
            RECS+=$'\n'"  Generation: 2 (UEFI). Disable Secure Boot (cloud-image bootloader)"
            RECS+=$'\n'"  vCPU:       2+, virtualization extensions exposed"
            RECS+=$'\n'"  RAM:        2 GiB+ STATIC; do not use Dynamic Memory on AD DCs"
            RECS+=$'\n'"  Disk:       SCSI controller (NOT IDE)"
            RECS+=$'\n'"  NIC:        Hyper-V synthetic adapter (default for Gen2)"
            RECS+=$'\n'"  Integration: enable Time Sync, Heartbeat, Guest Service Interface"
            RECS+=$'\n'"  Agent:      hyperv-daemons (this script just installed it)"
            RECS+=$'\n'"  Checkpoints: prefer offline (Standard) checkpoints over Production"
            RECS+=$'\n'"               for AD DCs — VSS-quiesced live snapshots interact"
            RECS+=$'\n'"               poorly with USN replication semantics."
        fi
        ;;
    amazon)
        RECS+=$'\n'"  Platform:   Amazon EC2 (Nitro)"
        RECS+=$'\n'"  Instance:   M-class or T-class with at least 2 vCPU / 2 GiB"
        RECS+=$'\n'"  Disk:       gp3 EBS for the root volume; consider separate volume for /var/lib/samba"
        RECS+=$'\n'"  NIC:        ENA driver (kernel built-in)"
        RECS+=$'\n'"  Agents:     qemu-guest-agent + cloud-init + cloud-guest-utils (installed)"
        RECS+=$'\n'"  Networking: place DCs in private subnets with VPC peering or AD-replication NACLs"
        RECS+=$'\n'"  Backups:    EBS snapshots are crash-consistent — schedule with care for an AD DC"
        ;;
    xen)
        RECS+=$'\n'"  Hypervisor: Xen / Citrix Hypervisor / XCP-ng"
        RECS+=$'\n'"  vCPU:       2+, expose AES-NI"
        RECS+=$'\n'"  RAM:        2 GiB+, no ballooning for AD DCs"
        RECS+=$'\n'"  Disk:       PVHVM virtual disk"
        RECS+=$'\n'"  NIC:        netfront (paravirtualized)"
        RECS+=$'\n'"  Agents:     qemu-guest-agent + xe-guest-utilities (installed)"
        RECS+=$'\n'"  Time:       sync via Xen virtio-rtc; chrony authoritative for AD"
        ;;
    oracle)
        RECS+=$'\n'"  Hypervisor: Oracle VirtualBox"
        RECS+=$'\n'"  No headless guest-agent .deb is staged. If you want VBoxClient"
        RECS+=$'\n'"  features (clipboard, file integration), install"
        RECS+=$'\n'"  virtualbox-guest-utils manually (~30 MB of X dependencies)."
        ;;
    none)
        RECS+=$'\n'"  Bare-metal install detected — no virtualization-specific advice."
        RECS+=$'\n'"  Make sure chrony has reachable upstream NTP, the NIC is wired,"
        RECS+=$'\n'"  and the BIOS clock is sane."
        ;;
    *)
        RECS+=$'\n'"  Unknown environment '$VIRT'. No specific recommendations."
        RECS+=$'\n'"  AD DC operation does not require a guest agent — run it without."
        ;;
esac

log ""
printf '%s\n' "$RECS" | tee -a "$LOGFILE"

# Write the motd snippet — visible at every SSH login until removed.
{
    echo
    echo "=== Samba AD DC Appliance: first-boot host integration ==="
    echo "Detected: $VIRT"
    printf '%s\n' "$INSTALLED_NOTE" | sed 's/^/  /'
    printf '%s\n' "$RECS"
    echo
    echo "(Remove $MOTD to silence this banner.)"
    echo
} > "$MOTD"

# Cleanup: remove caches for packages we did not install, keep the ones we
# did (handy for re-running dpkg -i if something goes sideways) plus the
# manifest. Builds a space-padded keep-list and a substring match.
log ""
log "cleaning up unused guest-agent / cloud-helper caches..."
KEEP=" $(echo "$INSTALLED_PKGS" | xargs) "
shopt -s nullglob
for d in "$CACHE"/*/; do
    name=$(basename "$d")
    if [[ "$KEEP" != *" $name "* ]]; then
        log "  removing $d"
        rm -rf "$d"
    fi
done
shopt -u nullglob

# Mark done; disable the unit so subsequent boots are clean.
touch "$MARKER"
log "samba-firstboot complete; marker at $MARKER"
systemctl disable samba-firstboot.service >>"$LOGFILE" 2>&1 || true
FBEOF
chmod +x /usr/local/sbin/samba-firstboot

cat > /etc/systemd/system/samba-firstboot.service <<'UEOF'
[Unit]
Description=Samba AD DC Appliance first-boot host integration
ConditionPathExists=!/var/lib/samba-firstboot.done
After=local-fs.target
# Run before samba-ad-dc so the guest agent is up before any AD traffic.
# samba-ad-dc is masked at image-prep time and only enabled by samba-sconfig
# after a join/provision, so this ordering is mostly defensive.
Before=samba-ad-dc.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/samba-firstboot
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UEOF

systemctl daemon-reload
systemctl enable samba-firstboot.service

#===============================================================================
# 23. FINAL CLEANUP
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
echo "  Samba:         $(samba --version 2>/dev/null || echo 'check manually')"
echo "  PowerShell:    $(pwsh --version 2>/dev/null || echo 'not installed')"
echo "  Chrony:        $(chronyc --version 2>/dev/null || echo 'check manually')"
echo "  Guest agents:  $(ls -1 /var/cache/samba-appliance/vmtools/ 2>/dev/null | grep -v ^manifest$ | tr '\n' ' ')"
echo ""
echo "  Removed:       ${REMOVE_PKGS[*]}"
echo ""
echo "  Next steps:"
echo "    1. Shut down this VM. The shutdown-state disk is the host-agnostic"
echo "       deploy master — copy/export it to any hypervisor you want."
echo "    2. On a deployed VM's first boot, samba-firstboot.service will detect"
echo "       the actual hypervisor, install the matching guest agent offline,"
echo "       and print recommended VM hardware to the console + /etc/motd.d/."
echo "    3. Run 'sudo samba-sconfig' to provision or join a domain."
echo ""
