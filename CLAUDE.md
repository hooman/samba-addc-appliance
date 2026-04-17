# CLAUDE.md — Samba AD DC Appliance Test Environment (Hyper-V Lab, v2)

## Mission

Build and test a **Samba Active Directory Domain Controller appliance** on
Debian 13 (Trixie). Deliverables in the repo root:

- `prepare-image.sh` — one-time Debian image prep (installs Samba, pwsh,
  nftables, ldap-utils, chrony skeleton; masks file-server services)
- `samba-sconfig.sh` — whiptail TUI for deployment config (provision /
  join / RODC / harden / diagnose)

You (Claude Code) drive a Hyper-V lab from the Mac. The lab models a realistic
network: the VM under test **boots onto a DHCP-served LAN with internet
reachable**, exactly like a real appliance deployment. The WS2025 forest with
baseline applied sits on the same LAN (or not, depending on test scenario).

## Lab topology — v2

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Mac (Claude Code runs here)                                              │
│  ~/.ssh/id_ed25519 — key-based SSH to:                                   │
│    - nmadmin@server  (Hyper-V host, PowerShell 7.6)                      │
│    - hm@10.10.10.1   (router1, via jump host)                            │
│    - debadmin@10.10.10.N (any lab VM, via jump host)                     │
│                                                                          │
│  /Volumes/ISO = D:\ISO\ on host (file transfer)                          │
└──────────────────────────────────────────────────────────────────────────┘
         │
         ▼ ssh nmadmin@server
┌──────────────────────────────────────────────────────────────────────────┐
│ Hyper-V host: server   (Windows Server 2025, PowerShell 7.6, Hyper-V)    │
│                                                                          │
│  Switches:                                                               │
│    PCI 1G Port 1    External — WAN to real network                       │
│    Lab-NAT          Internal — 10.10.10.0/24 (new in v2)                 │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐     │
│  │  PCI 1G Port 1 (external)                    ───► Internet      │     │
│  │    │                                                            │     │
│  │    │ WAN (eth0, DHCP from real network)                         │     │
│  │    ▼                                                            │     │
│  │  ┌────────────────────────┐                                     │     │
│  │  │ router1                │                                     │     │
│  │  │   Debian genericcloud  │   nftables masquerade (NAT)         │     │
│  │  │   cloud-init configured│   dnsmasq (DHCP + DNS forwarder)    │     │
│  │  └─────┬──────────────────┘                                     │     │
│  │        │ LAN (eth1, 10.10.10.1/24)                              │     │
│  │        │                                                        │     │
│  │  ┌─────▼──────────────────────────────────────────────────┐     │     │
│  │  │  Lab-NAT (internal) — 10.10.10.0/24                    │     │     │
│  │  │                                                        │     │     │
│  │  │  host vNIC           10.10.10.X  (via DHCP)            │     │     │
│  │  │                                                        │     │     │
│  │  │  ┌────────────────┐       ┌────────────────┐           │     │     │
│  │  │  │ WS2025-DC1     │       │ samba-dc1      │           │     │     │
│  │  │  │ 10.10.10.10    │       │ 10.10.10.20    │           │     │     │
│  │  │  │ lab.test/LAB   │       │ Debian 13      │           │     │     │
│  │  │  │ baseline GPOs  │       │ samba-sconfig  │           │     │     │
│  │  │  └────────────────┘       └────────────────┘           │     │     │
│  │  │                                                        │     │     │
│  │  │  DHCP dynamic pool: 10.10.10.100-200                   │     │     │
│  │  │  Reservations (dnsmasq on router1):                    │     │     │
│  │  │    00:15:5D:0A:0A:0A  -> WS2025-DC1  10.10.10.10       │     │     │
│  │  │    00:15:5D:0A:0A:14  -> samba-dc1   10.10.10.20       │     │     │
│  │  └────────────────────────────────────────────────────────┘     │     │
│  └─────────────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────────────┘
```

### Addressing

| Role | Hostname | MAC (pinned) | IP (dnsmasq reservation) |
|------|----------|------|------|
| Gateway/DHCP/DNS | router1 | (not pinned) | `10.10.10.1/24` (static on LAN) |
| WS2025 DC (first) | WS2025-DC1 | `00:15:5D:0A:0A:0A` | `10.10.10.10/24` |
| Samba DC (primary test VM) | samba-dc1 | `00:15:5D:0A:0A:14` | `10.10.10.20/24` |
| Samba DC (optional second) | samba-dc2 | `00:15:5D:0A:0A:15` | `10.10.10.21/24` |
| Hyper-V host vNIC on Lab-NAT | — | — | dynamic DHCP (from router) |

The router also delegates the `lab.test` zone to the two DC IPs, so any LAN
client pointing DNS at the router gets correct AD resolution.

---

## Connection details

### Hyper-V host

```
Host:   server
SSH:    ssh nmadmin@server        (key-based, PowerShell 7.6 login shell)
Mount:  /Volumes/ISO ↔ D:\ISO\
```

### Credentials (lab-only, never used outside the lab)

```
WS2025 LAB\Administrator / DSRM:   P@ssword123456!
Domain:                            lab.test (LAB NetBIOS)
Debian root password:              (set during install)
Debian debadmin user:              passwordless sudo, SSH key only
router1 hm user:                   passwordless sudo, SSH key only
```

### Staged on D:\ISO\

```
debian-13.4.0-amd64-netinst.iso                       Debian install media
debian-13-router-base.vhdx                            router base (from qcow2)
router1-seed.iso                                      cloud-init seed for router
26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso
                                                      Windows Server 2025 Eval
WS2025-2602-Security-Baseline.zip                     MSFT baseline GPO bundle
lab-scripts\                                          host-side PowerShell scripts
```

---

## Working with the lab

### Run a command on the Hyper-V host

```bash
# One-liner
ssh nmadmin@server 'Get-VM | Format-Table Name,State,Uptime'

# Multi-line via heredoc (the login shell is pwsh)
ssh nmadmin@server << 'EOF'
Get-VMSwitch
Get-VM
EOF

# Script file staged in D:\ISO\lab-scripts\
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\Wait-DCReady.ps1'
```

Heredocs with `$...` variables can get mangled by the local zsh before they
reach ssh. When a script grows beyond one line or uses any `$vars`, put it in
a `.ps1` file in `D:\ISO\lab-scripts\` and invoke it by path.

### Run a command inside a Linux VM (router or Samba DC)

```bash
# Via the host as jump (the host has a vNIC on Lab-NAT via DHCP)
ssh -J nmadmin@server hm@10.10.10.1 'nft list ruleset'
ssh -J nmadmin@server debadmin@10.10.10.20 'sudo systemctl is-active samba-ad-dc'

# Mac → VM: direct scp
scp -J nmadmin@server prepare-image.sh debadmin@10.10.10.20:/tmp/
```

Optional `~/.ssh/config` on the Mac:

```
Host hv-host
    HostName server
    User nmadmin

Host router1
    HostName 10.10.10.1
    User hm
    ProxyJump hv-host

Host samba-dc1
    HostName 10.10.10.20
    User debadmin
    ProxyJump hv-host
```

### Run a command inside WS2025-DC1 (PowerShell Direct, no network)

```bash
ssh nmadmin@server << 'EOF'
$cred = New-Object PSCredential('LAB\Administrator',
    (ConvertTo-SecureString 'P@ssword123456!' -AsPlainText -Force))
Invoke-Command -VMName 'WS2025-DC1' -Credential $cred -ScriptBlock {
    Get-ADDomain; Get-ADDomainController -Filter *
}
EOF
```

Or stage a `.ps1` in `D:\ISO\lab-scripts\` (more reliable for anything
multi-line).

### Packages inside the Samba VM

The VM is on Lab-NAT with router1 providing NAT. `apt-get update` and `apt
install X` work out of the box — no add/remove-NIC dance required. You can
still manually attach a second NIC for unusual cases, but the baseline lab
flow doesn't need it.

---

## Persistent lab infrastructure — DO NOT TEAR DOWN CASUALLY

These are rebuilt via scripts in `lab/` but are designed to stay up across
sessions:

1. **Switch `Lab-NAT`** (Hyper-V internal)
2. **VM `router1`** — gateway, DHCP server, DNS forwarder, NAT
3. **VM `WS2025-DC1`** — first DC of `lab.test`, baseline GPOs linked
4. **OU structure** in AD:
   ```
   DC=lab,DC=test
     ├── Domain Controllers   (baseline DC GPO)
     └── OU=Lab
           ├── OU=TestDCs         (additional DCs under test)
           └── OU=TestServers     (baseline Member Server GPO)
   ```
5. **Baseline GPOs** imported, linked per table above, ADMX in SYSVOL central
   store.

### Health check (run at start of every session)

```bash
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\Health-Check.ps1'
```

(Health-Check.ps1 needs to be updated for lab-v2 — TODO when we next touch
lab scripts.)

---

## lab/ script layout (v2)

| Script | Purpose |
|--------|---------|
| `New-LabRouter.ps1` | Build router1 VM from staged VHDX + cloud-init seed ISO |
| `New-WS2025Lab.ps1` | Build WS2025-DC1 (DISM-apply WIM, inject unattend + FirstLogon script, boot) |
| `FirstLogon-PromoteToDC.ps1` | Runs inside WS2025-DC1: phase 1 (role install) triggers promotion + reboot; RunOnce re-fires it for phase 2 (OUs, reverse zone, forwarder) |
| `unattend-ws2025-core.xml` | Panther unattend for WS2025 Server Core |
| `Apply-SecurityBaseline.ps1` | Push GPO zip to DC, import, link DC baseline to Domain Controllers, Member Server baseline to Lab/TestServers (exact-name match, not wildcard) |
| `New-SambaTestVM.ps1` | Create a fresh Debian VM on Lab-NAT with a pinned MAC matching a dnsmasq reservation; user then installs Debian manually |
| `Wait-DCReady.ps1` | Poll `C:\Setup\setup-complete.marker` via PSDirect after WS2025 VM boots |

All scripts are idempotent where reasonable: re-running skips existing
resources rather than destroying them. Destructive rebuild is always
`Remove-VM <name> -Force` first.

### One-time lab build

```bash
# 0. Prerequisites: Debian cloud image + seed ISO + router base VHDX staged
#    at D:\ISO\debian-13-router-base.vhdx  and  D:\ISO\router1-seed.iso
#    (These are produced on the Mac side via qemu-img and hdiutil; see the
#    "Staging router artifacts" section.)

ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\New-LabRouter.ps1'
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\New-WS2025Lab.ps1'
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\Wait-DCReady.ps1'
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\Apply-SecurityBaseline.ps1'
```

### Staging router artifacts (one command, on Mac)

```bash
cd <repo>
lab/stage-router-artifacts.sh --extra-dnsmasq lab/seed/dnsmasq-samba-lab.conf
```

This script:

1. Downloads Debian 13 genericcloud qcow2 (~300 MB, cached at
   `/Volumes/ISO/debian-13-genericcloud-amd64.qcow2`)
2. Converts to VHDX with `qemu-img`, writes `/Volumes/ISO/debian-13-router-base.vhdx`
3. Substitutes placeholders in `lab/seed/*.tpl` (hostname, FQDN, LAN IP, SSH
   pubkey from `~/.ssh/id_ed25519.pub`, DHCP pool, extra dnsmasq reservations)
4. Builds the NoCloud seed ISO via `hdiutil makehybrid`, writes
   `/Volumes/ISO/<hostname>-seed.iso`

Skip-if-exists on the base VHDX; always regenerate the seed ISO. Run
`--help` for options (`-n` hostname, `-i` LAN IP, `-d` domain, `-k` pubkey
path, `--extra-dnsmasq` extra config snippet to merge into dnsmasq.d).

The base VHDX is ~1.2 GB; the seed ISO is ~1 MB. Both stay on the ISO share
permanently and are reused across lab rebuilds.

---

## Test VM lifecycle (samba-dc1)

### Initial setup (once per VM identity)

1. Create the Debian VM on Lab-NAT with a pinned MAC that matches the
   dnsmasq reservation for the intended IP:
   ```bash
   ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\New-SambaTestVM.ps1 -VMName samba-dc1 -Start'
   ```

2. Install Debian via `vmconnect localhost samba-dc1`:
   - Minimal install, "SSH server" + "standard system utilities" only
   - Hostname: `samba-dc1`
   - Network: **DHCP** (router1's dnsmasq will hand out 10.10.10.20 via
     reservation)
   - Root password set, `debadmin` user created
   - Install takes ~5 minutes

3. At the console after first boot, log in as root and set up `debadmin`
   for passwordless sudo + SSH key:
   ```
   apt update && apt install -y sudo
   echo 'debadmin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/debadmin
   chmod 440 /etc/sudoers.d/debadmin
   mkdir -p /home/debadmin/.ssh && chmod 700 /home/debadmin/.ssh
   # copy Mac ~/.ssh/id_ed25519.pub content here:
   printf 'ssh-ed25519 AAAA... hooman@mac.com\n' >> /home/debadmin/.ssh/authorized_keys
   chown -R debadmin:debadmin /home/debadmin/.ssh
   chmod 600 /home/debadmin/.ssh/authorized_keys
   ```

4. Verify from the Mac:
   ```bash
   ssh -J nmadmin@server debadmin@10.10.10.20 'sudo -n true && echo OK'
   ```

5. Remove the install DVD:
   ```bash
   ssh nmadmin@server 'Set-VMDvdDrive -VMName samba-dc1 -Path $null'
   ```

6. Copy the appliance scripts and run image prep — **no temporary NIC
   needed**, internet is already reachable via router1:
   ```bash
   scp -J nmadmin@server prepare-image.sh samba-sconfig.sh debadmin@10.10.10.20:/tmp/
   ssh -J nmadmin@server debadmin@10.10.10.20 'sudo install -m 0755 /tmp/prepare-image.sh /root/'
   ssh -J nmadmin@server debadmin@10.10.10.20 'sudo install -m 0755 /tmp/samba-sconfig.sh /usr/local/sbin/samba-sconfig'
   ssh -J nmadmin@server debadmin@10.10.10.20 'sudo bash /root/prepare-image.sh'
   ```

7. Shutdown, checkpoint as `golden-image`:
   ```bash
   ssh -J nmadmin@server debadmin@10.10.10.20 'sudo shutdown -h now' || true
   # wait until off
   ssh nmadmin@server 'Checkpoint-VM -Name samba-dc1 -SnapshotName golden-image'
   ```

### Per test cycle

```bash
ssh nmadmin@server << 'EOF'
Stop-VM -Name samba-dc1 -Force -ErrorAction SilentlyContinue
Restore-VMCheckpoint -Name golden-image -VMName samba-dc1 -Confirm:$false
Start-VM -Name samba-dc1
EOF

# Run the scenario via the headless CLI (see samba-sconfig.sh):
ssh -J nmadmin@server debadmin@10.10.10.20 \
    'sudo env SC_REALM=lab.test SC_NETBIOS=LAB SC_DC=10.10.10.10 SC_PASS=P@ssword123456! \
     samba-sconfig join-dc'
```

### Cleanup at end of session

Only the test VMs. Never touch router1 or WS2025-DC1 (they're persistent).

```bash
ssh nmadmin@server << 'EOF'
Stop-VM -Name samba-dc1 -Force -ErrorAction SilentlyContinue
Restore-VMCheckpoint -Name golden-image -VMName samba-dc1 -Confirm:$false
Stop-VM -Name samba-dc1 -Force
EOF
```

---

## Test scenarios

### Scenario 1: Standalone new forest (no existing DC in lab)

```bash
ssh -J nmadmin@server debadmin@10.10.10.20 << 'EOF'
sudo rm -f /etc/samba/smb.conf
sudo systemctl stop samba-ad-dc 2>/dev/null
sudo tee /etc/krb5.conf > /dev/null << 'KRB'
[libdefaults]
  default_realm = TEST.LAN
  dns_lookup_kdc = true
  dns_lookup_realm = false
KRB
sudo samba-tool domain provision \
    --realm=TEST.LAN --domain=TEST \
    --server-role=dc --dns-backend=SAMBA_INTERNAL \
    --adminpass='P@ssword123456!' \
    --option='dns forwarder = 10.10.10.1'
sudo systemctl unmask samba-ad-dc
sudo systemctl enable --now samba-ad-dc
sleep 5
sudo net ads info -P
EOF
```

### Scenario 2: Join existing WS2025 forest as additional DC (primary test)

Use the headless CLI that drives samba-sconfig's fixes (FL detect, PTR, SYSVOL
seed, TLS cert, chrony re-point):

```bash
ssh -J nmadmin@server debadmin@10.10.10.20 \
    'sudo env SC_REALM=lab.test SC_NETBIOS=LAB SC_DC=10.10.10.10 SC_PASS=P@ssword123456! \
     samba-sconfig join-dc 2>&1 | grep -E "^\\[sconfig\\]"'
```

Expected clean output on first try:

```
[sconfig] forest FL probe: 2016
[sconfig] joining LAB.TEST as DC via 10.10.10.10 (FL=2016)...
[sconfig] PTR registered on 10.10.10.10
[sconfig] SYSVOL seeded. Resetting NTACLs...
[sconfig] chrony repointed at 10.10.10.10
[sconfig] TLS cert installed
[sconfig] JOIN SUCCESS (FL=2016) — TLS cert has SAN, PTR registered, SYSVOL seeded
```

### Scenario 3: RODC in WS2025 forest

Same as Scenario 2 with `SC_ROLE=RODC`:

```bash
ssh -J nmadmin@server debadmin@10.10.10.20 \
    'sudo env SC_REALM=lab.test SC_NETBIOS=LAB SC_DC=10.10.10.10 SC_PASS=P@ssword123456! \
     SC_ROLE=RODC samba-sconfig join-dc'
```

### Verifying from the WS2025 side

```bash
# Invoke via PSDirect (use a staged .ps1 if the heredoc has any $vars)
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\T3-FullVerify.ps1'
```

---

## Debugging

### Key logs

| Location | Contents |
|---|---|
| router1: `journalctl -u dnsmasq -f` | DHCP leases, DNS queries (verbose by default) |
| router1: `journalctl -u nftables` | NAT / firewall changes |
| Samba VM: `journalctl -u samba-ad-dc -f` | Live Samba logs |
| Samba VM: `/var/log/samba/` | Per-service Samba logs |
| WS2025: `Get-WinEvent -LogName 'Directory Service'` | AD events (especially 1925, 1725) |
| Hyper-V host: `Get-WinEvent -LogName Microsoft-Windows-Hyper-V-Worker-Admin` | VM lifecycle events |

### Common failures joining WS2025

| Symptom | Root cause | Resolution |
|---|---|---|
| `samba-tool domain join` hangs at "Looking for DC" | DNS not pointing at WS2025 | sconfig `join-dc` sets resolv.conf automatically; check router dnsmasq is up |
| `clock skew too great` | Guest clock drift | Hyper-V Integration Services keeps VMs in sync; if disabled, `chronyc makestep` |
| `WERR_DS_INCOMPATIBLE_VERSION` on `DsAddEntry` | Samba advertising 2008_R2 FL against 2016+ forest | sconfig auto-detects via rootDSE and passes `ad dc functional level = 2016` |
| `repadmin /showrepl` reports 8524 DNS lookup failure | Samba DC's PTR missing on WS2025 reverse zone | sconfig `register_own_ptr` handles this post-join |
| `LDAP_STRONG_AUTH_REQUIRED` | Baseline requires signing | Samba default is to sign; verify `ldap server require strong auth = yes` in smb.conf (sconfig hardening sets this) |
| SYSVOL `Policies/` empty on Samba | Samba has no DFSR | sconfig seeds via smbclient post-join; set up `sysvol-sync` timer for ongoing |

### Useful investigation commands

```bash
# From Samba DC
sudo testparm -s 2>&1 | head -30
sudo samba-tool dbcheck --cross-ncs
sudo samba-tool drs showrepl
sudo samba-tool dns query 10.10.10.10 lab.test @ ALL -U 'LAB\\Administrator' --password=P@ssword123456!
sudo net ads info -P
sudo net ads testjoin
sudo wbinfo -t

# From the WS2025 side (via staged .ps1)
ssh nmadmin@server 'pwsh -File D:\ISO\lab-scripts\T3-FullVerify.ps1'
```

---

## Session checklist

**Start of session:**
- [ ] Health check (Health-Check.ps1) — router1 + WS2025-DC1 running, domain healthy
- [ ] `samba-dc1` VM exists with `golden-image` checkpoint (if testing join flow)
- [ ] Scripts in repo current; lab-scripts on host current

**End of session:**
- [ ] Commit script changes to repo
- [ ] `samba-dc1` reverted to golden-image, powered off
- [ ] Test logs saved in `test-results/`
- [ ] **router1 + WS2025-DC1 still running** ← critical (persistent infra)
- [ ] Handoff notes updated if anything surprised you

---

## File layout

```
Repo root
├── CLAUDE.md                       (this file)
├── HANDOFF.md                      (user-facing setup checklist)
├── prepare-image.sh                (Debian image prep)
├── samba-sconfig.sh                (TUI + headless CLI)
├── lab/
│   ├── New-LabRouter.ps1           (build router1)
│   ├── New-WS2025Lab.ps1           (build WS2025-DC1)
│   ├── FirstLogon-PromoteToDC.ps1  (runs inside WS2025-DC1 via autologon + RunOnce)
│   ├── unattend-ws2025-core.xml    (Panther unattend)
│   ├── Apply-SecurityBaseline.ps1  (import + link baseline GPOs)
│   ├── New-SambaTestVM.ps1         (create empty Debian VM on Lab-NAT)
│   ├── Wait-DCReady.ps1            (poll for setup-complete marker)
│   └── seed/
│       ├── user-data               (cloud-init for router1)
│       ├── meta-data
│       └── network-config
└── test-results/                   (per-scenario logs, REPORT.md, topology.drawio)
```
