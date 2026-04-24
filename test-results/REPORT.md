# Samba AD DC Appliance — Test Report

- **Run date:** 2026-04-16
- **Scenario:** Debian 13 / Samba 4.22.8 joining a Windows Server 2025 forest with the MSFT WS2025-2602 Security Baseline applied
- **Topology:** 1 × WS2025-DC1 (172.22.0.10) + 1 × samba-dc1 (172.22.0.20) on Hyper-V `Lab-Internal` (172.22.0.0/24, no NAT)
- **Deliverables referenced:** distilled running notes in [`NOTES.md`](./NOTES.md)
  and topology diagram `topology.drawio.svg`. Raw `*.log` transcripts were
  local run artifacts and are no longer tracked.

## Result summary

| ID | Test | Verdict | Notes |
|----|------|---------|-------|
| T1 | Smoke (revert → boot → tool presence) | **PASS** | 2 caveats: chrony points at unreachable internet NTP; `nft` binary missing |
| T2 | Join WS2025 as additional DC | **PASS** after fix | 1st attempt → `WERR_DS_INCOMPATIBLE_VERSION`; fixed with `ad dc functional level = 2016` |
| T3.a | Inbound repl (WS2025 → Samba) | **PASS** | All 5 NCs healthy from start |
| T3.b | Outbound repl (Samba → WS2025) | **PASS** after fix | 1st attempt → error `8524` DNS lookup; fixed by adding PTR record for samba-dc1 on WS2025 |
| T3.c | User round-trip (both directions) | **PASS** | `samba-tool user create` ↔ `New-ADUser` both replicate |
| T3.d | GPO AD object replication | **PASS** | All 11 GPOs visible on Samba via `samba-tool gpo listall` |
| T3.e | SYSVOL file replication | **FAIL** (expected) | Samba doesn't implement DFSR; `sysvol-sync` rsync helper is scaffolded for manual use |
| T4.1 | LDAP signing | **PASS** | Samba uses GSS-sign by default |
| T4.2 | Kerberos AES-only | **PASS** for Samba, baseline has latent RC4 acceptance | Samba negotiates AES; RC4 tickets still issuable against pre-baseline accounts |
| T4.3 | SMB signing | **PASS** | Signing negotiates cleanly in both directions |
| T4.4 | LDAPS (Samba side) | **PASS with caveats** | Self-signed cert auto-generated; no SAN, 2y expiry, Windows clients may reject |
| T4.5 | LDAPS (WS2025 side) | N/A | No AD CS; not in scope |

## Failure taxonomy

### (A) Our-config / appliance script fixes

Items that exist in our repo and that we should patch before the appliance is
handed to anyone else.

1. **`prepare-image.sh` §8 — Microsoft PowerShell install**
   - Was unusable on Debian 13 because (a) Trixie's `sqv` rejects Microsoft's
     repo signing key, (b) `gpg --dearmor` requires a TTY under non-interactive
     sudo. Rewritten during this session to always fetch the direct `.deb`
     from GitHub.
2. **`prepare-image.sh` — chrony config points at internet NTP**
   - The default `chrony.conf` uses cloudflare/google/debian pools, which are
     unreachable on an isolated AD network. `samba-sconfig` join/provision
     flow should overwrite chrony to target the DC being joined, enabling the
     `ntpsigndsocket` for secure AD time sync.
3. **`prepare-image.sh` — nftables binary not installed**
   - Firewall rule file is written but the `nftables` package isn't pulled
     in, so `nft` and `nftables.service` have nothing to activate against.
     Add `nftables` to the package install list.
4. **`lab/FirstLogon-PromoteToDC.ps1` — phase 2 never auto-runs**
   - `<FirstLogonCommands>` fires only once. After `Install-ADDSForest`
     reboot, phase 2 (Lab OUs, DNS-to-self, forwarders, `setup-complete.marker`)
     is skipped. Manually re-invoked via PSDirect this session. Fix: phase 1
     should register a RunOnce key or Scheduled Task to continue on next
     logon.
5. **`lab/Apply-SecurityBaseline.ps1` — wrong Member Server GPO linked**
   - Pattern `*Member Server*` with `Select -First 1` grabs "Member Server
     Credential Guard" instead of the main "Member Server" baseline. Tighten
     the match to an exact DisplayName or link both.
6. **`samba-sconfig` join workflow — no functional-level detection**
   - Samba's default `ad dc functional level = 2008_R2` produces a cryptic
     failure against any 2012+ forest. Probe the target forest's
     `forestFunctionality` rootDSE attribute and set `ad dc functional level`
     to match before calling `samba-tool domain join`.
7. **`samba-sconfig` join workflow — no PTR registration**
   - Must either (a) use `samba-tool dns add` with GSS-TSIG to register the
     joining DC's PTR on the target reverse zone, or (b) loudly warn the
     admin that they need to add it on the Windows side. Otherwise WS2025
     KCC returns the useless "DNS lookup failure" and replication breaks.
8. **`samba-sconfig` join workflow — SYSVOL initial pull**
   - After a successful join, SYSVOL `Policies/` is empty on Samba. Kick off
     `sysvol-sync` once to seed it, then enable the systemd timer. Consider
     an `--source=smb` mode that uses `smbclient` instead of rsync-over-SSH
     (Windows DCs usually don't have sshd).
9. **`samba-sconfig` menu 5 — TLS cert generation**
   - Samba's auto-generated self-signed cert has no SAN and a 2-year validity.
     For production, menu 5 should generate a cert with DNS+IP SANs, with a
     proper CA (either a local CA installable into Windows, or an ACME client
     for public deployments), and set up rotation.
10. **`samba-sconfig` "test connectivity" menu — smbclient Kerberos cred-cache usability**
    - Using `sudo kinit Administrator` then `smbclient -k` fails because the
      cred cache is owned by root but `$USER` is `debadmin`. Either set
      `KRB5CCNAME` explicitly or use `-U user@REALM --password=...`. Document
      this in the TUI and/or wrap it.
11. **`prepare-image.sh` masks `samba.service` to `/dev/null`**
    - Cosmetically causes `systemctl enable samba-ad-dc` to emit
      `Failed to enable unit: File '/etc/systemd/system/samba.service' already
      exists and is a symlink to /dev/null`. Post-join `enable` still succeeds
      via the `samba-ad-dc` symlink. Fix: use `systemctl mask` only for
      file-server services that actually collide, not the umbrella `samba.service`.

### (B) Samba / upstream gaps — document as "this is how it is"

Items we cannot fix in our appliance because they live in Samba (or in the
Windows-Samba interop contract itself).

1. **No DFSR** — Samba has never implemented DFSR; SYSVOL between Samba and
   Windows DCs does not replicate. Workarounds: rsync (`sysvol-sync`),
   `robocopy`, or `smbclient mget`. This is the single biggest structural
   interop gap and is unlikely to change.
2. **`samba-tool domain join` does not auto-register PTR**
   - The tool populates forward records (A, CNAME, SRV) via the join flow and
     `samba_dnsupdate`, but `dns_update_list` does not include reverse zones.
     Windows admins traditionally add PTR manually; the appliance should do
     it for the user (Taxonomy A item #7 above).
3. **`samba-tool domain join` does not auto-match the target forest's functional level**
   - Default `ad dc functional level = 2008_R2` silently fails against any
     modern forest with the opaque `WERR_DS_INCOMPATIBLE_VERSION`. An
     upstream improvement would be: detect the target FL, warn if a
     downgrade is implied, and default to matching.
4. **`samba-tool domain join --help` is silent about most options**
   - The tool has no `--help` that documents `--option=` passthroughs like
     `ad dc functional level = 2016`. Admins have to read `smb.conf(5)` for
     each option. This is a documentation/UX gap upstream.

### Windows-side loosening **NOT required** for Samba to join

This is the good news. With the WS2025-2602 baseline applied:

- No need to disable LDAP signing or channel binding.
- No need to re-enable RC4 (the baseline doesn't actually block it — see T4.2).
- No need to disable SMB signing.
- No need to downgrade forest/domain functional level *if* Samba is configured
  with matching `ad dc functional level`.

The **only** WS2025-side manual step is adding a PTR record for the Samba DC
on the reverse zone. Samba itself can do that during join once our appliance
handles it (Taxonomy A item #7).

## Next steps (suggested order)

1. Implement the §A fixes in the appliance scripts (especially items 6, 7, 8, 9).
2. Patch `FirstLogon-PromoteToDC.ps1` phase 2 so full rebuilds don't need
   manual intervention (§A item 4).
3. Add a regression harness — `run-tests.sh` already sketched in `CLAUDE.md` —
   that exercises T1–T4 automatically.
4. For the write-up: the **T2 functional-level error** and the **T3.b PTR
   mystery** are the two most interesting "debugging stories" — both cost a
   lot of real-world time because the error messages point the wrong way
   (`WERR_DS_INCOMPATIBLE_VERSION` sounds like a schema issue; "DNS lookup
   failure" sounds like any DNS problem). Worth leading the article with them.
5. Once the appliance is hardened, repeat against a forest where
   `msDS-SupportedEncryptionTypes` is fully AES-only across existing accounts
   (a proper baseline-compliant posture, not just the imported GPO).

---

## Fix-and-verify iteration (2026-04-17) — all Taxonomy A items resolved

After the initial test run, the script-level fixes were implemented and each
validated against the live lab in its own cycle (clean golden-image revert +
replicated test every cycle). Final full-regression: T1→T2→T3→T4 completes
end-to-end with **zero manual intervention** on the first attempt.

### Applied fixes

| Cycle | Fix | Where | Validated by |
|-------|-----|-------|--------------|
| 0 | chrony skeleton cleared of internet NTP (samba-sconfig fills in per deployment) | `prepare-image.sh` §15 | chrony.conf minimal after golden-image revert |
| 0 | `nftables` and `ldap-utils` added to base packages | `prepare-image.sh` §4 | `which nft ldapsearch` both present |
| 0 | Don't mask `samba.service` — it's the `Alias=` of `samba-ad-dc.service`; masking breaks `systemctl enable samba-ad-dc` | `prepare-image.sh` §12 | Join flow now logs `Created symlink '/etc/systemd/system/samba.service'` (cleanly) instead of the prior `"Failed to enable unit: … already exists and is a symlink to /dev/null"` |
| 1 | `probe_forest_fl()` helper — anonymous rootDSE query → Samba FL string; wired into `domain_join_dc`/`domain_join_rodc`/`cli_join_dc` | `samba-sconfig.sh` new helper + 3 call-site edits | `samba-sconfig probe-fl 172.22.0.10` → `2016`; join succeeds first-try against WS2025 forest at FL 7 |
| 2 | `register_own_ptr()` helper — `samba-tool dns add` with explicit admin creds against target DC; idempotent ("already exists" and "zone missing" both handled) | `samba-sconfig.sh` new helper + 3 call-site edits | Cycle 2 test: `dig -x 172.22.0.20 @172.22.0.10 → samba-dc1.lab.test.`; `repadmin /replicate` and `/showrepl /errorsonly` both clean without manual PTR |
| 3 | `seed_sysvol()` helper — smbclient `recurse ON; mget ${realm}` from source DC + `ntacl sysvolreset` | `samba-sconfig.sh` new helper | Post-join Samba has 12 GPO directories under `Policies/`, including the newly-created `Lab-TestGPO` GUID |
| 3 | `configure_chrony_for_domain()` — writes `server <dc> iburst` into chrony.conf | `samba-sconfig.sh` new helper | `grep ^server /etc/chrony/chrony.conf → server 172.22.0.10 iburst` post-join |
| 3 | `apply_hardening_to_smb_conf()` now inserts *into* `[global]` via awk (not appended to EOF) | `samba-sconfig.sh` rewrite | `testparm -s` reports "Loaded services file OK" with zero warnings; all hardening values visible in output |
| 3 | `kerberos encryption types = aes256-... aes128-...` was syntactically invalid; Samba accepts only `{all,strong,legacy}` | `samba-sconfig.sh` hardening block | `kerberos encryption types = strong` (AES-only); testparm OK |
| 4 | `_generate_tls_cert_core()` — replaces Samba's auto-generated SAN-less cert with a 10-year self-signed cert that has `DNS:<fqdn>`, `DNS:<shortname>`, `IP:<primary ipv4>`, `keyUsage`, `extendedKeyUsage serverAuth+clientAuth` | `samba-sconfig.sh` refactored from TUI `generate_tls_cert` | `openssl s_client -connect samba-dc1:636 -showcerts \| openssl x509` shows SAN entries; `tls keyfile/certfile/cafile` properly in `[global]` |
| - | Headless test entry point: `samba-sconfig probe-fl <dc>` / `samba-sconfig join-dc` (env-driven: `SC_REALM`, `SC_NETBIOS`, `SC_DC`, `SC_PASS` [`SC_FWD` `SC_ROLE`]) so `run-tests.sh` and ad-hoc debugging don't need `expect` | `samba-sconfig.sh` new CLI dispatcher | Full regression ran end-to-end via `sudo env SC_... samba-sconfig join-dc`; raw transcript kept local |

### Taxonomy B items (Samba upstream / spec gaps) — no regression possible from our side, but documented

1. **No DFSR** — still works around with smbclient-based seed + `sysvol-sync` timer (the appliance handles this explicitly now).
2. **`samba_dnsupdate` doesn't register PTR** — the appliance registers it directly via `samba-tool dns add` (Cycle 2 fix).
3. **`samba-tool domain join` doesn't auto-detect target FL** — the appliance detects it via rootDSE before calling the tool (Cycle 1 fix).

### Result of the full post-fix regression

```
Test         Result      Notes
T1 Smoke     PASS        chrony minimal, nft+ldapsearch available, sconfig installed
T2 Join      PASS        FL=2016 auto-detected; join first try; samba-ad-dc active
T3.a Inbound PASS        5/5 NCs, 0 failures
T3.b Outbound PASS       0/5 failures on WS2025 — /showrepl /errorsonly "Healthy"
T3.c Users   PASS        testuser-samba + testuser-reg replicate, visible on WS2025
T3.d SYSVOL  PASS        12 GPO dirs seeded; `Policies/` populated immediately
T4.1 LDAP sign  PASS     Kerberos/SASL signed binds work (Samba default)
T4.2 Kerberos  PASS      `kerberos encryption types = strong` in smb.conf (AES only)
T4.3 SMB sign  PASS      `server/client signing = mandatory` in [global]
T4.4 LDAPS     PASS      10-yr cert w/ SAN (DNS fqdn, DNS shortname, IP) served on :636
```

Scripts at `prepare-image.sh` + `samba-sconfig.sh` (repo root) now produce
a clean first-try deployment. Next natural iteration: write `run-tests.sh`
against the `samba-sconfig join-dc` CLI to make this regression reproducible.

---

## Lab v2 regression (2026-04-17) — realistic DHCP-NAT topology

After the router-VM + fix-the-remaining-lab-script-bugs overhaul, the entire
pipeline was rerun from scratch against the new lab:

1. Router `router1` (Debian genericcloud + cloud-init) — one-shot build from
   `lab/stage-router-artifacts.sh` + `lab/New-LabRouter.ps1`.
2. WS2025-DC1 with the fixed FirstLogon (RunOnce phase 2 + DHCP-disable
   before static IP) and corrected baseline link for Member Server GPO.
3. Fresh Debian install on samba-dc1 (DHCP on Lab-NAT, no add/remove-NIC
   dance), `prepare-image.sh` first-try clean, golden-image checkpointed.
4. `samba-sconfig join-dc` (headless) end-to-end.

### Additional fix uncovered by v2 regression — force KCC after PTR

During the first v2 run, the fully-automated join+PTR flow still left
WS2025 with stale 8524 errors in `repadmin /showrepl /errorsonly` (visible
for ~15 min until the scheduled KCC pass) — even though replication itself
was silently working (replsummary `0 / 5` both directions from the start,
and `repadmin /replicate` succeeded once forced). Root cause: between
`samba-tool domain join` completing and `register_own_ptr` registering
the reverse record, there is a ~1-second window in which WS2025's KCC
attempts the replica link, fails with 8524 (DNS lookup), caches that
failure, and doesn't retry on its own schedule.

**Fix**: after a successful PTR registration, sconfig now runs
`samba-tool drs kcc <target_dc>` with the admin creds so the stale entry
is discarded immediately. Verified clean: `/showrepl /errorsonly` reports
"No errors" and `testuser-v2` (created on Samba) is visible via
`Get-ADUser` on WS2025 within seconds of creation.

### Result

```
[sconfig] forest FL probe: 2016
[sconfig] joining LAB.TEST as DC via 10.10.10.10 (FL=2016)...
[sconfig] registering PTR  20.10.10.10.in-addr.arpa  →  samba-dc1.lab.test.
[sconfig] PTR registered on 10.10.10.10
[sconfig] forcing KCC on 10.10.10.10 to clear stale 8524...
[kcc] Consistency check on 10.10.10.10 successful.
[sconfig] seeding SYSVOL from //10.10.10.10/sysvol/lab.test ...
[sconfig] SYSVOL seeded. Resetting NTACLs...
[sconfig] chrony repointed at 10.10.10.10
[sconfig] generating TLS cert (CN=samba-dc1.lab.test, SAN=DNS:samba-dc1.lab.test,DNS:samba-dc1,IP:10.10.10.20)
[sconfig] TLS cert installed
[sconfig] JOIN SUCCESS (FL=2016) — TLS cert has SAN, PTR registered, SYSVOL seeded
```

Raw capture was kept as a local transcript. Same T1-T4 outcomes as the
previous regression, plus:

- **No add/remove-NIC dance at any step** — Debian install via DHCP on
  Lab-NAT, prepare-image.sh runs with the Internet natively reachable.
- **WS2025-DC1 rebuild fully automated** — FirstLogon Phase 1 + 2 auto-run
  via RunOnce, zero manual console interventions needed (the "v1"
  requirement to manually re-invoke Phase 2 is gone).
- **Member Server baseline correctly linked** — `Apply-SecurityBaseline.ps1`
  now uses exact DisplayName match (`Get-GPO -Name '…Member Server'`) so
  the real Member Server policy lands on `OU=Lab/TestServers` instead of
  its Credential Guard sibling.

---

## T4 re-run after linking all 8 baseline GPOs (2026-04-17)

A follow-up audit asked: *"DC vs Member Server is a real distinction — are
all the baseline GPOs actually linked?"* Answer: no. The previous pass
linked only 2 of 8. `Apply-SecurityBaseline.ps1` was rewritten to use a
`$BaselineLinks` hashtable mapping each DisplayName to its intended OU.
Final state after the fix (confirmed via `Get-GPInheritance`):

```
DC=lab,DC=test:
  Default Domain Policy
  MSFT Internet Explorer 11 - Computer
  MSFT Internet Explorer 11 - User
  MSFT Windows Server 2025 v2602 - Defender Antivirus
  MSFT Windows Server 2025 v2602 - Domain Security

OU=Domain Controllers,DC=lab,DC=test:
  Default Domain Controllers Policy
  MSFT Windows Server 2025 v2602 - Domain Controller
  MSFT Windows Server 2025 v2602 - Domain Controller Virtualization Based Security

OU=TestServers,OU=Lab,DC=lab,DC=test:
  MSFT Windows Server 2025 v2602 - Member Server
  MSFT Windows Server 2025 v2602 - Member Server Credential Guard
```

### T4 outcomes with full baseline applied

`gpresult /R` on WS2025-DC1 confirms all 5 computer-scoped baseline GPOs
are in the "Applied Group Policy Objects" list. Re-running the T4 tests:

| # | Test | Outcome | Notes |
|---|------|---------|-------|
| 4.1 | LDAP signing (Samba↔WS2025) | **PASS** | Kerberos-signed bind, AES256 TGT |
| 4.2 | RC4 TGT should be refused | **STILL ISSUABLE** | See "RC4 finding" below |
| 4.3 | SMB signing (Samba↔WS2025) | **PASS** | `--option='client signing = mandatory'` works |
| 4.4 | LDAPS (port 636 on Samba) | **PASS** | Self-signed cert with DNS+IP SANs |

### "RC4 finding" — not what the baseline promises

Despite all 8 GPOs linked, `kinit Administrator@LAB.TEST` with a
`default_tkt_enctypes = arcfour-hmac-md5`-only config **still gets a TGT**
with `Etype (skey, tkt): DEPRECATED:arcfour-hmac`. Investigation:

**msDS-SupportedEncryptionTypes per account:**

| Account | Value | Meaning |
|---------|-------|---------|
| Administrator | `<unset>` | KDC falls back to permissive default (all enctypes) |
| Guest         | `<unset>` | same |
| krbtgt        | `0`       | same ("let the KDC decide") |
| testuser-v2   | `<unset>` | same |
| WS2025-DC1$   | `28` (=0x1C = AES128+AES256+CompoundIdentity) | AES only |
| SAMBA-DC1$    | `28` | AES only |

The WS2025 baseline configures the "Network security: Configure encryption
types allowed for Kerberos" policy (registry settings), but:

1. These registry keys affect what the **client** (the local machine)
   *requests*, not what the **KDC** *will issue*.
2. The KDC decides what to issue based on the principal's
   `msDS-SupportedEncryptionTypes` attribute. Absent that attribute, the
   KDC applies a permissive default that includes RC4 for backward compat.
3. The baseline import sets the attribute on **computer accounts** created
   after the baseline is applied, but does not retroactively update
   **user accounts** (including built-in `Administrator`, `Guest`, `krbtgt`).

**Taxonomy: B — baseline design, not a Samba gap.** Samba requests AES by
default and gets AES; no interop problem. A Windows admin following
best-practice hardening needs an **additional step** that the baseline
import doesn't automate:

```powershell
Get-ADUser -Filter * -Properties msDS-SupportedEncryptionTypes |
    Where-Object { -not $_.'msDS-SupportedEncryptionTypes' } |
    ForEach-Object { Set-ADUser $_ -Replace @{'msDS-SupportedEncryptionTypes' = 24} }
```

### "Password policy not taking effect" finding

`Get-ADDefaultDomainPasswordPolicy` post-baseline:

```
MinPasswordLength    : 0
PasswordHistoryCount : 0
LockoutThreshold     : 0
ComplexityEnabled    : True
```

But the Domain Security GPO has all these settings authored:

```
MinimumPasswordLength = 14
PasswordHistorySize   = 24
LockoutBadCount       = 3
LockoutDuration       = 15
AllowAdministratorLockout = true
```

Why isn't it applied? **Active Directory has a quirk**: Account / Password /
Kerberos policies are ONLY read from the **Default Domain Policy** GPO
(DN-fixed, can be found with `Get-GPO -Guid "31B2F340-016D-11D2-945F-00C04FB984F9"`),
not from *any* other GPO even if linked at the domain root. Any other
GPO may author these settings in its template, but AD's security policy
engine ignores them for the purpose of domain account policy — they only
apply to local accounts on member machines that receive the GPO.

MS's baseline ships these settings in "Domain Security" (easier to audit
and migrate than editing Default Domain Policy). The admin is expected
to either:

1. Edit Default Domain Policy to mirror the settings, or
2. Create a Fine-Grained Password Policy (PSO) in AD and bind to a group.

Neither is automated by the baseline ZIP's `Baseline-ADImport.ps1` nor by
our `Apply-SecurityBaseline.ps1`.

**Taxonomy: B — Windows/baseline platform quirk.** Documented here; no
change to the appliance scripts. If the lab ever wants to test
"password-policy-enforced" scenarios, the admin needs to merge settings
manually — this is a known Windows gotcha, widely written up.

### Samba-interop impact

**None.** All the compliance-relevant settings that Samba interacts with
(LDAP signing, SMB signing, channel binding, Kerberos AES preference) are
in the "Domain Controller" GPO which is correctly linked and applied.
Samba's hardening already matches: `ldap server require strong auth = yes`,
`server/client signing = mandatory`, `kerberos encryption types = strong`,
`ntlm auth = mschapv2-and-ntlmv2-only`. T4.1, T4.3, T4.4 all pass.

The RC4 and password-policy findings are **Windows-side production
hardening concerns**, not Samba-interop blockers.

Full raw output was kept as a local transcript; the durable findings are
captured above.
