version: 2
ethernets:
  eth0:
    dhcp4: true
    dhcp6: false
  eth1:
    dhcp4: false
    dhcp6: false
    addresses:
      - @@LAN_IP@@/@@LAN_PREFIX@@
