#!/usr/bin/env bash
#
# lab/run-scenario.sh — end-to-end Samba AD DC test cycle driver.
#
# Given a scenario name, this script:
#
#   1. stages lab/*.ps1 and lab/*.xml → /Volumes/ISO/lab-scripts/ (= D:\ISO\
#      lab-scripts\ on the Hyper-V host)
#   2. reverts samba-dc1 to its 'golden-image' checkpoint
#   3. runs Reset-LabDomainState on WS2025-DC1 (strips stale samba-* records)
#   4. scp's the repo's current prepare-image.sh / samba-sconfig.sh into
#      /tmp on samba-dc1 and installs samba-sconfig to /usr/local/sbin
#   5. sources lab/scenarios/<scenario>.sh and calls run_scenario() then
#      verify()
#
# Exit 0 = verify passed, non-zero otherwise. Every cycle writes a complete
# transcript to test-results/<scenario>-<UTC-timestamp>.log.
#
# Why the runner is opinionated:
#   A Samba join leaves durable objects in AD: computer account, NTDS Settings,
#   DNS records, replication links, and sometimes failed KCC state. Reverting
#   only the Debian VM is not enough for a clean test. The default path resets
#   both sides, pushes the current scripts, and verifies final state so each
#   run is a real regression instead of a lucky rerun against stale lab data.
#
# Scenarios contribute:
#   run_scenario   — the body that exercises the system under test
#   verify         — assertions; returns 0 on pass
#   pre_hook       — optional, runs after setup, before run_scenario
#   post_hook      — optional, runs after verify (always, even on FAIL)
#
# Scenarios may call the ssh_host / ssh_vm / scp_to_vm helpers defined below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCENARIO_DIR="$SCRIPT_DIR/scenarios"
RESULTS_DIR="$REPO_DIR/test-results"
STAGE_DIR="${STAGE_DIR:-/Volumes/ISO/lab-scripts}"

# Lab defaults — match CLAUDE.md lab-v2 addressing.
HV_HOST="${HV_HOST:-server}"
HV_USER="${HV_USER:-nmadmin}"
VM_NAME="${VM_NAME:-samba-dc1}"
VM_IP="${VM_IP:-10.10.10.20}"
VM_USER="${VM_USER:-debadmin}"
GOLDEN_CHECKPOINT="${GOLDEN_CHECKPOINT:-golden-image}"

usage() {
    cat <<USAGE
Usage: lab/run-scenario.sh <scenario> [flags]
       lab/run-scenario.sh --list

Flags:
  --no-reset      skip samba-dc1 revert (faster against a prepared VM)
  --no-push       skip scp of prepare-image.sh / samba-sconfig.sh
  --no-cleanup    skip Reset-LabDomainState on WS2025-DC1
  --no-stage      skip copying lab/*.ps1 to the host share
  --dry-cleanup   run Reset-LabDomainState with -DryRun (inspect only)
  --verify-only   skip everything except verify(); iterate on assertions
                  against the current VM state without re-running the
                  scenario body (implies --no-reset --no-push --no-cleanup
                  --no-stage and also skips run_scenario + pre/post hooks)

Environment overrides:
  HV_HOST, HV_USER, VM_NAME, VM_IP, VM_USER, GOLDEN_CHECKPOINT, STAGE_DIR

Scenarios in $SCENARIO_DIR:
USAGE
    if [[ -d "$SCENARIO_DIR" ]]; then
        find "$SCENARIO_DIR" -maxdepth 1 -name '*.sh' -type f 2>/dev/null \
            | sed 's|.*/||; s|\.sh$||; s|^|  |' | sort
    fi
}

SCENARIO=""
RESET=1
PUSH=1
CLEANUP=1
STAGE=1
DRY_CLEAN=""
VERIFY_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)     usage; exit 0 ;;
        --list)
            find "$SCENARIO_DIR" -maxdepth 1 -name '*.sh' -type f 2>/dev/null \
                | sed 's|.*/||; s|\.sh$||' | sort
            exit 0 ;;
        --no-reset)    RESET=0 ;;
        --no-push)     PUSH=0 ;;
        --no-cleanup)  CLEANUP=0 ;;
        --no-stage)    STAGE=0 ;;
        --dry-cleanup) DRY_CLEAN="-DryRun" ;;
        --verify-only) VERIFY_ONLY=1; RESET=0; PUSH=0; CLEANUP=0; STAGE=0 ;;
        -*) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
        *)  [[ -n "$SCENARIO" ]] && { echo "Only one scenario may be given." >&2; exit 2; }
            SCENARIO="$1" ;;
    esac
    shift
done

[[ -z "$SCENARIO" ]] && { usage >&2; exit 2; }

SCENARIO_FILE="$SCENARIO_DIR/$SCENARIO.sh"
[[ -f "$SCENARIO_FILE" ]] || { echo "No such scenario: $SCENARIO_FILE" >&2; exit 2; }

# Helpers usable by scenarios.
ssh_host()  { ssh "$HV_USER@$HV_HOST" "$@"; }
ssh_vm()    { ssh -J "$HV_USER@$HV_HOST" "$VM_USER@$VM_IP" "$@"; }
scp_to_vm() { scp -J "$HV_USER@$HV_HOST" "$@" "$VM_USER@$VM_IP:/tmp/"; }

say()  { echo "--- [$(date -u +%H:%M:%S)] $*"; }
step() { echo; echo "=============================================================="
         echo "=== $*"
         echo "=============================================================="; }

# Scenario function defaults (overridden by the scenario file).
run_scenario() { echo "scenario $SCENARIO: run_scenario() not defined"; return 2; }
verify()       { echo "scenario $SCENARIO: verify() not defined"; return 2; }
pre_hook()     { :; }
post_hook()    { :; }

# shellcheck disable=SC1090
source "$SCENARIO_FILE"

mkdir -p "$RESULTS_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$RESULTS_DIR/${SCENARIO}-${TS}.log"

# Tee all subsequent output to the log file.
exec > >(tee -a "$LOG") 2>&1

rc=2
trap 'say "EXIT rc=$rc  log=$LOG"' EXIT

step "scenario=$SCENARIO log=$LOG"

# 1. Stage host-side PS/XML scripts.
if [[ $STAGE -eq 1 ]]; then
    step "stage lab/*.ps1 lab/*.xml → $STAGE_DIR"
    if [[ -d "$STAGE_DIR" ]]; then
        cp -f "$SCRIPT_DIR"/*.ps1 "$STAGE_DIR"/ 2>/dev/null || true
        cp -f "$SCRIPT_DIR"/*.xml "$STAGE_DIR"/ 2>/dev/null || true
        ls -la "$STAGE_DIR"/*.ps1 2>/dev/null | tail -20
    else
        say "WARN: $STAGE_DIR not mounted — skipping stage"
    fi
else
    say "skipping stage (--no-stage)"
fi

# 2. Revert samba-dc1.
if [[ $RESET -eq 1 ]]; then
    step "revert $VM_NAME → $GOLDEN_CHECKPOINT"
    ssh_host "pwsh -File D:\\ISO\\lab-scripts\\Revert-TestVM.ps1 -VMName '$VM_NAME' -Checkpoint '$GOLDEN_CHECKPOINT'"

    say "wait for $VM_IP SSH (up to 120s)..."
    for _ in $(seq 1 60); do
        if ssh -o ConnectTimeout=3 -o BatchMode=yes \
               -J "$HV_USER@$HV_HOST" "$VM_USER@$VM_IP" true 2>/dev/null; then
            break
        fi
        sleep 2
    done
    ssh_vm 'hostname; ip -4 addr show | grep -E "inet " | head -3' \
        || { say "$VM_NAME unreachable after revert"; rc=1; exit 1; }
else
    say "skipping VM revert (--no-reset)"
fi

# 3. Clean WS2025-DC1 stale samba-* records.
if [[ $CLEANUP -eq 1 ]]; then
    step "Reset-LabDomainState on WS2025-DC1 ${DRY_CLEAN:+(dry-run)}"
    ssh_host "pwsh -File D:\\ISO\\lab-scripts\\Reset-LabDomainState.ps1 $DRY_CLEAN" \
        || { say "cleanup step failed"; rc=1; exit 1; }
else
    say "skipping WS2025 cleanup (--no-cleanup)"
fi

# 4. Push current repo scripts to samba-dc1.
if [[ $PUSH -eq 1 ]]; then
    step "push scripts to $VM_NAME"
    scp_to_vm "$REPO_DIR/prepare-image.sh" "$REPO_DIR/samba-sconfig.sh"
    ssh_vm 'sudo install -m 0755 /tmp/samba-sconfig.sh /usr/local/sbin/samba-sconfig'
else
    say "skipping script push (--no-push)"
fi

if [[ $VERIFY_ONLY -eq 0 ]]; then
    step "pre_hook"
    pre_hook

    step "scenario body"
    run_scenario || true   # scenario failures surface via verify(), not here

    step "post_hook (pre-verify)"
    # post_hook runs twice only when the caller asked for it — keep the
    # default contract (once, after verify). Do nothing here.
fi

step "verify"
if verify; then
    say "PASS"
    rc=0
else
    say "FAIL"
    rc=1
fi

if [[ $VERIFY_ONLY -eq 0 ]]; then
    step "post_hook"
    post_hook || true
fi

exit $rc
