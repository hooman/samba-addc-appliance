# lab/scenarios/provision-new.sh — provision a brand-new forest, no Windows
# DC dependency. Validates the standalone path that's normally exercised by
# hand only.
#
# The forest realm intentionally differs from the WS2025 lab forest
# (lab.test) so the WS2025 DC has no awareness of this provision and
# nothing on the lab needs cleaning up afterward — the next scenario that
# reverts samba-dc1 back to golden-image is its own reset.
#
# Sourced by lab/run-scenario.sh. Has access to ssh_host / ssh_vm /
# scp_to_vm / say / step helpers and the LAB_VM_* / LAB_HV_* variables.
#
# Overridable via env:
#   SC_REALM, SC_NETBIOS, SC_PASS, SC_FWD

SC_REALM="${SC_REALM:-test.lan}"
SC_NETBIOS="${SC_NETBIOS:-TEST}"
SC_PASS="${SC_PASS:-P@ssword123456!}"
SC_FWD="${SC_FWD:-10.10.10.1}"

run_scenario() {
    ssh_vm "sudo env \
        SC_REALM='$SC_REALM' \
        SC_NETBIOS='$SC_NETBIOS' \
        SC_PASS='$SC_PASS' \
        SC_FWD='$SC_FWD' \
        samba-sconfig provision-new"
}

verify() {
    local rc=0 out
    # Pre-compute the upper-case realm: macOS's stock bash 3.2 doesn't
    # support ${var^^}, so doing the transform locally and substituting
    # the result keeps the scenario portable across the orchestrator host.
    local realm_uc
    realm_uc=$(echo "$SC_REALM" | tr '[:lower:]' '[:upper:]')

    say "samba-ad-dc is active"
    ssh_vm 'sudo systemctl is-active samba-ad-dc' || rc=1

    say "smb.conf reflects the new realm"
    out=$(ssh_vm 'sudo grep -E "^\s*(realm|workgroup|server role)" /etc/samba/smb.conf' 2>&1 || true)
    echo "$out"
    grep -qiE "realm[[:space:]]*=[[:space:]]*${SC_REALM}" <<< "$out" || { say "realm mismatch"; rc=1; }
    grep -qiE "workgroup[[:space:]]*=[[:space:]]*${SC_NETBIOS}" <<< "$out" || { say "netbios mismatch"; rc=1; }

    say "Administrator account exists with the new password"
    # net ads info uses the local KDC; if the freshly-provisioned KDC answers
    # a kinit, the password and basic auth chain are healthy.
    ssh_vm "sudo bash -c 'echo \"$SC_PASS\" | kinit Administrator@${realm_uc}'" || rc=1
    ssh_vm "sudo klist 2>&1 | grep -q 'krbtgt/${realm_uc}@${realm_uc}'" || rc=1

    say "DNS forward zone exists for the realm and resolves the DC"
    ssh_vm "dig @127.0.0.1 ${SC_REALM} ANY +short | head -5" || rc=1
    out=$(ssh_vm "dig @127.0.0.1 -t SRV _ldap._tcp.${SC_REALM} +short" 2>&1 || true)
    echo "$out"
    grep -qE "samba-dc1\.${SC_REALM}\.?$" <<< "$out" || { say "no LDAP SRV for samba-dc1.${SC_REALM}"; rc=1; }

    say "SYSVOL is populated with the two default GPOs"
    out=$(ssh_vm "sudo bash -c 'realm=\$(grep -oP \"(?<=realm = ).*\" /etc/samba/smb.conf | head -1 | tr A-Z a-z); ls /var/lib/samba/sysvol/\$realm/Policies/'" 2>&1 || true)
    echo "$out"
    # Default Domain Policy + Default Domain Controllers Policy:
    grep -q '{31B2F340-016D-11D2-945F-00C04FB984F9}' <<< "$out" || { say "default domain policy missing"; rc=1; }
    grep -qi '{6AC1786C-016F-11D2-945F-00C04fB984F9}' <<< "$out" || { say "default DC policy missing"; rc=1; }

    say "TLS cert was generated with SAN"
    ssh_vm 'sudo openssl x509 -noout -ext subjectAltName -in /var/lib/samba/private/tls/cert.pem 2>&1 | head -5' || rc=1

    say "no replication errors (expected — this is a single-DC forest)"
    out=$(ssh_vm 'sudo samba-tool drs showrepl 2>&1' || true)
    echo "$out" | head -20
    if grep -qE '[1-9][0-9]* consecutive failure' <<< "$out" \
       || grep -qiE 'was (a FAILURE|unsuccessful)' <<< "$out"; then
        say "showrepl reports failures on a fresh provision"; rc=1
    fi

    return $rc
}
