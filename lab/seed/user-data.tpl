#cloud-config
# Template consumed by lab/stage-router-artifacts.sh
# Placeholders: @@HOSTNAME@@ @@FQDN@@ @@DOMAIN@@ @@LAN_IP@@ @@LAN_SUBNET_CIDR@@
#               @@DHCP_START@@ @@DHCP_END@@ @@SSH_PUBKEY@@ @@EXTRA_DNSMASQ@@

hostname: @@HOSTNAME@@
fqdn: @@FQDN@@
manage_etc_hosts: true

users:
  - name: hm
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo, adm]
    shell: /bin/bash
    ssh_authorized_keys:
      - @@SSH_PUBKEY@@

ssh_pwauth: false
disable_root: true

package_update: true
package_upgrade: false
packages:
  - nftables
  - dnsmasq
  - iputils-ping
  - curl
  - htop
  - tcpdump

write_files:
  - path: /etc/sysctl.d/99-ipforward.conf
    permissions: '0644'
    content: |
      net.ipv4.ip_forward=1
      net.ipv6.conf.all.forwarding=0

  - path: /etc/nftables.conf
    permissions: '0755'
    content: |
      #!/usr/sbin/nft -f
      flush ruleset

      table inet filter {
        chain input {
          type filter hook input priority 0; policy drop;
          iif "lo" accept
          ct state established,related accept
          ip protocol icmp accept
          iifname "eth1" tcp dport 22 accept
          iifname "eth1" udp dport 53 accept
          iifname "eth1" tcp dport 53 accept
          iifname "eth1" udp dport 67 accept
          iifname "eth0" tcp dport 22 accept
          log prefix "nft-drop: " limit rate 5/minute
          drop
        }
        chain forward {
          type filter hook forward priority 0; policy drop;
          ct state established,related accept
          iifname "eth1" oifname "eth0" accept
        }
        chain output {
          type filter hook output priority 0; policy accept;
        }
      }

      table ip nat {
        chain postrouting {
          type nat hook postrouting priority srcnat;
          oifname "eth0" masquerade
        }
      }

  - path: /etc/dnsmasq.d/lab.conf
    permissions: '0644'
    content: |
      # Serve only on the LAN interface
      interface=eth1
      bind-interfaces
      listen-address=@@LAN_IP@@,127.0.0.1

      # Manage our own upstream — don't read /etc/resolv.conf
      no-resolv
      no-poll

      # Dynamic DHCP pool
      dhcp-range=@@DHCP_START@@,@@DHCP_END@@,12h
      dhcp-option=option:router,@@LAN_IP@@
      dhcp-option=option:dns-server,@@LAN_IP@@
      dhcp-option=option:domain-name,@@DOMAIN@@

@@EXTRA_DNSMASQ@@

      # Upstream public DNS for everything else
      server=1.1.1.1
      server=8.8.8.8

      domain-needed
      bogus-priv
      cache-size=1000
      log-queries
      log-dhcp

  - path: /etc/systemd/resolved.conf.d/no-stub.conf
    permissions: '0644'
    content: |
      [Resolve]
      DNSStubListener=no

runcmd:
  - sysctl --system
  - mkdir -p /etc/systemd/resolved.conf.d
  - systemctl restart systemd-resolved 2>/dev/null || true
  - rm -f /etc/resolv.conf
  - 'printf "nameserver 127.0.0.1\nsearch @@DOMAIN@@\n" > /etc/resolv.conf'
  - systemctl enable --now nftables
  - nft -f /etc/nftables.conf
  - systemctl enable --now dnsmasq
  - 'echo "router-ready: $(date --iso-8601=seconds)" > /var/log/router-ready.marker'

final_message: "@@HOSTNAME@@ up in $UPTIME seconds (cloud-init)"
