#!/usr/bin/env bash
#===============================================================================
# stage-samba-base.sh - Mac-side staging for the Samba AD DC appliance
#
# Produces two files on the ISO share (/Volumes/ISO by default,
# = D:\ISO\ on the Hyper-V host):
#
#   debian-13-samba-base.vhdx     ~1.2 GB - Debian genericcloud qcow2 converted.
#                                  Built once, reused for every Samba VM you make.
#   <hostname>-seed.iso           ~1 MB - NoCloud cloud-init seed for one VM.
#
# The per-VM seed encodes hostname, the appliance admin user, and your SSH
# pubkey. A VM created from these two files boots, applies cloud-init once,
# and is immediately reachable over SSH from the Mac. No vmconnect clicks,
# no Debian installer wait, no manual sudoers / authorized_keys setup.
#
# This mirrors the lab-router stager. The cached qcow2 is shared between
# the two — the first repo to fetch it primes the cache for the other.
#
# Usage:
#   lab/stage-samba-base.sh                            # samba-dc1 / lab.test
#   lab/stage-samba-base.sh -n samba-dc2
#   lab/stage-samba-base.sh -u debadmin -k ~/.ssh/lab.pub
#===============================================================================
set -euo pipefail

HOSTNAME='samba-dc1'
DOMAIN='lab.test'
USERNAME='debadmin'
SSH_PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub"
STAGE_DIR='/Volumes/ISO'
DEBIAN_URL='https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_SRC="$SCRIPT_DIR/templates/cloud-init"

die() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    cat <<EOF

Options:
  -n, --hostname NAME     VM short hostname (default: $HOSTNAME)
  -d, --domain NAME       DNS domain (default: $DOMAIN)
  -u, --user NAME         appliance admin user (default: $USERNAME)
  -k, --pubkey FILE       SSH public key (default: ~/.ssh/id_ed25519.pub)
  -s, --stage-dir DIR     output directory (default: $STAGE_DIR)
  -h, --help              show this
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--hostname)   HOSTNAME="$2";        shift 2 ;;
        -d|--domain)     DOMAIN="$2";          shift 2 ;;
        -u|--user)       USERNAME="$2";        shift 2 ;;
        -k|--pubkey)     SSH_PUBKEY_FILE="$2"; shift 2 ;;
        -s|--stage-dir)  STAGE_DIR="$2";       shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "unknown arg: $1" ;;
    esac
done

command -v qemu-img >/dev/null || die "qemu-img not on PATH (brew install qemu)"
command -v hdiutil  >/dev/null || die "hdiutil missing (built-in on macOS)"
command -v curl     >/dev/null || die "curl not on PATH"
[[ -d "$STAGE_DIR" ]]              || die "stage dir not mounted: $STAGE_DIR"
[[ -f "$SSH_PUBKEY_FILE" ]]        || die "ssh pubkey not found: $SSH_PUBKEY_FILE"
[[ -d "$SEED_SRC" ]]               || die "seed templates dir not found: $SEED_SRC"
for tpl in user-data-samba.tpl meta-data.tpl network-config.tpl; do
    [[ -f "$SEED_SRC/$tpl" ]] || die "template missing: $SEED_SRC/$tpl"
done

FQDN="${HOSTNAME}.${DOMAIN}"
PUBKEY_CONTENT="$(tr -d '\n' < "$SSH_PUBKEY_FILE")"

echo "=== stage-samba-base.sh"
echo "  hostname:   $HOSTNAME"
echo "  fqdn:       $FQDN"
echo "  user:       $USERNAME"
echo "  pubkey:     $SSH_PUBKEY_FILE"
echo "  stage dir:  $STAGE_DIR"

#---- 1. base VHDX (shared across all Samba VMs) ----
CACHE_QCOW2="$STAGE_DIR/debian-13-genericcloud-amd64.qcow2"
OUT_VHDX="$STAGE_DIR/debian-13-samba-base.vhdx"

if [[ ! -f "$OUT_VHDX" ]]; then
    if [[ ! -f "$CACHE_QCOW2" ]]; then
        echo "-> downloading Debian 13 genericcloud qcow2 (~300 MB)"
        curl -fSL -o "$CACHE_QCOW2" "$DEBIAN_URL"
    else
        echo "-> using cached qcow2 at $CACHE_QCOW2"
    fi

    # qemu-img cannot lock across SMB on macOS; convert in /tmp then move.
    echo "-> converting qcow2 -> vhdx (~60s)"
    tmp_qcow=$(mktemp /tmp/samba-base-XXXX.qcow2)
    tmp_vhdx=$(mktemp /tmp/samba-base-XXXX.vhdx)
    trap "rm -f '$tmp_qcow' '$tmp_vhdx'" EXIT
    cp "$CACHE_QCOW2" "$tmp_qcow"
    qemu-img convert -O vhdx -o subformat=dynamic "$tmp_qcow" "$tmp_vhdx"
    cp "$tmp_vhdx" "$OUT_VHDX"
    rm -f "$tmp_qcow" "$tmp_vhdx"
    trap - EXIT
    echo "-> wrote $OUT_VHDX ($(du -h "$OUT_VHDX" | cut -f1))"
else
    echo "-> base VHDX already present at $OUT_VHDX - skipping convert"
fi

#---- 2. NoCloud seed ISO (per-VM) ----
SEED_BUILD_DIR=$(mktemp -d /tmp/seed-samba-XXXX)
SEED_OUT="$STAGE_DIR/${HOSTNAME}-seed.iso"

substitute() {
    sed \
        -e "s|@@HOSTNAME@@|$HOSTNAME|g" \
        -e "s|@@FQDN@@|$FQDN|g" \
        -e "s|@@DOMAIN@@|$DOMAIN|g" \
        -e "s|@@USERNAME@@|$USERNAME|g" \
        -e "s|@@SSH_PUBKEY@@|$PUBKEY_CONTENT|g" \
        "$1"
}

substitute "$SEED_SRC/user-data-samba.tpl"  > "$SEED_BUILD_DIR/user-data"
substitute "$SEED_SRC/meta-data.tpl"        > "$SEED_BUILD_DIR/meta-data"
substitute "$SEED_SRC/network-config.tpl"   > "$SEED_BUILD_DIR/network-config"

# hdiutil makehybrid won't overwrite — clear any prior copy first.
rm -f "$SEED_OUT"
hdiutil makehybrid -iso -joliet \
    -default-volume-name CIDATA \
    -o "$SEED_OUT" "$SEED_BUILD_DIR" >/dev/null

rm -rf "$SEED_BUILD_DIR"
echo "-> wrote $SEED_OUT ($(du -h "$SEED_OUT" | cut -f1))"

echo ""
echo "Build the VM with:"
echo "  ssh <host-user>@<hyper-v-host> 'pwsh -File D:\\ISO\\lab-scripts\\New-SambaTestVM.ps1 \\"
echo "      -VMName ${HOSTNAME} -SeedIso D:\\ISO\\${HOSTNAME}-seed.iso -Start'"
echo ""
echo "Or run the end-to-end build (stage + create + prepare + checkpoint):"
echo "  lab/build-fresh-base.sh -n ${HOSTNAME}"
