version: 2
ethernets:
  # Match by name glob, not a single hard-coded interface name. The cloud
  # image's predictable-naming policy gives different names per
  # hypervisor: Hyper-V's hv_netvsc still uses eth0, virtio-net on
  # qemu/Synology gives ens3, VMware vmxnet3 gives ens33, KVM/libvirt
  # default gives enp1s0, etc. "e*" covers all of these without forcing
  # a kernel-cmdline net.ifnames=0 override.
  primary:
    match:
      name: "e*"
    dhcp4: true
    dhcp6: false
    # Force a MAC-based DHCP client-id instead of systemd-networkd's
    # default DUID. Without this, dnsmasq sees the DUID as the client-id
    # and refuses to match the MAC-only `dhcp-host=` reservation in the
    # lab-router config — handing out a dynamic-pool address instead of
    # the reserved 10.10.10.20. samba-dc1 currently works only because
    # dnsmasq happens to remember its prior lease; a fresh
    # `lab/build-fresh-base.sh -f` rebuild would otherwise hit the same
    # DHCP-pool-instead-of-reservation bug the proxy hit on its first
    # build attempt. See dev-commons/audits/2026-05-01-style-compliance.md
    # finding H1 and dev-commons/STYLE.md §6.
    dhcp-identifier: mac
