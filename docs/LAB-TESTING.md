# Lab Testing Guide

This guide describes the tests that matter for the Samba AD DC appliance and
how to add them to the lab scenario runner.

The goal is not only "does Samba start?" The goal is to prove that a prepared
Debian appliance can interoperate with a hardened Windows Server 2025 forest in
the places administrators actually depend on: DNS, Kerberos, LDAP, SMB,
replication, SYSVOL, certificates, and recovery from common deployment mistakes.

## Test Runner Model

`lab/run-scenario.sh` runs from the Mac. A scenario is a shell file in
`lab/scenarios/` that defines:

| Function | Required | Purpose |
| --- | --- | --- |
| `run_scenario` | yes | Performs the action under test, usually over SSH into `samba-dc1`. |
| `verify` | yes | Asserts the desired final state and returns non-zero on failure. |
| `pre_hook` | no | Optional setup after VM revert and Windows cleanup. |
| `post_hook` | no | Optional evidence collection or cleanup after verification. |

The runner handles the common setup:

1. Stage `lab/*.ps1` and `lab/*.xml` to `/Volumes/ISO/lab-scripts`.
2. Revert `samba-dc1` to `golden-image`.
3. Clean stale Samba records from `WS2025-DC1`.
4. Push the current `prepare-image.sh` and `samba-sconfig.sh`.
5. Run the scenario and verify it.
6. Write a full log under `test-results/`.

## Existing Scenario

### `join-dc`

Purpose: prove a prepared Samba appliance can join a hardened WS2025 forest as
an additional writable DC.

What it covers today:

- `samba-sconfig join-dc` headless CLI.
- Forest functional-level probing.
- Domain join using existing admin credentials.
- Samba service startup.
- Windows-side DNS/PTR behavior.
- Forced KCC after PTR creation.
- Initial SYSVOL seed from `//WS2025-DC1/sysvol`.
- Samba-side DRS health.
- Windows-side replication verification.
- TLS certificate SAN presence.

Run:

```bash
lab/run-scenario.sh join-dc
```

Iterate only on verification:

```bash
lab/run-scenario.sh join-dc --verify-only
```

## Important Tests To Add

The following tests are the highest-value next additions. They are written in
the order they should be implemented.

### 1. Smoke Test: `smoke-prepared-image`

Purpose: verify the golden image is still a clean appliance base before any
domain operation.

Assertions:

- `samba-sconfig` is installed and executable.
- `samba-ad-dc` is disabled/inactive.
- `smbd`, `nmbd`, and `winbind` are masked or inactive as intended.
- `/etc/samba/smb.conf` does not exist.
- `pwsh`, `nft`, `ldapsearch`, `smbclient`, `samba-tool`, and `chronyd` exist.
- chrony has no hard-coded internet pools before deployment.
- `/etc/krb5.conf` is the skeleton.
- DNS and internet connectivity work through `router1`.
- first-boot marker behavior is predictable.

Why it matters: failed joins are much easier to debug when the base image is
known-good and deliberately unprovisioned.

Status: implemented in `lab/scenarios/smoke-prepared-image.sh`.

### 2. New Forest Provision: `provision-new-forest`

Purpose: verify Samba can be the first DC in a new forest, not only a joined DC.

Assertions:

- `samba-tool domain provision` succeeds through the appliance flow.
- `samba-ad-dc` starts and stays active.
- DNS SRV records exist locally.
- Kerberos TGT acquisition works.
- SYSVOL and NETLOGON shares are available.
- chrony is configured as the domain time source.
- hardening block is inserted into `[global]`, not a share section.
- TLS certificate has DNS and IP SAN entries.
- firewall can be enabled without blocking AD ports.

Needed script support: add a headless `samba-sconfig provision` command or keep
this as a TUI/manual test until that exists.

### 3. RODC Join: `join-rodc`

Purpose: verify the RODC path stays healthy as code changes.

Assertions:

- `SC_ROLE=RODC samba-sconfig join-dc` or a dedicated CLI path completes.
- The DC object is read-only in AD.
- Password replication policy is sane.
- DRS status is healthy for the partitions an RODC should hold.
- SYSVOL seed still succeeds.
- write attempts that should fail do fail clearly.

Why it matters: RODC joins are similar enough to writable joins to accidentally
reuse broken assumptions, but different enough to deserve their own regression.

### 4. Hardening Compatibility: `hardening-ws2025`

Purpose: prove the appliance remains compatible with WS2025 security posture.

Assertions:

- LDAP simple bind without TLS/signing fails when expected.
- SASL/GSSAPI signed LDAP bind succeeds.
- Kerberos uses strong encryption.
- SMB signing is mandatory.
- SMB1/SMB2 negotiation is refused according to configured min protocol.
- LDAPS serves the appliance certificate with SANs.
- `testparm -s` reports no global-parameter-in-share-section warnings.

Why it matters: hardening regressions often look like client compatibility
issues unless tested explicitly.

### 5. SYSVOL Sync: `sysvol-sync-smb`

Purpose: prove the out-of-band SYSVOL workaround remains operational.

Assertions:

- `samba-sconfig` can write SMB sync config without exposing credentials in
  world-readable files.
- `sysvol-sync` pulls from `//WS2025-DC1/sysvol`.
- Deleted and changed files converge locally.
- `samba-tool ntacl sysvolreset` completes.
- Logs are written to `/var/log/samba/sysvol-sync.log`.
- The scheduled cron entry or future systemd timer exists and runs.

Why it matters: Samba has no DFSR, so this is not optional operational glue.

### 6. DNS Reverse Zone Edge Cases: `join-no-reverse-zone`

Purpose: verify the join path gives useful output when a reverse zone is absent.

Assertions:

- Join succeeds even when PTR registration cannot.
- Output clearly states the reverse zone is missing.
- Verification detects Windows-side replication risk.
- The failure mode is documented in the test log.

Why it matters: many real AD environments do not have every reverse zone
created ahead of time.

### 7. Second Samba DC: `join-samba-to-samba`

Purpose: verify Samba-to-Samba behavior and SSH-based SYSVOL sync.

Assertions:

- `samba-dc2` joins using `samba-dc1` as source.
- DRS is healthy both ways.
- SSH transport for `sysvol-sync` works.
- push and pull modes do not race or delete unexpectedly.

Why it matters: Windows interop and Samba-only topologies exercise different
paths.

### 8. Upgrade Safety: `manual-upgrade-policy`

Purpose: ensure update policy does not accidentally upgrade Samba unattended.

Assertions:

- security-only and full-auto policies blacklist Samba/Kerberos/Winbind
  packages.
- manual policy does not install packages automatically.
- `get_update_policy` reports the state accurately.

Why it matters: unattended Samba upgrades on a DC can be a production outage.

## Scenario Template

Use this as a starting point for new files under `lab/scenarios/`.

```bash
# lab/scenarios/example.sh

run_scenario() {
    ssh_vm 'sudo samba-sconfig --help'
}

verify() {
    local rc=0

    say "samba-sconfig exists"
    ssh_vm 'test -x /usr/local/sbin/samba-sconfig' || rc=1

    say "example assertion"
    ssh_vm 'true' || rc=1

    return "$rc"
}
```

Prefer assertions that check final state instead of relying only on command
exit codes. Keep evidence in the log: print the relevant `systemctl`, `dig`,
`samba-tool`, `repadmin`, or `openssl` output before deciding pass/fail.

## Verification Commands Worth Reusing

From Samba:

```bash
sudo systemctl is-active samba-ad-dc
sudo samba-tool drs showrepl
sudo samba-tool domain level show
sudo samba-tool fsmo show
sudo net ads info -P
sudo testparm -s
dig @localhost _ldap._tcp.lab.test SRV +short
openssl x509 -noout -ext subjectAltName -in /var/lib/samba/private/tls/cert.pem
```

From WS2025:

```powershell
repadmin /replsummary
repadmin /showrepl /errorsonly
Get-ADDomainController -Filter *
Resolve-DnsName 10.10.10.20
Resolve-DnsName samba-dc1.lab.test
Get-DnsServerResourceRecord -ZoneName '10.10.10.in-addr.arpa'
```

## Adding Headless Commands

When a scenario needs to drive TUI-only behavior, add a focused headless
subcommand to `samba-sconfig.sh` instead of scripting whiptail. The current
pattern is:

- Validate required environment variables with `: "${VAR:?message}"`.
- Reuse the same helper functions as the TUI.
- Print progress lines prefixed with `[sconfig]`.
- Return non-zero only for failures the test should treat as scenario failure.

Good candidates:

- `samba-sconfig provision`
- `samba-sconfig harden`
- `samba-sconfig enable-firewall`
- `samba-sconfig sysvol-sync configure-smb`
- `samba-sconfig sanity`

## Test Data Hygiene

- Treat logs in `test-results/` as evidence. Keep representative passing logs,
  but avoid committing every ad-hoc run.
- Never rely on stale AD objects. Use `Reset-LabDomainState.ps1` before join
  scenarios unless deliberately testing dirty-state recovery.
- Keep passwords lab-only. The default `P@ssword123456!` appears throughout
  this repo because the lab is disposable and isolated.
- Do not tear down `router1` or `WS2025-DC1` casually. They are persistent
  fixtures.
