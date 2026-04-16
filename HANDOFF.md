# HANDOFF.md — How to hand this project off to Claude Code

This is your personal checklist. Work through it in order. The whole setup
takes about 45 minutes of your attention, most of it waiting while things
install. Once Claude Code takes over, you mostly watch.

## Mental model

You have two categories of files:

- **Project files** (CLAUDE.md, prepare-image.sh, samba-sconfig.sh, run-tests.sh, lab/\*) — these live in a **Git repo on your Mac**. Claude Code reads and edits them there.
- **Lab files** (the `lab/*.ps1` scripts, ISOs, GPO ZIP) — these need to be **on the Hyper-V host**, accessible from the D:\ISO\ path. Claude Code runs them there via SSH.

Claude Code itself runs on your Mac, SSHs into the Hyper-V host when it
needs to do hypervisor things, and SSHs into VMs (through the host as a
jump host) when it needs to run Debian commands. You don't need to install
anything on the Hyper-V host — PowerShell 7.6 and the modules are already
there.

Your job is: set up the project directory on your Mac, fill in a couple of
placeholder values, seed the lab scripts onto the host via your ISO share,
then start Claude Code with a clear instruction.

---

## Prerequisites

Check these **before** you start. If any fail, fix them first.

### 1. Claude Code is installed on your Mac

```bash
claude --version
```

If it's not installed, install it following Anthropic's current docs. You'll
also need to be signed in with your account.

### 2. SSH to the Hyper-V host works without a password

```bash
ssh nmadmin@__YOUR_HOST__ 'hostname'
```

This should return the host's hostname immediately, no password prompt.
If it prompts for a password, fix your SSH key setup before continuing.
Claude Code needs non-interactive SSH.

### 3. The ISO share is mounted and writable

```bash
ls /Volumes/ISO/
touch /Volumes/ISO/.write-test && rm /Volumes/ISO/.write-test && echo "writable"
```

You should see the three ISOs and the ZIP. The write test should print
"writable". If it doesn't, remount the share with write permissions.

### 4. The ISOs are all there

```bash
ls /Volumes/ISO/ | grep -E '(debian-13.4.0|SERVER_EVAL|Security-Baseline)'
```

You should see three matches.

---

## Step 1 — Create the project directory on your Mac

Pick a place for the repo. Somewhere under your usual development folder
makes sense. I'll use `~/Developer/samba-addc-appliance` as an example —
substitute your own.

```bash
mkdir -p ~/Developer/samba-addc-appliance
cd ~/Developer/samba-addc-appliance
git init
```

Now copy in all the files I delivered:

```bash
# Replace the path below with wherever you saved the files from Claude
DELIVERED=/path/to/downloaded/files

cp "$DELIVERED/CLAUDE.md"          .
cp "$DELIVERED/HANDOFF.md"         .
cp "$DELIVERED/prepare-image.sh"   .
cp "$DELIVERED/samba-sconfig.sh"   .
chmod +x prepare-image.sh samba-sconfig.sh

mkdir lab
cp "$DELIVERED/lab/"*              lab/
```

Verify the layout:

```bash
tree . || ls -R
```

You should see:

```
.
├── CLAUDE.md
├── HANDOFF.md
├── prepare-image.sh
├── samba-sconfig.sh
└── lab
    ├── Apply-SecurityBaseline.ps1
    ├── FirstLogon-PromoteToDC.ps1
    ├── New-SambaTestVM.ps1
    ├── New-WS2025Lab.ps1
    └── unattend-ws2025-core.xml
```

Commit to git so you can track Claude Code's changes:

```bash
git add -A
git commit -m "Initial scaffolding from Claude"
```

---

## Step 2 — Fill in the host-specific values

Only one placeholder needs changing: `__HYPERV_HOST__` in CLAUDE.md. This
appears in several places — replace them all with your Hyper-V host's SSH
target (hostname or IP).

```bash
# Replace YOURHOST with your actual host name or IP
sed -i '' 's/__HYPERV_HOST__/YOURHOST/g' CLAUDE.md
```

(The `-i ''` is macOS sed syntax — it edits in place with an empty backup
suffix.)

Verify no placeholders remain:

```bash
grep -n '__HYPERV_HOST__' CLAUDE.md
# (should print nothing)
```

If you want non-default lab values (different IP range, different admin
password, different domain name), also edit the parameter defaults at the
top of `lab/New-WS2025Lab.ps1` and `lab/FirstLogon-PromoteToDC.ps1`. The
defaults are:

- Lab network: `172.22.0.0/24`
- Host vNIC: `172.22.0.1`
- WS2025 DC: `172.22.0.10`
- Admin password: `P@ssword123456!`
- Domain: `lab.test` / `LAB`

> ⚠️ If you change the password or network, also update the matching values
> inside CLAUDE.md so Claude Code uses the right ones.

Commit any edits:

```bash
git add -A
git commit -m "Environment-specific values"
```

---

## Step 3 — Seed the lab scripts onto the Hyper-V host

Claude Code will invoke these scripts via SSH, so they need to live in a
stable path on the host. Copy them via your ISO share.

```bash
mkdir -p /Volumes/ISO/lab-scripts
cp lab/* /Volumes/ISO/lab-scripts/
ls /Volumes/ISO/lab-scripts/
```

On the Hyper-V host, these files now appear at `D:\ISO\lab-scripts\`. You
can verify:

```bash
ssh nmadmin@YOURHOST 'Get-ChildItem D:\ISO\lab-scripts\ | Format-Table Name,Length'
```

You should see all five files.

---

## Step 4 — Launch Claude Code

From the project root:

```bash
cd ~/Developer/samba-addc-appliance
claude
```

Claude Code will open in interactive mode. Your **first prompt** should
tell it to read the instructions and do the one-time lab build:

> Read CLAUDE.md carefully. Then run the one-time lab setup: build the
> WS2025 DC VM and apply the security baseline. This is the persistent
> infrastructure — build it once. Stop before creating the Samba test VM,
> because the Debian install needs to be done manually. Monitor the lab
> build progress and tell me when it's complete and the baseline is
> applied.

Claude Code will:

1. Read CLAUDE.md
2. Run the health check (will show everything is missing — that's fine
   for first run)
3. Execute `New-WS2025Lab.ps1` on the host via SSH
4. Wait for the DC to finish its first-logon script (watch for
   `setup-complete.marker`)
5. Execute `Apply-SecurityBaseline.ps1`
6. Report back

**Expected timing:** 15 minutes for the DC VM to build and promote,
another 2–3 minutes for the baseline import. Claude Code will show you
progress in real time.

If anything fails, Claude Code will stop and tell you. You can respond
with "try again" or "show me the log from X" — it'll work through it.

---

## Step 5 — Manual Debian install (one-time)

This is the one step that isn't automated. You have to open a console
window and click through the Debian installer. It takes about 5 minutes.

Tell Claude Code:

> The lab is built. Now create the Samba test VM with New-SambaTestVM.ps1.
> Once it's running, I'll do the Debian install manually via vmconnect.
> Tell me when to start.

Claude Code runs:

```powershell
pwsh -File D:\ISO\lab-scripts\New-SambaTestVM.ps1 -VMName samba-dc1 -Start
```

When Claude Code tells you the VM is running, open a Remote Desktop or
Console session to the Hyper-V host and run:

```powershell
vmconnect localhost samba-dc1
```

Then install Debian with these choices:

- **Language / Locale / Keyboard:** your preference
- **Hostname:** `samba-dc1`
- **Domain name:** (leave blank)
- **Root password:** pick one and remember it (this is the root password
  for the Debian VM; it's not the domain admin password)
- **No regular user:** when prompted to create a non-root user, use the
  same password or leave it empty. It doesn't matter — you won't use it.
- **Network:** configure manually, not DHCP:
  - IP: `172.22.0.20`
  - Netmask: `255.255.255.0`
  - Gateway: `172.22.0.1`
  - DNS: `1.1.1.1` (temporary — you'll switch to the WS2025 DC later)
- **Partitioning:** guided, use entire disk, all in one partition
- **Software selection:** uncheck desktop; keep **SSH server** and
  **standard system utilities**. Everything else off.
- **GRUB:** install to the disk

Reboot. Debian comes up with SSH listening on 172.22.0.20.

> 💡 The internal switch has no internet route. During install, you'll
> need an external NIC attached temporarily. Either attach it before
> starting the install, or if the mirror step fails, attach it then retry.
> Claude Code can attach/detach this NIC for you — just ask.

Back in Claude Code:

> Debian is installed. The VM has IP 172.22.0.20. Please verify SSH works,
> then run prepare-image.sh and checkpoint the VM as 'golden-image'. If
> the VM doesn't have internet access for apt, temporarily add an external
> NIC.

Claude Code will SSH in, copy the scripts, run `prepare-image.sh` (takes
~5 minutes), shut down the VM, and create the Hyper-V checkpoint.

---

## Step 6 — Run the automated test cycles

Now the fun part. Tell Claude Code:

> Run all three test scenarios using the automated test runner approach
> described in CLAUDE.md. For each scenario: revert samba-dc1 to the
> golden-image checkpoint, execute the scenario, capture the log, and
> verify success. Show me a summary at the end.

Claude Code will cycle through:

1. **Scenario 1** — standalone new forest (samba-tool domain provision)
2. **Scenario 2** — join the WS2025 domain as additional DC
3. **Scenario 3** — join as RODC

Each scenario takes 2–5 minutes. Total: ~15 minutes for all three.

Watch the output. Scenario 2 is the most likely to surface real issues —
that's where you're exercising the interaction between Samba and the
hardened WS2025 domain.

---

## Iterative development loop

From here on, the loop is:

1. You or Claude Code finds a bug in `prepare-image.sh` or
   `samba-sconfig.sh`
2. Claude Code edits the file in the repo
3. Claude Code SCPs the updated file to the VM (the right path depends
   on which script — CLAUDE.md has the details)
4. Claude Code reverts to golden-image, re-tests
5. Commit changes when a test passes

If you need to modify `prepare-image.sh` specifically, the checkpoint is
no longer valid (because it captured a state created by the old version).
You'll need to redo Step 5 — attach external NIC, re-run prepare-image,
re-checkpoint. Claude Code can do this but it's not instant.

`samba-sconfig.sh` changes don't invalidate the checkpoint — just revert,
SCP the new file, and test.

---

## What to do at the end of a session

Before you close Claude Code:

> Put the test VM back to golden-image state and power it off. Verify the
> WS2025 DC is still running. Commit any script changes to git with
> descriptive messages.

Check the Hyper-V host state afterwards:

```bash
ssh nmadmin@YOURHOST 'Get-VM | Format-Table Name,State,Uptime'
```

You want to see:

- `WS2025-DC1` — **Running** (this should NEVER be Off at end of session
  unless you explicitly took it down)
- `samba-dc1` — Off (or whatever state you left it in)

And your git log should show what changed:

```bash
cd ~/Developer/samba-addc-appliance
git log --oneline
```

---

## Troubleshooting

**Claude Code can't SSH to the host.** Test from your terminal first:
`ssh nmadmin@YOURHOST 'hostname'`. If that doesn't work silently, fix the
SSH key setup before Claude Code can help. Common cause: key not in
agent — try `ssh-add ~/.ssh/id_ed25519`.

**The DC build hangs forever.** Check the VM state on the host:
```powershell
Get-VM WS2025-DC1 | Format-List State,Uptime
```
If state is Running but nothing's happening, open vmconnect and see what
screen it's on. Most likely: OOBE got stuck on a prompt that the unattend
didn't cover. Fix: destroy the VM, fix the unattend, rebuild.

**"PowerShell Direct failed" errors.** The VM needs to finish booting and
the Integration Services to start. Wait longer (60+ seconds after VM
starts), or check `Get-VMIntegrationService` for the VM.

**Baseline import fails with "cannot find MapGuidsToGpoNames.ps1".** This
is a known issue with Baseline-ADImport.ps1 — the script expects
to be run from its own directory. `Apply-SecurityBaseline.ps1` handles
this with `Push-Location`, but if the ZIP structure is different than
expected, you may need to tweak the path discovery logic.

**Debian install can't find mirror.** The internal switch has no NAT.
Either enable ICS on the host (one-time setup, then this goes away), or
attach an external NIC temporarily. Claude Code can do either.

**The Samba VM joins WS2025 but replication fails.** Most common cause
is the WS2025 security baseline requiring LDAP signing or channel
binding. Fix is in the Samba smb.conf — `samba-sconfig` menu 5 applies
the necessary hardening. If the join itself fails with `LDAP_STRONG_AUTH
_REQUIRED`, generate a TLS cert via sconfig first, then retry the join.

**Everything goes sideways and you want to start fresh.** The lab infra
is rebuildable. On the host:
```powershell
Stop-VM WS2025-DC1 -Force
Remove-VM WS2025-DC1 -Force
Remove-Item D:\Lab\WS2025-DC1 -Recurse -Force
Get-VMSwitch Lab-Internal | Remove-VMSwitch -Force
```
Then re-run `New-WS2025Lab.ps1` and `Apply-SecurityBaseline.ps1`.

---

## A note on expectations

This is a first integration. The scripts are tested in design but they
haven't run end-to-end against your specific environment yet. Expect
something to not work the first time — probably a path, a permission, or
an edge case in the unattend file. Claude Code is well-suited to working
through these; let it iterate.

If you hit something I didn't anticipate, paste the error into Claude
Code along with relevant context, and let it propose a fix. If it
proposes something that feels off to you, push back and ask for the
alternative approach — same as you'd do with a junior engineer. Your
instincts on IT infrastructure will be right more often than Claude
Code's first suggestion.
