# CLAUDE.md — Samba AD DC Appliance Test Environment (Hyper-V Lab)

## Mission

Build and test a **Samba Active Directory Domain Controller appliance** on
Debian 13 (Trixie). Deliverables are two scripts in the repo root:

- `prepare-image.sh` — one-time Debian image prep
- `samba-sconfig.sh` — whiptail TUI for deployment config

You (Claude Code) have a Hyper-V lab to test these against. The lab includes a
**Windows Server 2025 Domain Controller** with the **WS2025 Security Baseline**
applied — this is the realistic target environment for a Samba DC to join.

Your job: deploy the scripts to Debian test VMs, verify they work, test the
three main scenarios (new forest, additional DC in WS2025 domain, RODC), and
iterate on fixes. **Do not tear down the lab infrastructure** — the WS2025 DC
and internal switch persist. Only test VMs should be rebuilt.

---

## Environment

```
┌────────────────────────────────────────────────────────────────┐
│ Mac (Claude Code runs here)                                    │
│  ~/.ssh key for nmadmin@__HYPERV_HOST__                        │
│  /Volumes/ISO  →  D:\ISO\ on host  (for file transfer)         │
│                                                                 │
│  ssh nmadmin@__HYPERV_HOST__    (lands in PowerShell 7.6)      │
│  ssh -J nmadmin@__HYPERV_HOST__ root@172.22.0.X   (to VMs)     │
└────────────────────────────────────────────────────────────────┘
         │
         ▼
┌────────────────────────────────────────────────────────────────┐
│ Hyper-V Host: __HYPERV_HOST__   (shell: PowerShell 7.6)        │
│   User: nmadmin  (admin; key-based SSH, no password)           │
│   D:\ISO\      — ISO library (= /Volumes/ISO on Mac)           │
│   D:\Lab\      — VM files                                      │
│                                                                 │
│   Pre-loaded modules: Hyper-V, ActiveDirectory                 │
│                                                                 │
│   ┌──────────────────────────────────────────────────────┐     │
│   │  Internal Switch: "Lab-Internal"  (172.22.0.0/24)    │     │
│   │  Host vNIC: 172.22.0.1                               │     │
│   │                                                       │     │
│   │  ┌────────────────┐    ┌────────────────┐            │     │
│   │  │ WS2025-DC1     │    │ samba-dc1      │            │     │
│   │  │ 172.22.0.10    │    │ 172.22.0.20    │            │     │
│   │  │ lab.test / LAB │    │ Debian 13      │            │     │
│   │  │ (persistent)   │    │ (test VM)      │            │     │
│   │  └────────────────┘    └────────────────┘            │     │
│   └──────────────────────────────────────────────────────┘     │
└────────────────────────────────────────────────────────────────┘
```

### Lab network plan

| Role | Hostname | IP | Purpose |
|------|----------|------|---------|
| Hyper-V host (vNIC) | — | 172.22.0.1 | Gateway + jump host |
| WS2025 DC (first) | ws2025-dc1 | 172.22.0.10 | lab.test forest root |
| Samba test VM 1 | samba-dc1 | 172.22.0.20 | Primary test VM |
| Samba test VM 2 | samba-dc2 | 172.22.0.21 | For replication tests |

The internal switch has **no NAT** — VMs can only reach each other and the
host. For package updates, see "Getting packages into VMs" below.

---

## Connection Details (fill in before handoff)

### Hyper-V Host

```
Hostname/IP:    __HYPERV_HOST__
SSH:            ssh nmadmin@__HYPERV_HOST__   (key-based, no password)
Shell:          PowerShell 7.6
Admin rights:   nmadmin is full admin
ISO share:      /Volumes/ISO (Mac) ↔ D:\ISO\ (host)
```

### Credentials (lab-only)

```
WS2025 local Admin / Domain Admin / DSRM:  P@ssword123456!
Domain:                                     lab.test / LAB (NetBIOS)
Debian root password:                       (set during manual install)
```

### Available ISOs in D:\ISO\

- `debian-13.4.0-amd64-netinst.iso` — Debian install target
- `26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso` — WS2025 Eval
- `WS2025-2602-Security-Baseline.zip` — GPO backups + ADMX + import scripts

---

## How to interact with this environment

### Running commands on the Hyper-V host

```bash
# Single command
ssh nmadmin@__HYPERV_HOST__ 'Get-VM | Format-Table Name,State,Uptime'

# Multi-line via heredoc (note: ssh invokes pwsh automatically since it's the login shell)
ssh nmadmin@__HYPERV_HOST__ << 'EOF'
Get-VMSwitch
Get-VM
EOF

# Run a PowerShell script file on the host
ssh nmadmin@__HYPERV_HOST__ 'pwsh -File D:\Lab\scripts\New-WS2025Lab.ps1'
```

### Running commands on Windows VMs (PowerShell Direct)

PowerShell Direct works over VMBus — no network needed. Always available once
the VM is booted past OOBE. Always wrap commands so they run on the **host**,
which then invokes into the VM:

```bash
ssh nmadmin@__HYPERV_HOST__ << 'EOF'
$cred = New-Object PSCredential('LAB\Administrator',
    (ConvertTo-SecureString 'P@ssword123456!' -AsPlainText -Force))
Invoke-Command -VMName 'WS2025-DC1' -Credential $cred -ScriptBlock {
    Get-ADDomain
}
EOF
```

### Running commands on Linux VMs

SSH with the host as jump host:

```bash
ssh -J nmadmin@__HYPERV_HOST__ root@172.22.0.20
```

Or set up `~/.ssh/config` on the Mac for convenience:

```
Host hv-host
    HostName __HYPERV_HOST__
    User nmadmin

Host samba-dc1
    HostName 172.22.0.20
    User root
    ProxyJump hv-host

Host samba-dc2
    HostName 172.22.0.21
    User root
    ProxyJump hv-host
```

### Transferring files

```bash
# Mac → Host (via mounted share)
cp prepare-image.sh /Volumes/ISO/

# Host → Linux VM (PowerShell Direct Copy-VMFile works on Debian with hv_utils)
ssh nmadmin@__HYPERV_HOST__ << 'EOF'
Copy-VMFile -Name 'samba-dc1' -SourcePath 'D:\ISO\prepare-image.sh' `
    -DestinationPath '/root/prepare-image.sh' -FileSource Host -CreateFullPath -Force
EOF

# Host → Windows VM
ssh nmadmin@__HYPERV_HOST__ << 'EOF'
Copy-VMFile -Name 'WS2025-DC1' -SourcePath 'D:\ISO\WS2025-2602-Security-Baseline.zip' `
    -DestinationPath 'C:\Setup\WS2025-2602-Security-Baseline.zip' -FileSource Host -CreateFullPath -Force
EOF

# Mac → Linux VM (direct via jump)
scp -J nmadmin@__HYPERV_HOST__ prepare-image.sh root@172.22.0.20:/root/
```

### Getting packages into VMs (no NAT on internal switch)

The internal switch has no route to the internet. Three options:

**Option A — ICS (enables NAT, easiest)**
Enable Internet Connection Sharing on the host's external NIC sharing to the
`vEthernet (Lab-Internal)` adapter. One-time setup; makes 172.22.0.1 act as
a NAT gateway.

**Option B — Temporary external NIC on the VM**
```powershell
Add-VMNetworkAdapter -VMName 'samba-dc1' -SwitchName 'Default Switch'
# Run updates in VM, then remove when done
Remove-VMNetworkAdapter -VMName 'samba-dc1' -Name 'Network Adapter 2'
```

**Option C — Local HTTP cache** — overkill for a lab; skip.

If running `prepare-image.sh`, it needs package installs, so do this BEFORE
starting the script. Or: include external NIC, run prep, remove NIC, snapshot.

---

## Persistent Lab Infrastructure — DO NOT TEAR DOWN

These exist once and stay up. If missing, rebuild via scripts in `lab/`.
**Never remove them at the end of a test run.**

1. **Switch `Lab-Internal`** (172.22.0.0/24)
2. **VM `WS2025-DC1`** at 172.22.0.10 — first DC of `lab.test`
3. **Security baseline GPOs** imported and linked to OUs
4. **OU structure** in AD:
   ```
   lab.test
     └── OU=Lab
           ├── OU=TestDCs       (Samba DCs join here)
           └── OU=TestServers   (Windows test members)
   ```

### Health check (run at start of every session)

```bash
ssh nmadmin@__HYPERV_HOST__ << 'EOF'
$ErrorActionPreference = 'SilentlyContinue'

# Switch
$sw = Get-VMSwitch -Name Lab-Internal
if ($sw) { "[OK] Switch Lab-Internal present" } else { "[MISSING] Switch Lab-Internal" }

# DC VM
$vm = Get-VM -Name WS2025-DC1
if ($vm -and $vm.State -eq 'Running') {
    "[OK] WS2025-DC1 running (uptime: $($vm.Uptime))"
} elseif ($vm) {
    "[WARN] WS2025-DC1 state: $($vm.State) — starting..."
    Start-VM -Name WS2025-DC1
} else {
    "[MISSING] WS2025-DC1 — run lab/New-WS2025Lab.ps1"
}

# DC services via PSDirect
$cred = New-Object PSCredential('LAB\Administrator',
    (ConvertTo-SecureString 'P@ssword123456!' -AsPlainText -Force))
try {
    Invoke-Command -VMName WS2025-DC1 -Credential $cred -ScriptBlock {
        "  AD domain: $((Get-ADDomain).DNSRoot)"
        "  DNS zone:  $((Get-DnsServerZone -Name lab.test).ZoneName)"
        "  GPOs:      $((Get-GPO -All).Count) total"
    } -ErrorAction Stop
} catch {
    "[WARN] Could not reach DC via PSDirect — may still be booting"
}
EOF
```

---

## Lab Setup Scripts

The `lab/` directory contains PowerShell scripts that build the persistent
infrastructure. **Run these once per environment** — they're idempotent and
won't destroy existing resources.

### One-time: build the lab

Copy scripts to the host first:
```bash
# From Mac repo directory:
cp -r lab/ /Volumes/ISO/lab-scripts/
# On host, scripts live at D:\ISO\lab-scripts\
```

Then run on the host:
```bash
# 1. Create switch + WS2025 DC VM (~15 min; VM builds itself)
ssh nmadmin@__HYPERV_HOST__ 'pwsh -File D:\ISO\lab-scripts\New-WS2025Lab.ps1'

# 2. Wait for DC to finish setup (check setup-complete.marker)
ssh nmadmin@__HYPERV_HOST__ << 'EOF'
$cred = New-Object PSCredential('LAB\Administrator',
    (ConvertTo-SecureString 'P@ssword123456!' -AsPlainText -Force))
do {
    Start-Sleep -Seconds 30
    try {
        $done = Invoke-Command -VMName WS2025-DC1 -Credential $cred -ScriptBlock {
            Test-Path 'C:\Setup\setup-complete.marker'
        } -ErrorAction Stop
        Write-Host "  setup-complete: $done"
    } catch {
        Write-Host "  still booting..."
    }
} while (-not $done)
EOF

# 3. Apply security baseline
ssh nmadmin@__HYPERV_HOST__ 'pwsh -File D:\ISO\lab-scripts\Apply-SecurityBaseline.ps1'
```

### lab/ script summary

| Script | Purpose | Idempotent |
|--------|---------|------------|
| `New-WS2025Lab.ps1` | Creates switch + WS2025-DC1 VM via DISM+Panther injection | Yes (skips if VM exists) |
| `unattend-ws2025-core.xml` | Panther unattend for WS2025 Server Core | — |
| `FirstLogon-PromoteToDC.ps1` | Runs inside VM: configures IP, installs AD DS, promotes DC | Yes (phase markers) |
| `Apply-SecurityBaseline.ps1` | Imports baseline ZIP, copies ADMX to SYSVOL, links GPOs | Mostly (GPLinks may duplicate) |
| `New-SambaTestVM.ps1` | Creates fresh Debian VM with ISO attached | No (fails if VM exists) |

---

## Test VM Lifecycle

Treat Debian VMs as disposable. The workflow:

### Initial setup (once per VM)

1. Create VM:
   ```bash
   ssh nmadmin@__HYPERV_HOST__ 'pwsh -File D:\ISO\lab-scripts\New-SambaTestVM.ps1 -VMName samba-dc1 -Start'
   ```

2. Install Debian manually via `vmconnect localhost samba-dc1`:
   - Minimal install, SSH server only, no desktop
   - Hostname: `samba-dc1` (short)
   - Static IP: 172.22.0.20/24, gateway 172.22.0.1, DNS 172.22.0.10 (but
     until prepare-image runs, the VM needs internet — use Option B above
     during install, set DNS to 1.1.1.1 temporarily)
   - Root password set, no regular user
   - Takes ~5 minutes

3. Remove the install DVD:
   ```bash
   ssh nmadmin@__HYPERV_HOST__ 'Set-VMDvdDrive -VMName samba-dc1 -Path $null'
   ```

4. Temporarily attach external NIC for package downloads:
   ```bash
   ssh nmadmin@__HYPERV_HOST__ "Add-VMNetworkAdapter -VMName samba-dc1 -SwitchName 'Default Switch'"
   ssh -J nmadmin@__HYPERV_HOST__ root@172.22.0.20 'dhclient eth1 || ip link set eth1 up && dhclient eth1'
   ```

5. Copy scripts and run prep:
   ```bash
   scp -J nmadmin@__HYPERV_HOST__ prepare-image.sh samba-sconfig.sh \
       root@172.22.0.20:/root/
   ssh -J nmadmin@__HYPERV_HOST__ root@172.22.0.20 'bash /root/prepare-image.sh'
   ```

6. Remove external NIC, shutdown, checkpoint:
   ```bash
   ssh -J nmadmin@__HYPERV_HOST__ root@172.22.0.20 'shutdown -h now' || true
   sleep 10
   ssh nmadmin@__HYPERV_HOST__ << 'EOF'
   Remove-VMNetworkAdapter -VMName samba-dc1 -Name 'Network Adapter 2' -ErrorAction SilentlyContinue
   Checkpoint-VM -Name samba-dc1 -SnapshotName 'golden-image'
EOF
   ```

### Per test cycle (fast)

```bash
ssh nmadmin@__HYPERV_HOST__ << 'EOF'
Stop-VM -Name samba-dc1 -Force -ErrorAction SilentlyContinue
Restore-VMCheckpoint -Name golden-image -VMName samba-dc1 -Confirm:$false
Start-VM -Name samba-dc1
EOF
sleep 30  # wait for boot

# Run the test scenario
ssh -J nmadmin@__HYPERV_HOST__ root@172.22.0.20 'samba-sconfig ...'
```

### Cleanup at end of all testing

Delete test VMs **only** (never WS2025-DC1):
```bash
ssh nmadmin@__HYPERV_HOST__ << 'EOF'
Stop-VM -Name samba-dc1 -Force -ErrorAction SilentlyContinue
Remove-VM -Name samba-dc1 -Force
Remove-Item D:\Lab\samba-dc1 -Recurse -Force
EOF
```

---

## Test Scenarios

### Scenario 1: Standalone new forest

**Goal:** verify `samba-tool domain provision` works end-to-end on a
prep'd image.

```bash
ssh -J nmadmin@__HYPERV_HOST__ root@172.22.0.20 << 'EOF'
rm -f /etc/samba/smb.conf
systemctl stop samba-ad-dc 2>/dev/null

cat > /etc/krb5.conf << 'KRB'
[libdefaults]
  default_realm = TEST.LAN
  dns_lookup_kdc = true
  dns_lookup_realm = false
KRB

samba-tool domain provision \
    --realm=TEST.LAN --domain=TEST \
    --server-role=dc --dns-backend=SAMBA_INTERNAL \
    --adminpass='P@ssword123456!' \
    --option='dns forwarder = 172.22.0.10'

rm -f /var/lib/samba/private/krb5.conf
ln -s /etc/krb5.conf /var/lib/samba/private/krb5.conf

cat > /etc/resolv.conf << 'DNS'
search test.lan
nameserver 127.0.0.1
DNS

systemctl unmask samba-ad-dc
systemctl enable samba-ad-dc
systemctl start samba-ad-dc
sleep 5

echo "=== Verify ==="
dig @localhost samba-dc1.test.lan +short
dig -t SRV @localhost _ldap._tcp.test.lan +short
echo 'P@ssword123456!' | kinit administrator && klist
smbclient -L localhost -U% -N | grep -E '(sysvol|netlogon)'
samba-tool domain level show
EOF
```

### Scenario 2: Join existing WS2025 forest as additional DC

**This is the highest-value test.** Validates compatibility with a WS2025
domain that has the security baseline applied.

```bash
ssh -J nmadmin@__HYPERV_HOST__ root@172.22.0.20 << 'EOF'
# Pre-flight checks
ping -c 3 172.22.0.10 || exit 1
dig @172.22.0.10 lab.test +short
dig -t SRV @172.22.0.10 _ldap._tcp.lab.test +short

# DNS at WS2025 DC
cat > /etc/resolv.conf << 'DNS'
search lab.test
nameserver 172.22.0.10
DNS

# Time sync
chronyc makestep

# krb5.conf
cat > /etc/krb5.conf << 'KRB'
[libdefaults]
  default_realm = LAB.TEST
  dns_lookup_kdc = true
  dns_lookup_realm = false
KRB

systemctl stop samba-ad-dc 2>/dev/null
rm -f /etc/samba/smb.conf

# Join!
samba-tool domain join lab.test DC \
    --dns-backend=SAMBA_INTERNAL \
    --option='dns forwarder = 172.22.0.10' \
    -U'LAB\Administrator' \
    --password='P@ssword123456!'

# Post-join
rm -f /var/lib/samba/private/krb5.conf
ln -s /etc/krb5.conf /var/lib/samba/private/krb5.conf
cat > /etc/resolv.conf << 'DNS'
search lab.test
nameserver 127.0.0.1
DNS

systemctl unmask samba-ad-dc
systemctl enable samba-ad-dc
systemctl start samba-ad-dc
sleep 10

echo "=== Verify replication ==="
samba-tool drs showrepl
EOF

# Cross-check from WS2025 side
ssh nmadmin@__HYPERV_HOST__ << 'EOF'
$cred = New-Object PSCredential('LAB\Administrator',
    (ConvertTo-SecureString 'P@ssword123456!' -AsPlainText -Force))
Invoke-Command -VMName WS2025-DC1 -Credential $cred -ScriptBlock {
    Get-ADDomainController -Filter *
    nltest /dsgetdc:lab.test
    repadmin /showrepl
}
EOF
```

### Scenario 3: RODC in WS2025 forest

Same as Scenario 2, but use `RODC` instead of `DC` in the join command:

```bash
samba-tool domain join lab.test RODC \
    --dns-backend=SAMBA_INTERNAL \
    --option='dns forwarder = 172.22.0.10' \
    -U'LAB\Administrator' \
    --password='P@ssword123456!'
```

---

## Automated Test Runner

Save as `run-tests.sh` in the repo root. Runs all scenarios, saves logs.

```bash
#!/usr/bin/env bash
set -u
HYPERV_HOST='__HYPERV_HOST__'
VM_NAME='samba-dc1'
VM_IP='172.22.0.20'
RESULTS_DIR='test-results'
mkdir -p "$RESULTS_DIR"

hv()     { ssh "nmadmin@${HYPERV_HOST}" "$@"; }
vm()     { ssh -J "nmadmin@${HYPERV_HOST}" "root@${VM_IP}" "$@"; }
revert() {
    hv "Stop-VM -Name $VM_NAME -Force -ErrorAction SilentlyContinue;
        Restore-VMCheckpoint -Name golden-image -VMName $VM_NAME -Confirm:\$false;
        Start-VM -Name $VM_NAME"
    # Wait for SSH to come back
    local tries=0
    while ! vm 'true' 2>/dev/null; do
        sleep 5
        tries=$((tries+1))
        [[ $tries -gt 30 ]] && { echo "VM didn't come up"; return 1; }
    done
}

run_scenario() {
    local name="$1"; shift
    local logfile="$RESULTS_DIR/${name}.log"
    echo "[$(date +%H:%M:%S)] === $name ==="
    revert || { echo "  revert failed"; return 1; }
    vm 'bash -s' > "$logfile" 2>&1 <<< "$*"
    local rc=$?
    echo "[$(date +%H:%M:%S)]     exit=$rc  log=$logfile"
    return $rc
}

# Scenario 1
run_scenario 'new-forest' '
    set -e
    rm -f /etc/samba/smb.conf
    cat > /etc/krb5.conf << EOF
[libdefaults]
  default_realm = TEST.LAN
  dns_lookup_kdc = true
EOF
    samba-tool domain provision --realm=TEST.LAN --domain=TEST \
        --server-role=dc --dns-backend=SAMBA_INTERNAL \
        --adminpass="P@ssword123456!"
    rm -f /var/lib/samba/private/krb5.conf
    ln -s /etc/krb5.conf /var/lib/samba/private/krb5.conf
    systemctl unmask samba-ad-dc && systemctl start samba-ad-dc
    sleep 5
    systemctl is-active samba-ad-dc
    dig -t SRV @localhost _ldap._tcp.test.lan +short
'

# Scenario 2
run_scenario 'join-ws2025-dc' '
    set -e
    echo -e "search lab.test\nnameserver 172.22.0.10" > /etc/resolv.conf
    chronyc makestep || true
    cat > /etc/krb5.conf << EOF
[libdefaults]
  default_realm = LAB.TEST
  dns_lookup_kdc = true
EOF
    rm -f /etc/samba/smb.conf
    samba-tool domain join lab.test DC \
        --dns-backend=SAMBA_INTERNAL \
        -U"LAB\\Administrator" --password="P@ssword123456!"
    echo -e "search lab.test\nnameserver 127.0.0.1" > /etc/resolv.conf
    systemctl unmask samba-ad-dc && systemctl start samba-ad-dc
    sleep 10
    samba-tool drs showrepl
'

# Scenario 3
run_scenario 'join-ws2025-rodc' '
    set -e
    echo -e "search lab.test\nnameserver 172.22.0.10" > /etc/resolv.conf
    chronyc makestep || true
    cat > /etc/krb5.conf << EOF
[libdefaults]
  default_realm = LAB.TEST
  dns_lookup_kdc = true
EOF
    rm -f /etc/samba/smb.conf
    samba-tool domain join lab.test RODC \
        --dns-backend=SAMBA_INTERNAL \
        -U"LAB\\Administrator" --password="P@ssword123456!"
    echo -e "search lab.test\nnameserver 127.0.0.1" > /etc/resolv.conf
    systemctl unmask samba-ad-dc && systemctl start samba-ad-dc
    sleep 10
    samba-tool drs showrepl
'

echo ""
echo "=== Summary ==="
for log in "$RESULTS_DIR"/*.log; do
    if grep -q 'is_active' "$log" && tail -1 "$log" | grep -q 'active'; then
        echo "  PASS  $(basename "$log" .log)"
    else
        echo "  FAIL  $(basename "$log" .log)"
    fi
done

# Always leave VM in known state
hv "Restore-VMCheckpoint -Name golden-image -VMName $VM_NAME -Confirm:\$false; Stop-VM $VM_NAME -Force"
```

---

## Debugging

### Key logs

| Location | Contents |
|---|---|
| Linux VM: `journalctl -u samba-ad-dc -f` | Live Samba logs |
| Linux VM: `/var/log/samba/` | Per-service Samba logs |
| WS2025: `Get-WinEvent -LogName 'Directory Service'` | AD events |
| Host: `Get-WinEvent -LogName Microsoft-Windows-Hyper-V-Worker-Admin` | VM events |

### Common failures joining WS2025

| Symptom | Cause | Fix |
|---|---|---|
| `domain join` hangs at "Looking for DC" | DNS not pointing at WS2025 | Fix resolv.conf |
| `clock skew too great` | Time drift | `chronyc makestep` before join |
| `LDAP_STRONG_AUTH_REQUIRED` | LDAP signing required by baseline | Generate TLS cert (sconfig menu 5) |
| `KDC has no support for encryption type` | Baseline disabled RC4 | Ensure `kerberos encryption types = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96` |
| `KERBEROS_PREAUTH_FAILED` | Time or realm case | Realm must be UPPERCASE |
| `NT_STATUS_LOGON_FAILURE` on join | Credentials wrong or baseline blocking | Verify NTLM fallback not needed |
| Join succeeds but replication fails | SYSVOL ACLs | Run `samba-tool ntacl sysvolreset` |

### Investigation commands

```bash
# Linux VM
testparm -s
samba-tool dbcheck --cross-ncs
samba-tool drs showrepl
samba-tool dns query localhost lab.test @ ALL
net ads info
wbinfo -t
smbclient //ws2025-dc1.lab.test/sysvol -U 'LAB\Administrator'

# WS2025 via PSDirect
ssh nmadmin@__HYPERV_HOST__ << 'EOF'
$cred = New-Object PSCredential('LAB\Administrator',
    (ConvertTo-SecureString 'P@ssword123456!' -AsPlainText -Force))
Invoke-Command -VMName WS2025-DC1 -Credential $cred -ScriptBlock {
    Get-ADDomainController -Filter *
    Get-DnsServerResourceRecord -ZoneName lab.test -RRType A
    repadmin /showrepl
    Get-GPO -All | Select DisplayName
}
EOF
```

---

## Script Modification Loop

1. Edit `prepare-image.sh` or `samba-sconfig.sh` in repo
2. `scp -J nmadmin@__HYPERV_HOST__ samba-sconfig.sh root@172.22.0.20:/usr/local/sbin/samba-sconfig`
3. If `prepare-image.sh` changed → need fresh install (re-run initial setup)
4. If `samba-sconfig.sh` only → revert checkpoint, replace file, re-test

---

## Session Checklist

**Start of session:**
- [ ] Run health check — switch + WS2025-DC1 up, domain healthy
- [ ] `samba-dc1` VM exists with `golden-image` checkpoint
- [ ] Scripts in repo current

**End of session:**
- [ ] Commit script changes to repo
- [ ] `samba-dc1` reverted to golden-image, powered off
- [ ] Test logs saved in `test-results/`
- [ ] **Lab infrastructure (switch + WS2025-DC1) STILL RUNNING** ← critical
- [ ] Summary written to handoff notes

---

## File Layout

```
Repo root
├── CLAUDE.md                       (this file)
├── prepare-image.sh                (Debian image prep)
├── samba-sconfig.sh                (TUI config tool)
├── run-tests.sh                    (test orchestrator, optional)
├── lab/
│   ├── New-WS2025Lab.ps1           (build lab infra)
│   ├── Apply-SecurityBaseline.ps1  (import GPOs)
│   ├── New-SambaTestVM.ps1         (create Debian VM)
│   ├── FirstLogon-PromoteToDC.ps1  (runs inside WS2025 VM on first boot)
│   └── unattend-ws2025-core.xml    (Panther unattend file)
└── test-results/                   (test run logs)
```
