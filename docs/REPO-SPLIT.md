# Repository Split Plan

This project started as one repository containing the Samba appliance, the lab
router, and the lab orchestration scripts. The target shape is three separate
repositories developed side by side locally.

## Repositories

### `lab-kit`

Reusable appliance lab orchestration.

Responsibilities:

- generic scenario runner
- hypervisor backends
- reusable helper scripts
- topology and scenario conventions
- log collection

It should not contain Samba-specific appliance logic.

### `lab-router`

Simple lab router virtual appliance.

Responsibilities:

- Debian cloud router image staging
- cloud-init templates
- dnsmasq DHCP/DNS forwarding
- nftables NAT
- simple multi-subnet/VLAN configuration model
- runtime reconfiguration path

It should not become a general network appliance and should not know about
Samba except through examples.

### `samba-addc-appliance`

Samba AD DC appliance.

Responsibilities:

- Debian image preparation for Samba AD DC
- `samba-sconfig`
- Samba/Windows interop documentation
- Samba-specific test scenarios
- lab definitions that consume `lab-kit` and `lab-router`

## Local Development Layout

Expected sibling checkout layout:

```text
Debian-SAMBA/
  lab-kit/
  lab-router/
  samba-addc-appliance/
```

The Samba repo can continue to carry compatibility copies of lab scripts while
the split settles. New reusable lab/router work should happen in the sibling
repos first, then Samba-specific tests can consume those tools.

## Migration Order

1. Extract `lab-router` with current router image staging and Hyper-V creation.
2. Extract `lab-kit` with generic scenario runner and Hyper-V helper scripts.
3. Update Samba docs to use the siblings for new work.
4. Move Samba-specific appliance files under clearer paths after tests are
   stable against the sibling tools.
5. Physically publish all three repos.
6. Remove compatibility copies from the Samba repo once scenarios use the
   sibling tools directly.
