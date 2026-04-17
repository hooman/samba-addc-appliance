#!/usr/bin/env bash
#===============================================================================
# stage-router-artifacts.sh — Mac-side staging for the lab-v2 router VM
#
# Produces two files on the ISO share (/Volumes/ISO by default, = D:\ISO\
# on the Hyper-V host):
#
#   debian-13-router-base.vhdx    (~1.2 GB — Debian genericcloud qcow2 converted)
#   <hostname>-seed.iso           (~1 MB — NoCloud seed with substituted config)
#
# The base VHDX is a shared read-only blob — build it once, reuse for all
# router VMs you ever make. The seed ISO is per-VM: one per hostname/IP.
#
# Template lives in lab/seed/*.tpl with @@PLACEHOLDERS@@. A concrete build
# substitutes them from CLI flags + ~/.ssh/id_ed25519.pub.
#
# Usage:
#   lab/stage-router-artifacts.sh                                    # router1 10.10.10.1 lab.test
#   lab/stage-router-artifacts.sh -n router2 -i 10.10.20.1           # second lab segment
#   lab/stage-router-artifacts.sh --help
#
# Re-running skips the qcow2 download and VHDX conversion if the output
# already exists, so it's cheap to re-generate just the seed ISO after
# tweaking templates.
#===============================================================================
set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────────
HOSTNAME='router1'
LAN_IP='10.10.10.1'
LAN_PREFIX='24'
DOMAIN='lab.test'
DHCP_START=''   # auto-derived if empty
DHCP_END=''
SSH_PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub"
STAGE_DIR='/Volumes/ISO'
DEBIAN_URL='https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2'
EXTRA_DNSMASQ=''
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_SRC="$SCRIPT_DIR/seed"

die() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    cat <<EOF

Options:
  -n, --hostname NAME      router hostname (default: $HOSTNAME)
  -i, --lan-ip IP          router LAN IP (default: $LAN_IP)
  -p, --lan-prefix N       LAN CIDR prefix length (default: $LAN_PREFIX)
  -d, --domain NAME        DNS search domain (default: $DOMAIN)
      --dhcp-start IP      DHCP pool start (default: derive .100 of subnet)
      --dhcp-end IP        DHCP pool end   (default: derive .200 of subnet)
  -k, --pubkey FILE        SSH public key path (default: $SSH_PUBKEY_FILE)
  -s, --stage-dir DIR      staging dir (default: $STAGE_DIR)
      --extra-dnsmasq FILE file whose content is inlined into dnsmasq config
                           (for DHCP reservations + DNS delegations)
  -h, --help               show this

Example: lab/stage-router-artifacts.sh --extra-dnsmasq lab/seed/dnsmasq-lab.conf
EOF
}

# ── parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--hostname)    HOSTNAME="$2";        shift 2 ;;
        -i|--lan-ip)      LAN_IP="$2";          shift 2 ;;
        -p|--lan-prefix)  LAN_PREFIX="$2";      shift 2 ;;
        -d|--domain)      DOMAIN="$2";          shift 2 ;;
        --dhcp-start)     DHCP_START="$2";      shift 2 ;;
        --dhcp-end)       DHCP_END="$2";        shift 2 ;;
        -k|--pubkey)      SSH_PUBKEY_FILE="$2"; shift 2 ;;
        -s|--stage-dir)   STAGE_DIR="$2";       shift 2 ;;
        --extra-dnsmasq)  EXTRA_DNSMASQ_FILE="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "unknown arg: $1" ;;
    esac
done

# ── sanity ──────────────────────────────────────────────────────────────────
command -v qemu-img >/dev/null || die "qemu-img not on PATH (brew install qemu)"
command -v hdiutil  >/dev/null || die "hdiutil missing (should be built-in on macOS)"
command -v curl     >/dev/null || die "curl not on PATH"
[[ -d "$STAGE_DIR" ]] || die "stage dir not mounted: $STAGE_DIR"
[[ -f "$SSH_PUBKEY_FILE" ]] || die "ssh pubkey not found: $SSH_PUBKEY_FILE"
[[ -d "$SEED_SRC" ]] || die "seed templates dir not found: $SEED_SRC"
for tpl in user-data.tpl meta-data.tpl network-config.tpl; do
    [[ -f "$SEED_SRC/$tpl" ]] || die "template missing: $SEED_SRC/$tpl"
done

# Auto-derive DHCP pool endpoints from LAN_IP if not supplied.
# E.g. 10.10.10.1 -> 10.10.10.100 / 10.10.10.200
if [[ -z "$DHCP_START" || -z "$DHCP_END" ]]; then
    IFS='.' read -r a b c _d <<< "$LAN_IP"
    [[ -z "$DHCP_START" ]] && DHCP_START="${a}.${b}.${c}.100"
    [[ -z "$DHCP_END"   ]] && DHCP_END="${a}.${b}.${c}.200"
fi

FQDN="${HOSTNAME}.${DOMAIN}"
PUBKEY_CONTENT="$(tr -d '\n' < "$SSH_PUBKEY_FILE")"

# Derive subnet/cidr string "10.10.10.0/24"
IFS='.' read -r a b c _d <<< "$LAN_IP"
LAN_SUBNET_CIDR="${a}.${b}.${c}.0/${LAN_PREFIX}"

# Optional extra dnsmasq content (dhcp-host reservations, DNS delegations)
EXTRA_DNSMASQ_BLOCK=''
if [[ -n "${EXTRA_DNSMASQ_FILE:-}" ]]; then
    [[ -f "$EXTRA_DNSMASQ_FILE" ]] || die "extra-dnsmasq file not found: $EXTRA_DNSMASQ_FILE"
    # Prefix each line with 6 spaces so it nests cleanly under the write_files block
    EXTRA_DNSMASQ_BLOCK="$(sed 's/^/      /' "$EXTRA_DNSMASQ_FILE")"
fi

echo "=== stage-router-artifacts.sh"
echo "  hostname:     $HOSTNAME"
echo "  fqdn:         $FQDN"
echo "  lan:          $LAN_IP/$LAN_PREFIX  (subnet $LAN_SUBNET_CIDR)"
echo "  domain:       $DOMAIN"
echo "  dhcp pool:    $DHCP_START .. $DHCP_END"
echo "  pubkey:       $SSH_PUBKEY_FILE"
echo "  stage dir:    $STAGE_DIR"
echo "  extra dnsmasq: ${EXTRA_DNSMASQ_FILE:-<none>}"

# ── 1. base VHDX (shared across all router VMs) ─────────────────────────────
CACHE_QCOW2="$STAGE_DIR/debian-13-genericcloud-amd64.qcow2"
OUT_VHDX="$STAGE_DIR/debian-13-router-base.vhdx"

if [[ ! -f "$OUT_VHDX" ]]; then
    if [[ ! -f "$CACHE_QCOW2" ]]; then
        echo "-> downloading Debian 13 genericcloud qcow2 (~300 MB)"
        curl -fSL -o "$CACHE_QCOW2" "$DEBIAN_URL"
    else
        echo "-> using cached qcow2 at $CACHE_QCOW2"
    fi

    # qemu-img can't lock across SMB on macOS → convert via local tmp, then
    # move into place.
    echo "-> converting qcow2 -> vhdx (~60s)"
    tmp_qcow=$(mktemp /tmp/router-XXXX.qcow2)
    tmp_vhdx=$(mktemp /tmp/router-XXXX.vhdx)
    trap "rm -f '$tmp_qcow' '$tmp_vhdx'" EXIT
    cp "$CACHE_QCOW2" "$tmp_qcow"
    qemu-img convert -O vhdx -o subformat=dynamic "$tmp_qcow" "$tmp_vhdx"
    cp "$tmp_vhdx" "$OUT_VHDX"
    rm -f "$tmp_qcow" "$tmp_vhdx"
    trap - EXIT
    echo "-> wrote $OUT_VHDX ($(du -h "$OUT_VHDX" | cut -f1))"
else
    echo "-> base VHDX already present at $OUT_VHDX — skipping convert"
fi

# ── 2. NoCloud seed ISO (per-router) ────────────────────────────────────────
SEED_BUILD_DIR=$(mktemp -d /tmp/seed-router-XXXX)
SEED_OUT="$STAGE_DIR/${HOSTNAME}-seed.iso"

echo "-> generating seed ISO for $HOSTNAME"

substitute() {
    # Streaming sed with all placeholders
    sed \
        -e "s|@@HOSTNAME@@|$HOSTNAME|g" \
        -e "s|@@FQDN@@|$FQDN|g" \
        -e "s|@@DOMAIN@@|$DOMAIN|g" \
        -e "s|@@LAN_IP@@|$LAN_IP|g" \
        -e "s|@@LAN_PREFIX@@|$LAN_PREFIX|g" \
        -e "s|@@LAN_SUBNET_CIDR@@|$LAN_SUBNET_CIDR|g" \
        -e "s|@@DHCP_START@@|$DHCP_START|g" \
        -e "s|@@DHCP_END@@|$DHCP_END|g" \
        -e "s|@@SSH_PUBKEY@@|$PUBKEY_CONTENT|g" \
        "$1"
}

substitute "$SEED_SRC/meta-data.tpl"       > "$SEED_BUILD_DIR/meta-data"
substitute "$SEED_SRC/network-config.tpl"  > "$SEED_BUILD_DIR/network-config"

# user-data.tpl has a multi-line @@EXTRA_DNSMASQ@@ placeholder that sed can't
# easily insert multi-line content for. awk -v can't hold a multi-line value
# (newline-in-string error), so pass via environment and use ENVIRON.
EXTRA_DNSMASQ_BLOCK="$EXTRA_DNSMASQ_BLOCK" \
awk '
    # Only match the PLACEHOLDER LINE (after any leading whitespace), not
    # occurrences in comments like the file header "Placeholders: ... @@EXTRA_DNSMASQ@@".
    /^[[:space:]]*@@EXTRA_DNSMASQ@@[[:space:]]*$/ {
        if (ENVIRON["EXTRA_DNSMASQ_BLOCK"] != "") print ENVIRON["EXTRA_DNSMASQ_BLOCK"]
        next
    }
    { print }
' "$SEED_SRC/user-data.tpl" | substitute /dev/stdin > "$SEED_BUILD_DIR/user-data"

# hdiutil makehybrid refuses to overwrite; remove any prior copy first.
rm -f "$SEED_OUT"
hdiutil makehybrid -iso -joliet \
    -default-volume-name CIDATA \
    -o "$SEED_OUT" "$SEED_BUILD_DIR" >/dev/null

rm -rf "$SEED_BUILD_DIR"
echo "-> wrote $SEED_OUT ($(du -h "$SEED_OUT" | cut -f1))"

echo ""
echo "done. Build the VM with:"
echo "  ssh nmadmin@server 'pwsh -File D:\\ISO\\lab-scripts\\New-LabRouter.ps1 \\"
echo "      -VMName $HOSTNAME -SeedIso D:\\ISO\\${HOSTNAME}-seed.iso'"
