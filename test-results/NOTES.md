# Running notes — Samba AD DC + WS2025 interop lab

Format: observations, surprises, and decisions made while executing
the test plan. Intended source material for a write-up.

## Environment snapshot (start of run)

- **Date:** 2026-04-16
- **Samba:** 4.22.8 (Debian 13 Trixie package)
- **WS2025:** Standard Evaluation, Server Core, build 26100.32230
- **Baseline:** MSFT Windows Server 2025 v2602 Security Baseline, linked to `OU=Domain Controllers` and `OU=TestServers`
- **Debian:** 13 Trixie, netinst, minimal
- **Hypervisor:** Hyper-V on Windows Server 2025 host

## Pre-test findings (already known from image build)

### prepare-image.sh section 8 — Microsoft PowerShell install broke twice

- **Symptom 1:** `apt-get update` failed with `Missing key EE4D7792F748182B` (sqv verification).
  Debian 13 (Trixie) replaced `gpgv` with `sqv` (Sequoia) as the default apt
  signature verifier. It's stricter than gpgv and rejects Microsoft's current
  repo metadata signature because one subkey is missing from the keyring.
- **Symptom 2:** Even after working around `apt-get update`, `curl … | gpg --dearmor`
  failed under non-interactive sudo with `gpg: cannot open '/dev/tty'`. The gpg
  stack tries to contact an agent/pinentry, which needs a tty even for a
  pure-format `--dearmor` operation.
- **Resolution:** Dropped the Microsoft apt repo path entirely; always install
  from the GitHub-hosted `.deb`. One external HTTP GET, no GPG, no repo
  pollution. The MS repo can be re-enabled later if/when Microsoft's signing
  story catches up to Trixie's sqv.
- **Taxonomy:** A — our-config/script fix. Resolved before running tests.

### lab/FirstLogon-PromoteToDC.ps1 phase-2 never auto-runs

- **Symptom:** After `Install-ADDSForest` reboots the WS2025 VM, the phase-2
  block of the script (OUs, DNS-to-self, forwarders, reverse zone,
  setup-complete marker) never executes.
- **Root cause:** `<FirstLogonCommands>` fires only on the first logon before
  any reboot. There is no mechanism in the current unattend+script to re-invoke
  on the post-promotion logon.
- **Workaround used:** Manually re-invoked `C:\Setup\FirstLogon-PromoteToDC.ps1`
  via PSDirect. Since `phase2.marker` exists from phase 1, the script took the
  phase-2 branch cleanly.
- **Taxonomy:** A — our-config/script fix. Documented; not yet patched in
  script source. Next rebuild will need: end of phase 1 should register a
  RunOnce key or Scheduled Task to re-run on next logon.

### lab/Apply-SecurityBaseline.ps1 linked the wrong Member Server GPO

- **Symptom:** Pattern `*Member Server*` with `Select-Object -First 1` picked
  *"… Member Server Credential Guard"* instead of the main "… Member Server"
  baseline. Main Member Server hardening is imported but not linked to
  `OU=TestServers`.
- **Resolution:** Not retroactively fixed (TestServers OU is not used by the
  current test scenario). One-line retrofit documented.
- **Taxonomy:** A — our-config/script fix.

## Test execution log

### T1 — Smoke (golden-image revert → boot) — **PASS** with caveats

Checks that succeeded:
- Revert + boot clean; SSH up within 10s
- eth0 static 172.22.0.20/24, default route via 172.22.0.1 (internal, no NAT)
- `samba-ad-dc` disabled + inactive as intended (prepare-image disables it; actual mask is applied only to `samba`, `winbind`, `nmbd`, `smbd` — the file-server stack)
- `samba --version` → 4.22.8-Debian
- `pwsh` → 7.6.0
- `/usr/local/sbin/samba-sconfig` present
- No `/etc/samba/smb.conf` (as intended pre-deploy)
- `/etc/krb5.conf` is the skeleton with `YOURREALM.LAN` placeholder
- No DC ports listening (as intended pre-deploy)

Caveats uncovered that will matter for T2:

- **chrony config points at internet pools** (cloudflare, google, debian). The
  internal Lab-Internal switch has no NAT, so chrony never gets a usable source
  and system time drifts. For join against WS2025 this is critical (Kerberos
  requires ≤5 min clock skew). **Taxonomy: A** — `samba-sconfig` should write
  a chrony config pointing at `172.22.0.10` (or the DC the VM is joining)
  before `samba-tool domain join` runs. Workaround for T2: manual
  reconfiguration before the join.
- **`nft` binary not installed** — `prepare-image.sh` writes a firewall
  ruleset file but the `nftables` package isn't pulled in. `nftables.service`
  unit is present but the tool isn't. **Taxonomy: A** — add `nftables` to the
  package install list in `prepare-image.sh`. Will verify whether it actually
  affects T2 (samba-sconfig's firewall step should install/activate rules).

Result written to `T1-smoke.log`.

### T2 — Join WS2025 as additional DC — **PASS** after one config fix

First attempt (documented in `T2-join.log`) failed with:

```
ERROR(runtime): uncaught exception - DsAddEntry failed
DsAddEntry failed with status WERR_ACCESS_DENIED info (8567, 'WERR_DS_INCOMPATIBLE_VERSION')
```

Classic symptom of a schema-version/FL mismatch during NTDSDSA object creation.

Root cause from WS2025 Directory Service event log (1725, Warning):

> The request to add a new NTDS Settings object was denied because the highest
> functional level supported by the operating system was lower than the
> functional level of the forest.
> Highest functional level of the operating system: 4
> Forest functional level: 7

- OS level `4` = Server 2008 R2 (what Samba was advertising)
- Forest level `7` = Server 2016 / WinThreshold (what WS2025 provisioned into)

This is a **Samba default**, not a gap. The smb.conf parameter
`ad dc functional level` defaults to `2008_R2` in Samba 4.22 for historical
compatibility. Recent Samba versions (4.19+) support `2016` but do not default
to it — presumably to avoid silently upgrading existing lab/test setups.

**Fix (applied):** pass `--option="ad dc functional level = 2016"` to
`samba-tool domain join`. Second attempt succeeded end-to-end:
join → NTDSDSA added → schema+config+domain NCs replicated → SAMBA-DC1 entered
`OU=Domain Controllers`.

Post-join verification:
- `samba-ad-dc` active; ports 53, 88 (TCP), 389, 445, 464, 636, 3268 all listening
- `net ads info -P`: LDAP/KDC server = 172.22.0.10 (WS2025), server time offset = 0
- `kinit Administrator@LAB.TEST` succeeds; TGT granted

**Taxonomy for this finding:** Partially A, partially B.
- **A-side:** our `samba-sconfig` TUI must write `ad dc functional level = 2016`
  (or the detected remote forest level) into `smb.conf` before invoking
  `samba-tool domain join`, since Samba's default produces a silent failure
  against any modern AD forest. This is something we should fix in our
  appliance scripts before release.
- **B-side:** Samba doesn't *detect* the target forest's functional level
  during join and auto-set its own. A user running `samba-tool domain join`
  against a 2016+ forest gets a cryptic `WERR_DS_INCOMPATIBLE_VERSION`
  instead of an actionable message. Worth filing upstream.

**Recommendation for the appliance:** `samba-sconfig` join flow should first
probe the target DC's `domainFunctionality` / `forestFunctionality` rootDSE
attributes, then set `ad dc functional level` to match.

Also noted in passing:
- `prepare-image.sh` leaves `samba.service` masked via `/dev/null` symlink.
  Post-join `systemctl enable samba-ad-dc` emits a harmless warning:
  `Failed to enable unit: File '/etc/systemd/system/samba.service' already
  exists and is a symlink to /dev/null`. The `samba-ad-dc` unit still enables
  cleanly via its own symlink. **Taxonomy: A**, cosmetic — could be cleaned
  up by using `systemctl mask samba nmbd smbd winbind` only after checking
  they aren't the main DC unit.
- Hyper-V Integration Services time-sync keeps all lab clocks within ~15s
  without needing chrony reachable. Chrony's configured NTP pools are
  unreachable on the no-NAT internal switch; harmless but confusing.
  **Taxonomy: A**, `samba-sconfig` should rewrite chrony to target the DC
  we are joining (or the lab gateway) with `ntpsigndsocket` for SNTP
  signing support.

Result written to `T2-join.log` and `T2-join-ws2025-events.log`.

### T3 — Replication + functional — **PASS** with one pre-fix, one structural Samba gap

#### T3.a — Inbound replication (WS2025 → Samba) — clean from the start

`samba-tool drs showrepl` on the Samba side shows all five partitions
(`DC=lab,DC=test`, `CN=Configuration,...`, `CN=Schema,...`, `DC=DomainDnsZones,...`,
`DC=ForestDnsZones,...`) replicating via RPC with zero consecutive failures.

#### T3.b — Outbound replication (Samba → WS2025) — **failed initially with a mis-leading error**

`repadmin /showrepl /errorsonly` on WS2025 reported across all 5 NCs:

```
Last error: 8524 (0x214c):
  The DSA operation is unable to proceed because of a DNS lookup failure.
```

Event `1925` in Directory Service log made it concrete:

```
Source directory service address: 0f681b9d-…-4782d98718cb._msdcs.lab.test
```

That GUID CNAME resolved correctly from WS2025 (slow — 600 ms first time, warm after — but it resolved). The A record for `samba-dc1.lab.test` resolved in 2 ms. The real missing piece was the **PTR** record for `172.22.0.20`:

```
0.22.172.in-addr.arpa zone contents:
  10 -> WS2025-DC1.lab.test.
  (no 20 -> samba-dc1.lab.test — missing)
```

After adding it manually:

```powershell
Add-DnsServerResourceRecordPtr -ZoneName '0.22.172.in-addr.arpa' \
    -Name 20 -PtrDomainName 'samba-dc1.lab.test'
```

`repadmin /kcc WS2025-DC1` re-ran the consistency check, `repadmin /replicate` from WS2025 to pull from Samba returned `completed successfully`, and `/showrepl /errorsonly` reported "No errors". **`repadmin /replsummary` now shows 0 / 5 failures in both directions.**

**Taxonomy:** Mixed A + B.
- **B (Samba):** `samba_dnsupdate` does not register a PTR record for the DC itself. It registers forward A/CNAME/SRV entries from `dns_update_list`, but the reverse zone is ignored. On most production AD deployments the admin adds PTRs manually, so Samba's behavior is consistent with a legacy Windows-admin workflow — but it breaks Windows KCC when Samba is the source DC.
- **Windows surface:** the reported error `8524 / DNS lookup failure` is uselessly vague. The KCC cannot add a REPLICA LINK because the source DC's reverse lookup doesn't resolve. The actual DNS operation that fails is the KCC's implicit `PTR` check on the source DC's IP. This is a classic "Samba-joined-to-Windows" gotcha that is widely reported on mailing lists but under-documented in official docs.
- **A (our appliance):** `samba-sconfig` join flow must ensure the PTR record is created (either by discovering the reverse zone and calling `samba-tool dns add` with GSS-TSIG, or by documenting that the admin must add it on WS2025). Cleanest: the TUI's "Join domain" step auto-registers its own PTR.

#### T3.c — Functional round-trips — **PASS**

- `testuser-samba` created via `samba-tool user create`, replicated, visible via `Get-ADUser` on WS2025 as `CN=From Samba,CN=Users,DC=lab,DC=test`.
- `testuser-ws2025` created via `New-ADUser`, replicated back; `samba-tool user show` on Samba returns the full object with `objectClass: user`, correct `cn/sn/givenName`, `instanceType: 4`.
- `Lab-TestGPO` created on WS2025 via `New-GPO`; `samba-tool gpo listall` shows it on the Samba side along with all 10 baseline GPOs that existed before the join. **GPO AD objects replicate correctly.**

#### T3.d — SYSVOL file replication — **Samba gap, workaround present**

- `/var/lib/samba/sysvol/lab.test/` exists but `Policies/` stays empty after a new GPO is created on WS2025. Samba does not implement DFSR.
- The `prepare-image.sh` + `samba-sconfig` stack anticipates this: it installs a `sysvol-sync` helper script (rsync over SSH, pull or push modes) and expects `samba-sconfig` to write `/etc/samba/sysvol-sync.conf` at deployment time.
- Demonstrated that **smbclient-based pull** works as an ad-hoc fallback:
  `smbclient //ws2025-dc1/sysvol -U LAB\Administrator -c "recurse ON; mget lab.test"` — fetched all 17 policy directories including `{10044A0D-…}` (Lab-TestGPO) into `/tmp/lab.test/Policies/`.
- **Taxonomy: B (Samba architectural gap).** Upstream is unlikely to implement DFSR in the foreseeable future. Workaround is rsync over SSH (what `sysvol-sync` does).

**Recommendation:** `samba-sconfig` should install a systemd timer that runs `sysvol-sync` every 5–15 minutes after a "Join as additional DC" deployment, and an `inotify`-triggered one-shot for urgent changes. Alternatively, a `--source=smb` mode that uses smbclient instead of rsync would let it work even when SSH isn't set up to the Windows DC (Windows DCs rarely have sshd listening).

#### T3.e — smbclient with Kerberos cred-cache — minor usability note

`sudo kinit Administrator@LAB.TEST` followed by `smbclient -k //...` failed with:
```
gensec_gse_client_prepare_ccache: No password for user principal[debadmin@LAB.TEST]
NT_STATUS_INVALID_PARAMETER
```
The TGT is stored against `root` (because we used `sudo`), but `smbclient` is evaluating the client principal based on `$USER` (`debadmin`). Fixes:
- `sudo KRB5CCNAME=/tmp/krb5cc_0 smbclient -k ...`, or
- `smbclient ... -U 'Administrator@LAB.TEST' --password=...` (no `-k`; uses SPNEGO/GSSAPI with explicit creds).
- **Taxonomy: A (our scripts/docs).** Worth a note in the `samba-sconfig` "Test SYSVOL" menu.

Results in `T3-replication.log` and `T3-functional.log`.

### T4 — Baseline compliance — **mostly PASS**, one baseline gap worth flagging

#### T4.1 — LDAP signing — **Samba complies**

`ldbsearch` against WS2025 over `ldap://` with a valid Kerberos TGT (AES256
session key) returns the requested attribute. Samba's LDAP client defaults
to GSS-API sign (and seal when requested), so WS2025 baseline's
`LDAPServerIntegrity = 1` ("require signing") + `LdapEnforceChannelBinding = 2`
("required") don't block any Samba operation that uses SASL-bound LDAP.

#### T4.2 — Kerberos encryption types — **Samba fine, baseline incomplete**

**Samba side:** the machine accounts for both DCs carry
`msDS-SupportedEncryptionTypes: 28` (= `0x1C`, RC4 + AES128 + AES256). Samba
requests AES256 by default; AES256 TGTs are issued and all interop works with
`aes256-cts-hmac-sha1-96` session keys.

**Baseline gap (not Samba's fault):** with an explicitly RC4-only MIT `krb5.conf`
(`default_tkt_enctypes = arcfour-hmac-md5`, `allow_weak_crypto = true`),
`kinit Administrator@LAB.TEST` **succeeds** and returns a TGT whose `klist -e`
output shows:

```
Etype (skey, tkt): DEPRECATED:arcfour-hmac, DEPRECATED:arcfour-hmac
```

`LAB\Administrator` has no `msDS-SupportedEncryptionTypes` attribute set,
so the KDC falls back to "all enctypes permitted" for that principal. The
WS2025-2602 baseline GPO enforces enctypes via
`Network security: Configure encryption types allowed for Kerberos` policy,
but that controls what the KDC **advertises**, not what it will serve. To
actually deny RC4 to a user, `msDS-SupportedEncryptionTypes` must be set on
the user object itself — which the baseline doesn't do retroactively for
existing accounts created before the GPO was linked.

**Taxonomy:** B-adjacent, but this is a **Windows-side baseline completeness
issue**, not a Samba gap. Worth flagging in the write-up because many people
assume "baseline applied = RC4 gone". To actually lock out RC4 for
`LAB\Administrator` and other pre-baseline accounts:

```powershell
Set-ADUser Administrator -Replace @{
    "msDS-SupportedEncryptionTypes" = 24
}   # 24 = 0x18 = AES128 + AES256 only
```

**Baseline loosening recommendation:** *none required for Samba interop*.
Samba joins, replicates, and serves just fine with the baseline as-is.

#### T4.3 — SMB signing — **Samba complies**

`smbclient //ws2025-dc1.lab.test/sysvol` connects and lists directories with
both `--client-protection=sign` and `--option='client signing = mandatory'`.
Samba's SMB2/3 client negotiates signing by default, matching the WS2025
baseline's `RequireSecuritySignature = 1`.

#### T4.4 — LDAPS on Samba (port 636) — **works out of the box, caveats**

`openssl s_client -connect samba-dc1:636` shows Samba auto-generated a
self-signed cert during provision/join:

- Subject: `O=Samba Administration, OU=Samba - temporary autogenerated HOST certificate, CN=SAMBA-DC1.lab.test`
- Issuer: self-signed CA of the same name
- Valid Apr 17 2026 → Mar 17 2028 (2 years)
- Key: RSA 4096, sha256WithRSAEncryption
- **No subjectAltName extension**

Caveats:
- Windows clients that strictly validate chains (or require SAN per RFC 5280)
  will reject this cert. LDAPS works for Samba itself and for OpenSSL but
  is unsuitable for most Microsoft clients.
- The cert expires in 2 years. A production appliance needs a rotation
  story — either issuing from an internal CA (what `samba-sconfig` menu 5
  should eventually do) or a Let's Encrypt / ACME integration for public
  deployments.

**Taxonomy: A.** Our `samba-sconfig` TLS/cert workflow must produce a cert
with (a) SAN entries (DNS: FQDN, IP: primary IP), (b) a proper CA chain —
ideally signed by a CA that Windows trusts (e.g., import into SYSVOL root
CAs via GPO), (c) auto-rotation before expiry.

#### T4.5 — LDAPS on WS2025 — not applicable to Samba appliance, noted for lab posture

WS2025 accepts TLS on port 636 (TLSv1.3 handshake succeeds) but does not
present a cert — this lab DC has no AD Certificate Services role installed,
so no cert got auto-enrolled for the DC. Production lab validation would
deploy AD CS or manually install a DC cert. Not a Samba concern.

#### T4 summary

| Area | Samba behavior | WS2025 baseline | Verdict |
|---|---|---|---|
| LDAP signing | GSS-SASL sign by default | Require signing | ✅ Compatible |
| LDAP channel binding | Handled by SSPI/GSS | Required | ✅ Compatible |
| Kerberos AES | AES256 preferred | AES-only **policy** but per-account attr unset | ⚠️ Works, baseline has a latent RC4 acceptance |
| SMB signing | Mandatory by default | Require signature | ✅ Compatible |
| LDAPS (Samba side) | Self-signed, no SAN, 2y validity | Expects real cert w/ SAN | ⚠️ A-taxonomy: needs sconfig cert management |
| LDAPS (WS2025 side) | N/A | No cert; needs AD CS | Out of scope |

Result in `T4-baseline.log`.

