# Samba AD DC Appliance

This repository builds and tests a small **Samba Active Directory Domain
Controller appliance** on Debian 13. The appliance is meant to feel like a
headless server product: prepare a clean image once, then use a local
`sconfig`-style tool to provision, join, harden, diagnose, and maintain the
domain controller.

The repo currently contains compatibility copies of the Hyper-V lab scripts
that exercise the appliance against a Windows Server 2025 forest with Microsoft
security baseline GPOs applied. The longer-term direction is a three-repo
layout developed side by side:

- `lab-kit`: reusable appliance lab orchestration
- `lab-router`: simple reusable lab router VM
- `samba-addc-appliance`: this Samba appliance and its scenarios

See [`docs/REPO-SPLIT.md`](docs/REPO-SPLIT.md) for the split plan.

The lab exists because most of the important behavior is interoperability behavior:
Kerberos, LDAP signing, Samba replication, Windows KCC expectations, DNS, and
SYSVOL handling.

## Repository Map

| Path | Purpose |
| --- | --- |
| `prepare-image.sh` | One-time Debian image preparation. Installs Samba AD DC dependencies, PowerShell, chrony, nftables, and appliance helper scripts. |
| `samba-sconfig.sh` | Main appliance configuration tool. Provides the whiptail TUI and a small headless CLI for automated tests. |
| `lab/` | Samba test harness: runner, env, scenarios, and Hyper-V helpers under `lab/hyperv/`. Generic pieces (revert, router) live in the sibling repos. |
| `lab/hyperv/` | Hyper-V/WS2025-specific PowerShell + unattend XML: WS2025 DC build, baseline apply, Samba test VM creation, AD cleanup, verification. |
| `lab/run-scenario.sh` | Mac-side test runner that reverts the Samba VM, cleans the Windows lab state, pushes current scripts, runs a scenario, and verifies results. Stages PS scripts from this repo plus `../lab-kit/hypervisors/hyperv/` and `../lab-router/hypervisors/hyperv/`. |
| `lab/scenarios/` | Scenario definitions. `join-dc.sh` is the current end-to-end additional-DC test. |
| `test-results/` | Distilled historical notes, topology, and regression reports. Raw `*.log` transcripts are local-only. |
| `AGENTS.md` | Vendor-neutral coding-agent guide for this repo. |
| `CLAUDE.md` | Claude Code compatibility pointer back to `AGENTS.md`. |
| `HANDOFF.md` | Retired handoff pointer to maintained docs. |

## Intended Workflow

1. Build the persistent lab infrastructure once:
   - `router1`, a Debian NAT/DHCP/DNS-forwarder VM.
   - `WS2025-DC1`, the first Windows Server 2025 DC for `lab.test`.
   - Microsoft baseline GPOs linked into the lab domain.

2. Create a Debian test VM, install Debian manually, then run
   `prepare-image.sh` once.

3. Checkpoint the prepared Debian VM as `golden-image`.

4. Iterate on `samba-sconfig.sh` and the lab tests by running scenarios from
   the Mac:

   ```bash
   lab/run-scenario.sh join-dc
   ```

5. Promote fixes into the appliance scripts only after the scenario verifies
   them end to end.

## Lab Topology

The v2 lab uses a realistic DHCP/NAT layout. The Samba VM starts life like a
normal appliance would: attached to a LAN, receiving DHCP, with internet access
through a gateway.

| Role | VM | IP | Notes |
| --- | --- | --- | --- |
| Gateway / DHCP / DNS forwarder | `router1` | `10.10.10.1` | Debian cloud image, NAT through the external Hyper-V switch. |
| First Windows DC | `WS2025-DC1` | `10.10.10.10` | Owns `lab.test`, reverse zone, baseline GPOs. |
| Samba DC under test | `samba-dc1` | `10.10.10.20` | Debian 13 appliance candidate. |
| Optional second Samba DC | `samba-dc2` | `10.10.10.21` | Useful for Samba-to-Samba SYSVOL and replication tests. |

DHCP reservations live in the sibling `lab-router` repo at
`configs/samba-addc.dnsmasq.conf`. Hyper-V VM MAC addresses in the PowerShell
scripts are pinned to match those reservations.

## First-Time Lab Setup

These commands are run from the Mac unless noted.

### 1. Check prerequisites

You need:

- Passwordless SSH to the Hyper-V host as `nmadmin@server`.
- `/Volumes/ISO` mounted and writable. This maps to `D:\ISO\` on the host.
- `qemu-img`, `hdiutil`, and `curl` on the Mac.
- Windows Server 2025 and Debian installer ISOs staged in `/Volumes/ISO`.
- `WS2025-2602-Security-Baseline.zip` staged in `/Volumes/ISO`.

Quick checks:

```bash
ssh nmadmin@server 'hostname'
touch /Volumes/ISO/.write-test && rm /Volumes/ISO/.write-test
which qemu-img hdiutil curl
```

### 2. Stage router artifacts

Router staging now lives in the sibling `lab-router` repo. Prefer the YAML
config (requires `yq`; `brew install yq`):

```bash
../lab-router/scripts/stage-router-artifacts.sh \
    --config ../lab-router/configs/samba-addc.yaml
```

The pre-YAML invocation using the raw dnsmasq snippet still works if you
don't want to install `yq`:

```bash
../lab-router/scripts/stage-router-artifacts.sh \
    --extra-dnsmasq ../lab-router/configs/samba-addc.dnsmasq.conf
```

This creates or refreshes:

- `/Volumes/ISO/debian-13-router-base.vhdx`
- `/Volumes/ISO/router1-seed.iso`

The VHDX is reused; the seed ISO is cheap to regenerate whenever the router
cloud-init templates or dnsmasq reservations change.

### 3. Stage host-side lab scripts

The host needs PowerShell scripts from all three sibling repos staged into one
place:

```bash
mkdir -p /Volumes/ISO/lab-scripts
cp lab/hyperv/*.ps1 lab/hyperv/*.xml /Volumes/ISO/lab-scripts/
cp ../lab-kit/hypervisors/hyperv/*.ps1 /Volumes/ISO/lab-scripts/
cp ../lab-router/hypervisors/hyperv/*.ps1 /Volumes/ISO/lab-scripts/
```

Repeat this after editing any PowerShell or unattend files. `lab/run-scenario.sh`
also re-stages from all three sources automatically on every run.

### 4. Build the router

Run on the Hyper-V host through SSH:

```bash
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\New-LabRouter.ps1'
```

Verify from the Mac:

```bash
ssh -J nmadmin@server hm@10.10.10.1 'cat /var/log/router-ready.marker; sudo nft list table ip nat'
```

### 5. Build the WS2025 domain controller

```bash
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\New-WS2025Lab.ps1'
```

Wait until promotion and phase 2 complete. If you have a wait helper staged,
run it; otherwise use PowerShell Direct as described in `HANDOFF.md`.

Then apply the Microsoft baseline:

```bash
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\Apply-SecurityBaseline.ps1'
```

### 6. Create the Samba test VM

```bash
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\New-SambaTestVM.ps1 -VMName samba-dc1 -Start'
```

Install Debian manually in the console:

- Hostname: `samba-dc1`
- Network: DHCP
- Software selection: SSH server and standard system utilities only
- Create `debadmin`
- After first boot, give `debadmin` passwordless sudo and install your SSH key

Verify:

```bash
ssh -J nmadmin@server debadmin@10.10.10.20 'sudo -n true && echo OK'
```

### 7. Prepare and checkpoint the image

Copy the scripts to the VM and run image preparation:

```bash
scp -J nmadmin@server prepare-image.sh samba-sconfig.sh debadmin@10.10.10.20:/tmp/
ssh -J nmadmin@server debadmin@10.10.10.20 'sudo install -m 0755 /tmp/samba-sconfig.sh /usr/local/sbin/samba-sconfig && sudo cp /tmp/prepare-image.sh /root/prepare-image.sh && sudo bash /root/prepare-image.sh'
```

Shut down and checkpoint on the Hyper-V host:

```bash
ssh nmadmin@server 'Stop-VM samba-dc1; Checkpoint-VM -Name samba-dc1 -SnapshotName golden-image'
```

## Running Tests

List scenarios:

```bash
lab/run-scenario.sh --list
```

Run the prepared-image smoke test:

```bash
lab/run-scenario.sh smoke-prepared-image
```

Run the main join regression:

```bash
lab/run-scenario.sh join-dc
```

Useful iteration flags:

```bash
lab/run-scenario.sh join-dc --verify-only
lab/run-scenario.sh join-dc --no-reset --no-cleanup
lab/run-scenario.sh join-dc --dry-cleanup
```

Every run writes a transcript to `test-results/<scenario>-<timestamp>.log`.

`lab/run-scenario.sh` is a thin wrapper around `../lab-kit/bin/run-scenario.sh`.
It sets `LAB_ENV=lab/samba.env`, resolves the scenario short-name to a file in
`lab/scenarios/`, and forwards flags. The `--no-cleanup` / `--dry-cleanup`
flags set `SC_SKIP_CLEANUP` / `SC_DRY_CLEANUP` env vars which scenarios read
in their `pre_hook` (only `join-dc` uses them today — the smoke scenario
has no AD cleanup).

For the full test plan and important tests to add next, see
[`docs/LAB-TESTING.md`](docs/LAB-TESTING.md).

## Important Design Notes

- Samba does not implement DFSR. SYSVOL replication is handled explicitly by
  `sysvol-sync` and by SMB-based seeding after a Windows join.
- Samba's default AD DC functional level can be too low for modern Windows
  forests. `samba-sconfig` probes rootDSE and passes the matching functional
  level to `samba-tool domain join`.
- Windows KCC can report replication error `8524` if the Samba DC's PTR record
  is missing. The join flow registers the PTR and forces KCC afterward.
- The image preparation script avoids baking internet NTP sources into chrony.
  Domain time is configured during provision or join, where the correct source
  is known.
- The generated TLS certificate is self-signed but includes SANs. Production
  deployments should replace it with a CA-issued certificate or a managed local
  CA workflow.

## Current Status

The current implemented regression is `join-dc`: revert the prepared Debian
image, join it to the WS2025 forest as an additional DC, validate Samba and
Windows-side replication, ensure SYSVOL is populated, and verify the TLS cert
has SAN entries.

Next useful work is documentation polish, more scenarios, and broader
headless `samba-sconfig` commands so tests can cover provision, RODC, firewall,
hardening, diagnostics, and SYSVOL sync without driving the TUI.
