# HANDOFF.md — How to hand this project off to Claude Code (lab v2)

This is your personal setup checklist. Work through it in order. The whole
thing takes ~30 minutes of your attention, most of it waiting while things
install or download. Once Claude Code takes over, you mostly watch.

## Mental model

You have two categories of files:

- **Project files** (CLAUDE.md, prepare-image.sh, samba-sconfig.sh, lab/\*) —
  these live in a **Git repo on your Mac**. Claude Code reads and edits them
  there.
- **Lab files** (lab/\*.ps1 scripts, ISOs, base VHDX, seed ISO, GPO ZIP) —
  these sit on the **Hyper-V host at D:\ISO\** (= /Volumes/ISO on your Mac).
  Claude Code invokes them over SSH.

Claude Code runs on your Mac, SSHs into the Hyper-V host (`nmadmin@server`)
for hypervisor work, and SSHs into lab VMs through the host as a jump. You
don't install anything on the Hyper-V host — PowerShell 7.6 and the Hyper-V
module are already present.

---

## Prerequisites

Check these **before** starting. If any fail, fix first.

### 1. Claude Code installed on your Mac

```bash
claude --version
```

### 2. Passwordless SSH to the Hyper-V host

```bash
ssh nmadmin@server 'hostname'
```

Should return the host's hostname instantly — no password prompt.

### 3. `/Volumes/ISO/` mounted (= `D:\ISO\` on host) and writable

```bash
ls /Volumes/ISO/
touch /Volumes/ISO/.write-test && rm /Volumes/ISO/.write-test && echo writable
```

### 4. Tools on the Mac

```bash
which qemu-img hdiutil curl
```

All three required. `qemu-img` via `brew install qemu` if missing. `hdiutil`
and `curl` are built-in on macOS.

### 5. ISOs and base VHDX staged on `/Volumes/ISO/`

These are ~2 GB total and you only stage them **once** (they persist across
lab rebuilds). See "Step 1 — Stage lab artifacts" below.

---

## Step 1 — Stage lab artifacts (one-time)

### 1a. Source ISOs

These should already be on `/Volumes/ISO/`:

```
debian-13.4.0-amd64-netinst.iso                                      ~650 MB
26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso
WS2025-2602-Security-Baseline.zip
```

### 1b. Build the router VHDX and seed ISO (one command)

```bash
cd ~/Developer/samba-addc-appliance    # wherever the repo lives
lab/stage-router-artifacts.sh --extra-dnsmasq lab/seed/dnsmasq-samba-lab.conf
```

Reads your `~/.ssh/id_ed25519.pub` automatically (override with `-k`), picks up
the repo's templates in `lab/seed/*.tpl`, writes two files to `/Volumes/ISO/`:

- `debian-13-router-base.vhdx` — shared read-only base (the Debian genericcloud
  qcow2 converted via `qemu-img`). Builds once; skipped on re-runs.
- `router1-seed.iso` — per-router NoCloud seed with your SSH key and the
  lab-specific dnsmasq reservations for WS2025-DC1 + samba-dc1. Always
  regenerated (cheap — ~1 second).

First run takes ~2 minutes (qcow2 download + conversion). Subsequent runs
take seconds.

For a **second** router (e.g., `router2` at `10.10.20.1` for a multi-site
test), pass different args:

```bash
lab/stage-router-artifacts.sh -n router2 -i 10.10.20.1    # no -extra-dnsmasq = generic router
```

### 1c. Copy lab/ scripts to the host

```bash
mkdir -p /Volumes/ISO/lab-scripts
cp lab/*.ps1 lab/*.xml /Volumes/ISO/lab-scripts/
```

Repeat this any time you edit a `lab/*.ps1` file.

---

## Step 2 — Build the lab

Claude Code can do this for you once the artifacts are staged. If you want
to run it yourself first to verify, these are the commands:

```bash
# Router (takes ~3 min — cloud-init installs packages and starts services)
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\New-LabRouter.ps1'

# Verify router is alive and NAT works
ssh -J nmadmin@server hm@10.10.10.1 'cat /var/log/router-ready.marker; \
    sudo nft list table ip nat'

# WS2025 DC (takes ~10-15 min for install + promotion + phase-2)
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\New-WS2025Lab.ps1'
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\Wait-DCReady.ps1'

# Security baseline (takes ~2 min)
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\Apply-SecurityBaseline.ps1'
```

The router and WS2025-DC1 are meant to persist across sessions — build them
once, keep them running, reuse.

---

## Step 3 — Create the Samba test VM

```bash
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\New-SambaTestVM.ps1 \
    -VMName samba-dc1 -Start'
```

The VM boots from the Debian netinst ISO. **You install manually.** During
install:

- Hostname: `samba-dc1`
- Domain: leave blank (domain is configured later by sconfig)
- Network: **DHCP** (router1's dnsmasq reserves `10.10.10.20` for the pinned
  MAC)
- Set a strong root password — you only use it at the console once, to
  finish the sudo + SSH key setup below
- Create the `debadmin` user with a throwaway password
- At "software selection", pick **only** "SSH server" and "standard system
  utilities"

When the installer reboots into the installed system, **log in at the
console as root** and run:

```
apt update && apt install -y sudo
echo 'debadmin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/debadmin
chmod 440 /etc/sudoers.d/debadmin
mkdir -p /home/debadmin/.ssh
chmod 700 /home/debadmin/.ssh
```

Now paste your Mac's ssh-ed25519 public key into
`/home/debadmin/.ssh/authorized_keys`:

```
cat > /home/debadmin/.ssh/authorized_keys
<paste your key — one line — then Ctrl-D>
```

```
chown -R debadmin:debadmin /home/debadmin/.ssh
chmod 600 /home/debadmin/.ssh/authorized_keys
```

Verify from your Mac:

```bash
ssh -J nmadmin@server debadmin@10.10.10.20 'sudo -n true && echo OK'
```

Should print `OK`. Then remove the install DVD:

```bash
ssh nmadmin@server 'Set-VMDvdDrive -VMName samba-dc1 -Path $null'
```

At this point the VM is ready and Claude Code can take over. Tell it
something like:

> "Debian is installed on samba-dc1 with debadmin passwordless sudo + SSH
> key. The VM is on 10.10.10.20 via DHCP. Please run prepare-image.sh,
> checkpoint as golden-image, then validate T1-T4 with the headless sconfig
> CLI and report."

---

## Troubleshooting

### Router VM doesn't come up

Cloud-init takes 2-3 min on first boot. If after 5 min `ssh -J nmadmin@server
hm@10.10.10.1` still fails:

- `ssh nmadmin@server '(Get-VM router1).State'` — is it running?
- `ssh nmadmin@server '(Get-VMNetworkAdapter -VMName router1).IPAddresses'` —
  is the LAN NIC reporting an IP?
- If not, cloud-init may have failed. `vmconnect localhost router1`, log in
  as `hm` (no password — key-only), `sudo journalctl -u cloud-init`.

### WS2025 `Wait-DCReady.ps1` times out

Check phase state:

```bash
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\Diag-WS2025.ps1'
```

Common states:
- Phase 1 stuck at "Using adapter: Ethernet" → an early bug in
  FirstLogon-PromoteToDC.ps1 that's since fixed (Set-NetIPInterface -Dhcp
  Disabled before IP removal). If you see this on an old script, re-stage
  `lab/FirstLogon-PromoteToDC.ps1` to `D:\ISO\lab-scripts\`, rebuild the
  VM.
- Phase 2 RunOnce never fires → autologon consumed all 2 counts without
  triggering phase 2. Manually re-invoke:
  `ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\Run-Phase2.ps1'`

### VM doesn't get DHCP from the router

Check dnsmasq on the router:

```bash
ssh -J nmadmin@server hm@10.10.10.1 'sudo cat /var/lib/misc/dnsmasq.leases; \
    sudo journalctl -u dnsmasq -n 50'
```

The VM must have its MAC pinned to match a reservation in
`/etc/dnsmasq.d/lab.conf`. If you're adding a new test VM, add its MAC to
the reservations (or let it get a dynamic lease).

### Rebuild the router from scratch

```bash
ssh nmadmin@server 'Stop-VM router1 -Force -ErrorAction SilentlyContinue; \
    Remove-VM router1 -Force; Remove-Item D:\Lab\router1 -Recurse -Force'
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\New-LabRouter.ps1'
```

Takes ~5 min since the base VHDX is already on `D:\ISO\`.

### Rebuild the whole lab from scratch

```bash
ssh nmadmin@server 'Stop-VM samba-dc1,WS2025-DC1,router1 -Force -ErrorAction SilentlyContinue; \
    Remove-VM samba-dc1,WS2025-DC1,router1 -Force; \
    Remove-VMSwitch Lab-NAT -Force -ErrorAction SilentlyContinue; \
    Remove-Item D:\Lab -Recurse -Force'
```

Then re-run Step 2 and Step 3 above.

---

## File map

```
Repo root
├── CLAUDE.md            Claude Code's operational reference (deep lab details)
├── HANDOFF.md           This file (user-facing setup)
├── prepare-image.sh     Debian image prep (installs Samba, pwsh, nftables, etc.)
├── samba-sconfig.sh     whiptail TUI + headless CLI for deployment config
├── .gitignore
├── lab/
│   ├── New-LabRouter.ps1            build router1
│   ├── New-WS2025Lab.ps1            build WS2025-DC1
│   ├── FirstLogon-PromoteToDC.ps1   promotion script (phases via RunOnce)
│   ├── unattend-ws2025-core.xml     Panther unattend
│   ├── Apply-SecurityBaseline.ps1   import + link baseline GPOs
│   ├── New-SambaTestVM.ps1          create the Debian test VM
│   ├── Wait-DCReady.ps1             poll setup-complete.marker
│   └── seed/                        cloud-init user-data for router1
│       ├── user-data
│       ├── meta-data
│       └── network-config
└── test-results/                    Claude Code's test artifacts + diagrams
```
