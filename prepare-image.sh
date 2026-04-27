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
