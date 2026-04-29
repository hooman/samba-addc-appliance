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
