# Three-Repo Layout

This project started as one repository containing the Samba appliance,
the lab router, and the lab orchestration scripts. It now lives in
three sibling repositories developed side by side locally:

```text
Debian-SAMBA/
  lab-kit/               reusable appliance lab orchestration
  lab-router/            reusable router VM builder
  samba-addc-appliance/  this repo
```

The split is substantively complete. This doc is a reference for where
things live and where new work should go.

## Repositories

### `lab-kit`

Reusable appliance lab orchestration. Ships today:

- `bin/run-scenario.sh` — generic pipeline: stage, reset, push,
  post-push, pre_hook, run_scenario, verify, post_hook.
- `hypervisors/hyperv/Revert-TestVM.ps1` — generic revert helper.
- `examples/samba-addc.env` — reference env file for an appliance
  consumer.
- `scenarios/common/` — shared scenario fragments.
- `docs/architecture.md`, `docs/hypervisors.md`.

Boundary: no appliance-specific logic. No Samba strings in code. Hyper-V
is the first backend, but libvirt/VMware should be addable without
reshaping the runner.

### `lab-router`

Simple lab router virtual appliance. Ships today:

- `scripts/stage-router-artifacts.sh` — Mac-side stager that produces
  a reusable base VHDX and a per-router cloud-init seed ISO. Accepts
  CLI flags, `--config YAML` (single-LAN), and `--extra-dnsmasq`
  raw snippets (and merges them).
- `templates/cloud-init/*.tpl` — Debian 13 cloud-init templates
  (nftables NAT, dnsmasq DHCP/DNS, hardened SSH).
- `hypervisors/hyperv/New-LabRouter.ps1` — Hyper-V VM builder.
- `configs/*.yaml` and `configs/samba-addc.dnsmasq.conf` — example
  configs, including a Samba-flavored example.
- `docs/configuration.md` — YAML schema and what the stager reads.

Boundary: does not depend on `samba-addc-appliance`. Samba-flavored
content exists only as named examples under `configs/`. Out of scope:
VPN, captive portal, WireGuard, firewall zones beyond NAT + lab LAN.

### `samba-addc-appliance`

Samba AD DC appliance and its Samba-specific tests.

- `prepare-image.sh`, `samba-sconfig.sh` — the appliance itself.
- `lab/run-scenario.sh` — thin Samba wrapper around
  `../lab-kit/bin/run-scenario.sh`.
- `lab/samba.env` — appliance-specific wiring for the lab-kit runner.
- `lab/scenarios/*.sh` — Samba scenarios (`join-dc`,
  `smoke-prepared-image`).
- `lab/hyperv/*.ps1 *.xml` — Hyper-V/WS2025-specific helpers (WS2025
  build, baseline apply, AD cleanup, Samba VM creation, Windows-side
  verification, unattend file).
- `docs/` — SETUP, LAB-TESTING, REPO-SPLIT (this file),
  AGENTIC-DEVELOPMENT.

Boundary: reusable lab/router work belongs in the sibling repos. This
repo should only host code specific to testing the Samba appliance
against a WS2025 forest.

## Dependency Direction

```text
samba-addc-appliance
  consumes lab-kit (runner, revert helper)
  consumes lab-router (router stager, New-LabRouter.ps1, configs)

lab-kit
  does not depend on any appliance repo

lab-router
  does not depend on lab-kit or any appliance repo
```

## Migration History

The original split plan was six ordered steps. Status:

1. Extract `lab-router` with current router image staging and Hyper-V
   creation. **Done.**
2. Extract `lab-kit` with generic scenario runner and Hyper-V helper
   scripts. **Done.** Runner gained `LAB_STAGE_SOURCES` /
   `LAB_POST_PUSH_CMD` / `LAB_HOST_STAGE_DIR` hooks so Samba-specific
   behavior lives in the env file, not the runner.
3. Update Samba docs to use the siblings for new work. **Done.**
4. Move Samba-specific appliance files under clearer paths after tests
   are stable against the sibling tools. **Done** — Hyper-V/WS2025
   helpers now live under `lab/hyperv/`.
5. Physically publish all three repos. **Done** — pushed to
   `hooman/lab-kit`, `hooman/lab-router`, `hooman/samba-addc-appliance`.
6. Remove compatibility copies from the Samba repo once scenarios use
   the sibling tools directly. **Done** — Samba repo no longer carries
   `New-LabRouter.ps1`, `Revert-TestVM.ps1`, `stage-router-artifacts.sh`,
   or `seed/`.

## Publishing

Each repo is independently pushable:

```bash
git -C lab-kit push origin main
git -C lab-router push origin main
git -C samba-addc-appliance push origin main
```

There is no meta-repo. Updates that cross boundaries should be landed
as ordered commits (dependency first, consumer second) and pushed in
the same order.
