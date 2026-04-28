#cloud-config
# Per-VM cloud-init seed for the Samba AD DC appliance base image.
# Substituted by lab/stage-samba-base.sh from CLI flags + ssh pubkey.
# Placeholder names used below (each wrapped in @@...@@ in the template):
#   HOSTNAME, FQDN, DOMAIN, USERNAME, SSH_PUBKEY

hostname: @@HOSTNAME@@
fqdn: @@FQDN@@
manage_etc_hosts: true

users:
  - name: @@USERNAME@@
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [sudo, adm]
    shell: /bin/bash
    ssh_authorized_keys:
      - @@SSH_PUBKEY@@

ssh_pwauth: false
disable_root: true

# prepare-image.sh runs apt update + upgrade itself; running them here just
# doubles first-boot time without changing the final state.
package_update: false
package_upgrade: false

runcmd:
  # Disable cloud-init for subsequent boots — its job is done after this
  # one-shot first run. The appliance behaves like a normal Debian box from
  # now on. prepare-image.sh's package purge can drop the cloud-init package
  # entirely later if desired; the rendered network config in
  # /etc/netplan/50-cloud-init.yaml persists either way.
  - touch /etc/cloud/cloud-init.disabled
  # Set a documented default password for @@USERNAME@@. ssh_pwauth: false above
  # means this password only works at the console; SSH stays key-only. The
  # samba-init wizard on TTY1 forces the operator to change it before they
  # can mark setup complete. The marker /var/lib/samba-init-default-password
  # tells the wizard the password is still the factory default.
  - 'echo "@@USERNAME@@:samba-appliance-please-change-me" | chpasswd'
  - 'mkdir -p /var/lib && touch /var/lib/samba-init-default-password'
  # Marker for the orchestrator (lab/build-fresh-base.sh) to poll.
  - 'echo "samba-base-ready: $(date --iso-8601=seconds)" > /var/log/samba-base-ready.marker'

final_message: "@@HOSTNAME@@ ready in $UPTIME seconds (cloud-init)"
