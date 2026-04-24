#!/usr/bin/env bash
#===============================================================================
# samba-sconfig — Samba AD DC Appliance Configuration Tool
#
# Whiptail TUI modeled after Windows Server Core's sconfig.
# Handles deployment configuration and management of a Samba AD DC
# on Debian 13 (Trixie).
#
# Usage: sudo samba-sconfig
#
# Maintainer map:
#   - TUI menu functions collect input and confirm destructive operations.
#   - Shared helpers do the real work and are also used by the headless CLI at
#     the bottom of this file.
#   - Keep deployment-specific decisions out of prepare-image.sh. If a value
#     depends on realm, source DC, client subnet, or role, set it here.
#   - Samba/Windows interop has several non-obvious requirements. Comments near
#     probe_forest_fl, register_own_ptr, seed_sysvol, and chrony explain the
#     failure modes those helpers prevent.
#===============================================================================
set -uo pipefail

readonly VERSION="1.1.0"
readonly SCRIPT_NAME="samba-sconfig"
readonly WT_HEIGHT=22
readonly WT_WIDTH=76
readonly WT_MENU_HEIGHT=14

#===============================================================================
# UTILITIES
#===============================================================================
die()  { whiptail --msgbox "FATAL: $*" 10 60; exit 1; }
info() { whiptail --msgbox "$*" 12 64; }
yesno(){ whiptail --yesno "$*" 10 60; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Run as root (sudo samba-sconfig)." >&2
        exit 1
    fi
}

get_hostname()  { hostname -s 2>/dev/null || echo "(not set)"; }
get_fqdn()      { hostname -f 2>/dev/null || echo "(not set)"; }
get_domain()    { dnsdomainname 2>/dev/null || echo "(not set)"; }
get_ip()        { ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+[.\d/]+' | head -1 || echo "(not set)"; }
get_gateway()   { ip route show default | awk '/default/{print $3}' | head -1 || echo "(not set)"; }
get_iface()     { ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1 || \
                  ip link show | awk -F: '/^[0-9]+:/{if($2!~"lo") print $2}' | tr -d ' ' | head -1; }

is_provisioned() { [[ -f /etc/samba/smb.conf ]] && grep -q 'server role.*active directory' /etc/samba/smb.conf 2>/dev/null; }
is_addc_running() { systemctl is-active samba-ad-dc &>/dev/null; }

# Resolve an FQDN to an IPv4 address using the CURRENT system resolver.
# If the argument is already an IPv4 literal, return it unchanged. Callers
# must use this BEFORE rewriting /etc/resolv.conf, otherwise the new
# nameserver (the target DC, which may not yet be reachable or ready) gets
# asked and the lookup silently fails. The FQDN string then lands in
# resolv.conf as-is, which kills DNS entirely and the join errors out at
# "Looking for DC".
resolve_dc_ip() {
    local host="$1"
    if [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        printf '%s' "$host"
        return 0
    fi
    local ip
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}')
    [[ -n "$ip" ]] || return 1
    printf '%s' "$ip"
}

# Query the target DC's rootDSE forestFunctionality attribute and return the
# matching Samba `ad dc functional level` string. rootDSE is queried
# anonymously: per LDAP/AD convention it remains readable even when the Windows
# security baseline requires LDAP signing for normal binds.
#
# This prevents a costly false lead. Samba's historical default is 2008_R2;
# Windows Server 2025 forests are typically FL 2016. If we let Samba advertise
# the old default, `samba-tool domain join` can fail with
# WERR_DS_INCOMPATIBLE_VERSION during NTDS Settings creation, which looks like
# a schema or permission problem until you inspect the Windows event log.
#
#   Input:  $1 = DC hostname or IP
#   Stdout: one of 2003, 2008, 2008_R2, 2012, 2012_R2, 2016
#   Return: 0 on success, 1 on query failure (stdout still prints 2008_R2)
probe_forest_fl() {
    local dc="$1"
    local fl_num
    fl_num=$(ldapsearch -x -LLL -H "ldap://${dc}" -s base -b "" forestFunctionality 2>/dev/null \
        | awk '/^forestFunctionality:/ { print $2 }')
    if [[ -z "$fl_num" ]]; then
        echo "2008_R2"
        return 1
    fi
    case "$fl_num" in
        2)  echo "2003"    ;;
        3)  echo "2008"    ;;
        4)  echo "2008_R2" ;;
        5)  echo "2012"    ;;
        6)  echo "2012_R2" ;;
        7)  echo "2016"    ;;
        *)  echo "2016"    ;;   # Samba 4.22 caps at 2016 — advertise max we support
    esac
}

get_realm() {
    is_provisioned && grep -oP '(?<=realm = ).*' /etc/samba/smb.conf 2>/dev/null | head -1 || echo "(not provisioned)"
}

get_netbios() {
    is_provisioned && grep -oP '(?<=workgroup = ).*' /etc/samba/smb.conf 2>/dev/null | head -1 || echo "(not provisioned)"
}

get_dc_role() {
    if ! is_provisioned; then echo "Not provisioned"; return; fi
    if is_addc_running; then echo "AD DC (Running)"; else echo "AD DC (Stopped)"; fi
}

get_update_policy() {
    if [[ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
        echo "Not configured"
        return
    fi
    local update_list unattended
    update_list=$(grep -oP '(?<=Update-Package-Lists ").*(?=")' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)
    unattended=$(grep -oP '(?<=Unattended-Upgrade ").*(?=")' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)
    if [[ "$unattended" == "1" && "$update_list" == "1" ]]; then
        if grep -q 'origin=Debian,codename=.*-security' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null && \
           ! grep -q '^\s*"origin=Debian,codename=\${distro_codename}' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
            echo "Security only"
        else
            echo "Full automatic"
        fi
    else
        echo "Manual"
    fi
}

#===============================================================================
# FIRST-LAUNCH WIZARD
#
# Run once per image, right when the admin first opens sconfig on a freshly
# prepared VM. Covers the tasks that are easy to forget and hard to recover
# from later: check connectivity, offer updates, prompt to pin the DHCP lease
# as a static IP before provisioning/joining a domain.
#===============================================================================
FIRST_BOOT_MARKER='/var/lib/samba-sconfig/first-boot-done'

first_boot_wizard() {
    [[ -f "$FIRST_BOOT_MARKER" ]] && return
    mkdir -p "$(dirname "$FIRST_BOOT_MARKER")"

    whiptail --title "Welcome to samba-sconfig" --msgbox \
        "This looks like a freshly-prepared appliance image.\n\nThe first-launch wizard will offer to:\n  1. Check your internet connection\n  2. Install available updates\n  3. Pin the current DHCP lease as a static IP\n\nYou can skip any step and come back via the normal menus." \
        14 64

    # 1. Connectivity probe
    if ping -c 1 -W 2 -q 1.1.1.1 &>/dev/null; then
        whiptail --title "Connectivity" --msgbox \
            "Internet reachable.\n\nGateway: $(get_gateway)\nDNS:     $(get_current_dns)" 10 60
    else
        whiptail --title "Connectivity" --msgbox \
            "Cannot reach 1.1.1.1.\n\nThis lab expects DHCP from the router. Check that the VM is on the Lab-NAT switch and the router VM is up. Skipping update offer." 12 64
        touch "$FIRST_BOOT_MARKER"
        return
    fi

    # 2. Updates
    if whiptail --title "System Updates" --yesno \
        "Check for and install available updates now?\n\nThis runs 'apt update' and 'apt upgrade -y'. Takes 1-3 min on a clean image." 12 64; then
        clear
        echo "[sconfig] apt update..."
        apt-get update
        echo "[sconfig] apt upgrade..."
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
        echo "[sconfig] done — press Enter to continue"
        read -r _
    fi

    # 3. Pin DHCP lease as static. The lab uses DHCP reservations to mimic a
    # real appliance landing on an existing LAN, but AD DCs still need stable
    # addressing. Writing a static config here gives production-like behavior
    # after first boot while keeping initial install simple.
    local addr_source
    addr_source=$(get_addr_source)
    if [[ "$addr_source" == "dhcp" ]]; then
        if whiptail --title "Network" --yesno \
            "Interface is on DHCP ($(get_ip | cut -d/ -f1)).\n\nAn AD DC needs a stable IP. Pin the current lease as static now?" 12 64; then
            local iface; iface=$(get_iface)
            local ip mask gw dns
            ip=$(get_ip | cut -d/ -f1); mask=$(get_ip | cut -d/ -f2)
            gw=$(get_gateway); dns=$(get_current_dns)
            cat > /etc/network/interfaces << NETEOF
# Managed by samba-sconfig (first-boot pin)
auto lo
iface lo inet loopback

auto ${iface}
iface ${iface} inet static
    address ${ip}/${mask}
    gateway ${gw}
NETEOF
            printf "nameserver %s\n" "$dns" > /etc/resolv.conf
            whiptail --title "Network" --msgbox \
                "Static pin written:\n  ${ip}/${mask}\n  gw=${gw}  dns=${dns}\n\nEffective on next boot (or systemctl restart networking)." 12 64
        fi
    fi

    touch "$FIRST_BOOT_MARKER"
}

#===============================================================================
# MAIN MENU
#===============================================================================
main_menu() {
    first_boot_wizard
    while true; do
        local hostname fqdn ip_addr dc_role realm_str
        hostname=$(get_hostname)
        fqdn=$(get_fqdn)
        ip_addr=$(get_ip)
        dc_role=$(get_dc_role)
        realm_str=$(get_realm)

        local choice
        choice=$(whiptail --title "Samba AD DC Configuration [$hostname] v${VERSION}" \
            --menu "\n  Host: $fqdn  |  IP: $ip_addr\n  Role: $dc_role  |  Realm: $realm_str\n" \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "System Configuration" \
            "2" "Domain Operations" \
            "3" "Post-Domain Setup" \
            "4" "SYSVOL Replication" \
            "5" "Security Hardening" \
            "6" "Diagnostics & Sanity Check" \
            "7" "Service Management" \
            "8" "Reboot / Shutdown" \
            "Q" "Exit" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) menu_system_config ;;
            2) menu_domain_ops ;;
            3) menu_post_domain ;;
            4) menu_sysvol_sync ;;
            5) menu_hardening ;;
            6) menu_diagnostics ;;
            7) menu_services ;;
            8) menu_power ;;
            Q|q) clear; exit 0 ;;
        esac
    done
}

#===============================================================================
# 1. SYSTEM CONFIGURATION
#===============================================================================
menu_system_config() {
    while true; do
        local update_policy
        update_policy=$(get_update_policy)
        local choice
        choice=$(whiptail --title "System Configuration" \
            --menu "Hostname: $(get_fqdn)\nIP: $(get_ip) | GW: $(get_gateway)\nUpdates: $update_policy" \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Set Hostname" \
            "2" "Configure Network (Static IP)" \
            "3" "Set Timezone" \
            "4" "Configure System Updates" \
            "5" "Run Updates Now" \
            "6" "Show System Info" \
            "B" "Back to Main Menu" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) config_hostname ;;
            2) config_network ;;
            3) config_timezone ;;
            4) config_updates ;;
            5) run_updates_now ;;
            6) show_system_info ;;
            B|b) return ;;
        esac
    done
}

config_hostname() {
    local current_fqdn
    current_fqdn=$(get_fqdn)

    local new_hostname
    new_hostname=$(whiptail --inputbox \
        "Enter the FQDN for this server.\n\nRules:\n- Short name max 15 characters (AD limit)\n- Use .lan or a subdomain you own\n- NEVER use .local (mDNS conflict)\n\nCurrent: $current_fqdn" \
        14 64 "$current_fqdn" \
        3>&1 1>&2 2>&3) || return

    [[ -z "$new_hostname" ]] && return

    if [[ "$new_hostname" != *.* ]]; then
        info "ERROR: Must be a FQDN (e.g., dc1.home.lan)."; return
    fi
    if [[ "$new_hostname" == *.local ]]; then
        info "ERROR: .local conflicts with mDNS/Bonjour."; return
    fi

    local short_name="${new_hostname%%.*}"
    if [[ ${#short_name} -gt 15 ]]; then
        info "ERROR: Short name '$short_name' exceeds 15 chars."; return
    fi

    local ip_addr
    ip_addr=$(get_ip | cut -d/ -f1)

    hostnamectl set-hostname "$new_hostname"
    echo "$new_hostname" > /etc/hostname

    # Clean /etc/hosts and add new entry
    sed -i "/\s${current_fqdn}\b/d" /etc/hosts 2>/dev/null || true
    echo "${ip_addr}  ${new_hostname}  ${short_name}" >> /etc/hosts

    info "Hostname set to: $new_hostname\nShort: $short_name\n\nReboot recommended."
}

get_addr_source() {
    # Report whether the default interface currently has a DHCP lease,
    # a static assignment, or nothing. Used by config_network to decide
    # what to offer the user.
    local iface="${1:-$(get_iface)}"
    [[ -z "$iface" ]] && { echo none; return; }
    if ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'dynamic'; then
        echo dhcp
    elif ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
        echo static
    else
        echo none
    fi
}

get_current_dns() {
    # First non-comment nameserver in /etc/resolv.conf
    awk '/^nameserver[[:space:]]/ { print $2; exit }' /etc/resolv.conf 2>/dev/null
}

config_network() {
    local iface
    iface=$(get_iface)
    [[ -z "$iface" ]] && { info "ERROR: No network interface detected."; return; }

    local current_ip current_mask current_gw current_dns addr_source
    current_ip=$(get_ip | cut -d/ -f1)
    current_mask=$(get_ip | cut -d/ -f2)
    current_gw=$(get_gateway)
    current_dns=$(get_current_dns)
    addr_source=$(get_addr_source "$iface")

    # If the host is currently on DHCP (typical first-boot state on lab-v2),
    # offer the one-shot "pin the current lease as static" path as the most
    # common path. An AD DC needs a stable IP; the lab's dnsmasq reservation
    # keeps the lease stable, but static is the real-world expectation.
    local mode
    if [[ "$addr_source" == "dhcp" ]]; then
        mode=$(whiptail --title "Network Configuration" \
            --menu "Interface $iface is currently on DHCP.\n\nCurrent lease:\n  IP:  $current_ip/$current_mask\n  GW:  $current_gw\n  DNS: $current_dns\n\nAn AD DC needs a stable IP. Choose one:" \
            $WT_HEIGHT $WT_WIDTH 6 \
            "1" "Pin current DHCP lease as static (recommended)" \
            "2" "Enter different static IP" \
            "3" "Keep DHCP (not recommended for a DC)" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return
    else
        mode='2'   # already static (or none) — go straight to manual entry
    fi

    local new_ip new_mask new_gw new_dns
    case "$mode" in
        1)
            new_ip="$current_ip"
            new_mask="${current_mask:-24}"
            new_gw="$current_gw"
            new_dns="${current_dns:-1.1.1.1}"
            yesno "Pin as static?\n\nInterface: $iface\nIP: $new_ip/$new_mask\nGateway: $new_gw\nDNS: $new_dns" || return
            ;;
        2)
            new_ip=$(whiptail --inputbox "Interface: $iface\n\nStatic IP address:" \
                10 60 "$current_ip" 3>&1 1>&2 2>&3) || return
            new_mask=$(whiptail --inputbox "Subnet prefix length (e.g., 24):" \
                10 60 "${current_mask:-24}" 3>&1 1>&2 2>&3) || return
            new_gw=$(whiptail --inputbox "Default gateway:" \
                10 60 "$current_gw" 3>&1 1>&2 2>&3) || return
            new_dns=$(whiptail --inputbox "Upstream DNS (used pre-domain; post-domain sconfig points at 127.0.0.1):" \
                10 64 "${current_dns:-1.1.1.1}" 3>&1 1>&2 2>&3) || return
            yesno "Apply static?\n\nInterface: $iface\nIP: $new_ip/$new_mask\nGateway: $new_gw\nDNS: $new_dns" || return
            ;;
        3)
            info "Keeping DHCP. Make sure router has a reservation for this host."
            return
            ;;
        *)  return ;;
    esac

    cat > /etc/network/interfaces << NETEOF
# Managed by samba-sconfig
auto lo
iface lo inet loopback

auto ${iface}
iface ${iface} inet static
    address ${new_ip}/${new_mask}
    gateway ${new_gw}
NETEOF

    cat > /etc/resolv.conf << DNSEOF
nameserver ${new_dns}
DNSEOF

    local fqdn short
    fqdn=$(get_fqdn); short=$(get_hostname)
    sed -i "/[[:space:]]${fqdn}\b/d" /etc/hosts 2>/dev/null || true
    echo "${new_ip}  ${fqdn}  ${short}" >> /etc/hosts

    info "Network written to /etc/network/interfaces.\nReboot (or 'systemctl restart networking') to apply."
}

config_timezone() { dpkg-reconfigure tzdata; }

config_updates() {
    local choice
    choice=$(whiptail --title "System Update Policy" \
        --menu "Current policy: $(get_update_policy)\n\nSelect how this server should handle system updates." \
        $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "1" "Manual — no automatic updates (I will run updates myself)" \
        "2" "Security Only — auto-install critical security patches" \
        "3" "Full Automatic — auto-install all stable updates" \
        "B" "Back" \
        3>&1 1>&2 2>&3) || return

    case "$choice" in
        1) set_update_policy_manual ;;
        2) set_update_policy_security ;;
        3) set_update_policy_full ;;
        B|b) return ;;
    esac
}

set_update_policy_manual() {
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "7";
EOF
    info "Update policy: MANUAL\n\nPackage lists refresh daily, but nothing installs automatically.\nRun updates manually from this menu or via apt."
}

set_update_policy_security() {
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # Configure unattended-upgrades for security only
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

Unattended-Upgrade::Package-Blacklist {
    // Prevent Samba from being upgraded unattended (could break AD)
    "samba";
    "samba-ad-dc";
    "winbind";
    "libnss-winbind";
    "libpam-winbind";
    "krb5-user";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Email notification (configure if needed)
//Unattended-Upgrade::Mail "root";
//Unattended-Upgrade::MailReport "on-change";

// Auto-reboot if needed (disabled by default for a DC)
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    systemctl enable unattended-upgrades 2>/dev/null || true

    info "Update policy: SECURITY ONLY\n\nOnly Debian security patches auto-install.\nSamba/Kerberos/Winbind packages are blacklisted from auto-update\n(upgrade those manually to avoid breaking AD).\n\nAuto-reboot is DISABLED."
}

set_update_policy_full() {
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "origin=Debian,codename=${distro_codename},label=Debian";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-updates,label=Debian";
};

Unattended-Upgrade::Package-Blacklist {
    "samba";
    "samba-ad-dc";
    "winbind";
    "libnss-winbind";
    "libpam-winbind";
    "krb5-user";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    systemctl enable unattended-upgrades 2>/dev/null || true

    info "Update policy: FULL AUTOMATIC\n\nAll Debian stable + security updates auto-install.\nSamba/Kerberos/Winbind are still blacklisted.\nAuto-reboot is DISABLED."
}

run_updates_now() {
    if yesno "Run apt update && apt upgrade now?\n\nThis will update package lists and install available upgrades interactively."; then
        clear
        echo "=== Running system updates ==="
        echo ""
        apt-get update
        echo ""
        apt-get upgrade
        echo ""
        echo "Press Enter to return to samba-sconfig..."
        read -r
    fi
}

show_system_info() {
    local info_text
    info_text=$(cat << EOF
Hostname (FQDN): $(get_fqdn)
Hostname (short): $(get_hostname)
IP Address:       $(get_ip)
Gateway:          $(get_gateway)
Interface:        $(get_iface)
DNS Domain:       $(get_domain)

Kernel:           $(uname -r)
Debian:           $(cat /etc/debian_version 2>/dev/null)
Virtualization:   $(systemd-detect-virt 2>/dev/null || echo "unknown")
Uptime:           $(uptime -p 2>/dev/null)

Samba:            $(samba --version 2>/dev/null || echo "not installed")
PowerShell:       $(pwsh --version 2>/dev/null || echo "not installed")
DC Role:          $(get_dc_role)
Realm:            $(get_realm)
NetBIOS:          $(get_netbios)
Update Policy:    $(get_update_policy)
EOF
)
    whiptail --title "System Information" --scrolltext --msgbox "$info_text" 24 70
}

#===============================================================================
# 2. DOMAIN OPERATIONS
#===============================================================================
menu_domain_ops() {
    if is_provisioned; then
        info "Already provisioned.\n\nRealm: $(get_realm)\nNetBIOS: $(get_netbios)\n\nTo re-provision, remove /etc/samba/smb.conf and\n/var/lib/samba/private/ contents first."
        return
    fi

    local choice
    choice=$(whiptail --title "Domain Operations" \
        --menu "Select DC role. WARNING: These operations are destructive." \
        $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "1" "Create New Forest & Domain" \
        "2" "Join as Additional DC (Backup)" \
        "3" "Join as Read-Only DC (RODC)" \
        "B" "Back" \
        3>&1 1>&2 2>&3) || return

    case "$choice" in
        1) domain_provision_new ;;
        2) domain_join_dc ;;
        3) domain_join_rodc ;;
        B|b) return ;;
    esac
}

collect_domain_info() {
    DC_REALM=$(whiptail --inputbox \
        "AD Realm (UPPERCASE DNS domain name).\n\nExamples: HOME.LAN, CORP.CONTOSO.COM\nDo NOT use .local" \
        12 64 "" 3>&1 1>&2 2>&3) || return 1
    [[ -z "$DC_REALM" ]] && return 1
    DC_REALM="${DC_REALM^^}"
    [[ "$DC_REALM" == *.LOCAL ]] && { info ".LOCAL conflicts with mDNS."; return 1; }

    local default_netbios="${DC_REALM%%.*}"
    DC_NETBIOS=$(whiptail --inputbox "NetBIOS (short) domain name. Max 15 chars, no dots." \
        10 64 "$default_netbios" 3>&1 1>&2 2>&3) || return 1
    DC_NETBIOS="${DC_NETBIOS^^}"

    DC_DNS_FORWARDER=$(whiptail --inputbox "DNS forwarder (upstream DNS for external names):" \
        10 64 "1.1.1.1" 3>&1 1>&2 2>&3) || return 1

    return 0
}

# Provisioning a new forest — prompt for the password to CREATE for the
# built-in Administrator. Username is fixed (Administrator) because this is
# the well-known account Samba creates during `domain provision`.
collect_new_admin_password() {
    DC_ADMIN_USER="Administrator"
    DC_ADMIN_PASS=$(whiptail --passwordbox \
        "Choose a password for the new forest's built-in Administrator account.\n\nMinimum 8 characters; Samba's default policy requires mixed case, digits, and a symbol." \
        14 68 3>&1 1>&2 2>&3) || return 1
    [[ ${#DC_ADMIN_PASS} -lt 8 ]] && { info "Password too short (min 8 chars)."; return 1; }

    local pass_confirm
    pass_confirm=$(whiptail --passwordbox "Confirm password:" 10 64 3>&1 1>&2 2>&3) || return 1
    [[ "$DC_ADMIN_PASS" != "$pass_confirm" ]] && { info "Passwords don't match."; return 1; }

    return 0
}

# Joining an existing domain — prompt for the EXISTING credentials of a
# domain account with rights to add a DC. Defaults to Administrator but any
# account in Domain Admins (or with delegated join rights) works.
collect_join_credentials() {
    DC_ADMIN_USER=$(whiptail --inputbox \
        "Username of a domain administrator with permission to join a new DC to ${DC_NETBIOS}.\n\nDefaults to Administrator. Any account in Domain Admins (or with delegated join rights) will work." \
        13 68 "Administrator" 3>&1 1>&2 2>&3) || return 1
    [[ -z "$DC_ADMIN_USER" ]] && { info "Admin username required."; return 1; }

    DC_ADMIN_PASS=$(whiptail --passwordbox \
        "Enter the current password for ${DC_NETBIOS}\\\\${DC_ADMIN_USER} (these are the existing credentials used to authenticate the join — not a new password):" \
        12 68 3>&1 1>&2 2>&3) || return 1
    [[ -z "$DC_ADMIN_PASS" ]] && { info "Password required."; return 1; }

    return 0
}

write_krb5_conf() {
    cat > /etc/krb5.conf << KRBEOF
[libdefaults]
  default_realm = ${1}
  dns_lookup_kdc = true
  dns_lookup_realm = false
KRBEOF
}

apply_hardening_to_smb_conf() {
    local smb="/etc/samba/smb.conf"
    [[ -f "$smb" ]] || return
    grep -q '# --- sconfig hardening ---' "$smb" 2>/dev/null && return

    # Insert hardening INTO the [global] section. Appending to EOF lands
    # after [sysvol]/[netlogon], which makes testparm complain "Global
    # parameter X found in service section!" and in some cases the value
    # is actually ignored. Samba's post-provision smb.conf uses tab-indent,
    # so match that.
    local tmp
    tmp=$(mktemp)
    awk '
        BEGIN { inserted = 0 }
        /^\[global\][[:space:]]*$/ && !inserted {
            print
            print "\t# --- sconfig hardening ---"
            print "\tserver signing = mandatory"
            print "\tclient signing = mandatory"
            print "\tserver min protocol = SMB3_00"
            print "\tclient min protocol = SMB3_00"
            print "\tldap server require strong auth = yes"
            print "\tkerberos encryption types = strong"
            print "\tntlm auth = mschapv2-and-ntlmv2-only"
            print "\ttls enabled = yes"
            print "\ttls priority = NORMAL:-VERS-ALL:+VERS-TLS1.2:+VERS-TLS1.3"
            print "\tlog level = 1 auth_audit:3 auth_json_audit:3"
            print "\tallow dns updates = secure only"
            inserted = 1
            next
        }
        { print }
    ' "$smb" > "$tmp"

    if [[ $(wc -l < "$tmp") -gt $(wc -l < "$smb") ]]; then
        mv "$tmp" "$smb"
    else
        # Fallback: no [global] line found — leave original alone and warn
        rm -f "$tmp"
        echo "[sconfig] WARN: [global] section not found in $smb — hardening NOT applied" >&2
        return 1
    fi
}

# `samba-tool ntacl sysvolreset` can loop forever emitting
# "idmap range not specified for domain '*'" when smb.conf has no idmap
# block for the catch-all domain. Samba's post-provision / post-join
# template doesn't include one; inject a sensible default so sysvolreset
# (and any other tool that needs SID→POSIX translation for foreign SIDs)
# can progress. No-op on subsequent calls.
ensure_idmap_config() {
    local smb="/etc/samba/smb.conf"
    [[ -f "$smb" ]] || return 0
    grep -qE '^[[:space:]]*idmap config \* : backend' "$smb" 2>/dev/null && return 0

    local tmp
    tmp=$(mktemp)
    awk '
        BEGIN { inserted = 0 }
        /^\[global\][[:space:]]*$/ && !inserted {
            print
            print "\tidmap config * : backend = tdb"
            print "\tidmap config * : range = 3000000-4000000"
            inserted = 1
            next
        }
        { print }
    ' "$smb" > "$tmp"

    if [[ $(wc -l < "$tmp") -gt $(wc -l < "$smb") ]]; then
        mv "$tmp" "$smb"
    else
        rm -f "$tmp"
        echo "[sconfig] WARN: [global] not found in $smb — idmap config NOT added" >&2
        return 1
    fi
}

post_provision_setup() {
    local realm="$1" dns_fwd="$2"
    local realm_lower="${realm,,}"

    # Samba tools look in private/krb5.conf, while admins expect the system
    # Kerberos config in /etc. Use one source of truth so the TUI, CLI, kinit,
    # and Samba agree after both provision and join.
    rm -f /var/lib/samba/private/krb5.conf
    ln -s /etc/krb5.conf /var/lib/samba/private/krb5.conf

    if ! grep -q "dns forwarder" /etc/samba/smb.conf 2>/dev/null; then
        sed -i "/\[global\]/a\\        dns forwarder = ${dns_fwd}" /etc/samba/smb.conf
    fi

    ensure_idmap_config

    cat > /etc/resolv.conf << DNSEOF
search ${realm_lower}
nameserver 127.0.0.1
DNSEOF

    systemctl unmask samba-ad-dc
    systemctl enable samba-ad-dc
    systemctl start samba-ad-dc
    sleep 3
}

# Seed /var/lib/samba/sysvol/ from the source DC immediately after joining.
# Samba doesn't implement DFSR, so without a bootstrap copy the GPO files
# under Policies/ are empty until sysvol-sync runs on a schedule. We use
# smbclient (not rsync-over-SSH) because Windows DCs rarely have sshd.
#
#   Input:  $1 source DC (FQDN), $2 netbios domain, $3 admin username,
#           $4 admin password, $5 realm (lowercased used for the SYSVOL
#           subtree name)
seed_sysvol() {
    local src_dc="$1" netbios="$2" admin_user="$3" admin_pass="$4" realm="$5"
    local realm_lower="${realm,,}"
    local tmpdir
    tmpdir=$(mktemp -d)

    echo "[sconfig] seeding SYSVOL from //${src_dc}/sysvol/${realm_lower} ..."
    if smbclient "//${src_dc}/sysvol" \
            -U "${netbios}\\${admin_user}%${admin_pass}" \
            -c "recurse ON; prompt OFF; lcd ${tmpdir}; mget ${realm_lower}" \
            >/dev/null 2>&1; then
        if [[ -d "${tmpdir}/${realm_lower}" ]]; then
            cp -a "${tmpdir}/${realm_lower}/." "/var/lib/samba/sysvol/${realm_lower}/"
            echo "[sconfig] SYSVOL seeded. Resetting NTACLs..."
            samba-tool ntacl sysvolreset 2>&1 | sed 's/^/[ntacl] /' || true
            rm -rf "$tmpdir"
            return 0
        fi
    fi
    echo "[sconfig] WARN: SYSVOL seed failed (smbclient or copy). Policies/ will be empty"
    echo "[sconfig]       until sysvol-sync runs. Verify SMB signing + creds on $src_dc."
    rm -rf "$tmpdir"
    return 1
}

# Re-point chrony at a domain time source. Called post-join / post-provision.
# The image skeleton has no NTP servers baked in. That avoids public-pool
# assumptions and lets this function use the correct source: the existing DC
# when joining, or a chosen upstream/client subnet when this host is the first
# DC in a new deployment.
configure_chrony_for_domain() {
    local ntp_source="$1" subnet="${2:-}"
    local conf="/etc/chrony/chrony.conf"

    # Strip any prior sconfig-managed block
    sed -i '/# --- sconfig-managed chrony ---/,/# --- end sconfig ---/d' "$conf" 2>/dev/null

    cat >> "$conf" <<CHRONYEOF
# --- sconfig-managed chrony ---
server ${ntp_source} iburst
$( [[ -n "$subnet" ]] && echo "allow ${subnet}" )
# --- end sconfig ---
CHRONYEOF
    systemctl restart chrony 2>/dev/null || true
    echo "[sconfig] chrony repointed at ${ntp_source}${subnet:+ (serving $subnet)}"
}

# Register this host's PTR in the target forest's reverse zone so Windows DC
# KCC replication works. The forward records created by Samba are not enough
# in the WS2025 lab: Windows can resolve the source DC GUID CNAME and A record
# but still cache replication error 8524 when the source IP has no PTR.
#
#   Input:  $1 target DC (FQDN or IP, usually the source DC we joined from)
#           $2 NetBIOS domain (for `${NETBIOS}\${admin_user}`)
#           $3 admin username (e.g. Administrator)
#           $4 admin password
#           $5 realm (DNS domain) — used to compose this host's FQDN
#   Return: 0 on success, 1 on any failure (including zone not present).
register_own_ptr() {
    local target_dc="$1" netbios="$2" admin_user="$3" admin_pass="$4" realm="$5"
    local my_ip my_fqdn reverse_zone reverse_name a b c d

    my_ip=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    [[ -z "$my_ip" ]] && { echo "[sconfig] WARN: no IPv4 address — skipping PTR registration"; return 1; }
    IFS='.' read -r a b c d <<< "$my_ip"
    reverse_zone="${c}.${b}.${a}.in-addr.arpa"
    reverse_name="$d"
    my_fqdn="$(hostname -s).${realm,,}"

    echo "[sconfig] registering PTR  ${reverse_name}.${reverse_zone}  →  ${my_fqdn}."
    local out ptr_ok=false
    if out=$(samba-tool dns add "$target_dc" "$reverse_zone" "$reverse_name" PTR "${my_fqdn}." \
                -U"${netbios}\\${admin_user}" --password="$admin_pass" 2>&1); then
        echo "[sconfig] PTR registered on $target_dc"
        ptr_ok=true
    elif grep -qiE "already exist|DNS_ERROR_RECORD_ALREADY_EXISTS" <<< "$out"; then
        echo "[sconfig] PTR already present on $target_dc"
        ptr_ok=true
    fi

    if $ptr_ok; then
        # Force KCC on the source DC to re-evaluate the replica link now that
        # PTR exists. Without this, the stale 8524 from the brief window
        # between `samba-tool domain join` completing and the PTR being
        # registered lingers in /showrepl /errorsonly for ~15 min until KCC's
        # next scheduled run.
        echo "[sconfig] forcing KCC on $target_dc to clear stale 8524..."
        samba-tool drs kcc "$target_dc" \
            -U"${netbios}\\${admin_user}" --password="$admin_pass" 2>&1 \
            | sed 's/^/[kcc] /' || true
        return 0
    fi
    # zone missing is the common cause on unconfigured labs — explain clearly
    if grep -qiE "DNS_ERROR_ZONE_DOES_NOT_EXIST|WERR_DNS_ERROR_ZONE_DOES_NOT_EXIST" <<< "$out"; then
        echo "[sconfig] WARN: reverse zone $reverse_zone does not exist on $target_dc"
        echo "[sconfig]       Windows replication FROM this DC will fail (error 8524) until"
        echo "[sconfig]       the forest admin creates the zone. Continuing anyway."
        return 1
    fi
    echo "[sconfig] WARN: PTR registration failed:"
    echo "$out" | sed 's/^/[ptr] /'
    return 1
}

domain_provision_new() {
    local DC_REALM DC_NETBIOS DC_ADMIN_USER DC_ADMIN_PASS DC_DNS_FORWARDER
    collect_domain_info || return
    collect_new_admin_password || return

    yesno "Provision NEW forest?\n\nRealm: $DC_REALM\nNetBIOS: $DC_NETBIOS\nDNS: SAMBA_INTERNAL\nForwarder: $DC_DNS_FORWARDER" || return

    rm -f /etc/samba/smb.conf
    systemctl stop samba-ad-dc 2>/dev/null || true
    write_krb5_conf "$DC_REALM"

    {
        echo "10"; echo "XXX"; echo "Provisioning AD domain..."; echo "XXX"
        samba-tool domain provision \
            --realm="$DC_REALM" --domain="$DC_NETBIOS" \
            --server-role=dc --dns-backend=SAMBA_INTERNAL \
            --adminpass="$DC_ADMIN_PASS" \
            --option="dns forwarder = $DC_DNS_FORWARDER" 2>&1 | tail -5
        echo "50"; echo "XXX"; echo "Applying hardening..."; echo "XXX"
        apply_hardening_to_smb_conf
        echo "70"; echo "XXX"; echo "Starting services..."; echo "XXX"
        post_provision_setup "$DC_REALM" "$DC_DNS_FORWARDER"
        echo "100"; echo "XXX"; echo "Done!"; echo "XXX"
    } | whiptail --title "Provisioning" --gauge "Starting..." 8 60 0

    if is_addc_running; then
        info "Domain provisioned!\n\nRealm: $DC_REALM | NetBIOS: $DC_NETBIOS\n\nNext: Run Diagnostics (6), Post-Domain Setup (3), Hardening (5)"
    else
        info "WARNING: samba-ad-dc not running.\n\nCheck: journalctl -u samba-ad-dc -n 50"
    fi
}

domain_join_dc() {
    local DC_REALM DC_NETBIOS DC_ADMIN_USER DC_ADMIN_PASS DC_DNS_FORWARDER
    collect_domain_info || return

    local existing_dc
    existing_dc=$(whiptail --inputbox "FQDN or IP of existing DC to replicate from:" \
        10 64 "" 3>&1 1>&2 2>&3) || return

    local dc_ip
    if ! dc_ip=$(resolve_dc_ip "$existing_dc"); then
        info "Cannot resolve '$existing_dc' via the current resolver.\nProvide an IP or fix /etc/resolv.conf first."
        return
    fi

    collect_join_credentials || return

    yesno "Join as ADDITIONAL DC?\n\nRealm: $DC_REALM\nSource DC: $existing_dc ($dc_ip)\nAs: ${DC_NETBIOS}\\\\${DC_ADMIN_USER}" || return

    # Auto-detect target forest functional level. Samba's default
    # `ad dc functional level = 2008_R2` silently fails against any
    # 2012+ forest with WERR_DS_INCOMPATIBLE_VERSION.
    local fl_str
    fl_str=$(probe_forest_fl "$dc_ip")

    rm -f /etc/samba/smb.conf
    systemctl stop samba-ad-dc 2>/dev/null || true
    write_krb5_conf "$DC_REALM"
    echo -e "search ${DC_REALM,,}\nnameserver ${dc_ip}" > /etc/resolv.conf

    whiptail --infobox "Joining domain at FL=$fl_str... This may take several minutes." 8 60

    if samba-tool domain join "$DC_REALM" DC \
        --dns-backend=SAMBA_INTERNAL \
        --option="dns forwarder = $DC_DNS_FORWARDER" \
        --option="ad dc functional level = $fl_str" \
        -U"${DC_NETBIOS}\\${DC_ADMIN_USER}" \
        --password="$DC_ADMIN_PASS" 2>&1 | tail -20; then
        apply_hardening_to_smb_conf
        post_provision_setup "$DC_REALM" "$DC_DNS_FORWARDER"
        register_own_ptr "$dc_ip" "$DC_NETBIOS" "$DC_ADMIN_USER" "$DC_ADMIN_PASS" "$DC_REALM" || true
        seed_sysvol "$dc_ip" "$DC_NETBIOS" "$DC_ADMIN_USER" "$DC_ADMIN_PASS" "$DC_REALM" || true
        configure_chrony_for_domain "$dc_ip"
        _generate_tls_cert_core
        info "Joined as additional DC (FL=$fl_str)!\nRealm: $DC_REALM"
    else
        info "Join FAILED.\n\nCheck connectivity to $existing_dc ($dc_ip) and credentials."
    fi
}

domain_join_rodc() {
    local DC_REALM DC_NETBIOS DC_ADMIN_USER DC_ADMIN_PASS DC_DNS_FORWARDER
    collect_domain_info || return

    local existing_dc
    existing_dc=$(whiptail --inputbox "FQDN or IP of writable DC:" \
        10 64 "" 3>&1 1>&2 2>&3) || return

    local dc_ip
    if ! dc_ip=$(resolve_dc_ip "$existing_dc"); then
        info "Cannot resolve '$existing_dc' via the current resolver.\nProvide an IP or fix /etc/resolv.conf first."
        return
    fi

    collect_join_credentials || return

    yesno "Join as RODC?\n\nRealm: $DC_REALM\nSource DC: $existing_dc ($dc_ip)\nAs: ${DC_NETBIOS}\\\\${DC_ADMIN_USER}" || return

    local fl_str
    fl_str=$(probe_forest_fl "$dc_ip")

    rm -f /etc/samba/smb.conf
    systemctl stop samba-ad-dc 2>/dev/null || true
    write_krb5_conf "$DC_REALM"
    echo -e "search ${DC_REALM,,}\nnameserver ${dc_ip}" > /etc/resolv.conf

    whiptail --infobox "Joining as RODC at FL=$fl_str..." 8 60

    if samba-tool domain join "$DC_REALM" RODC \
        --dns-backend=SAMBA_INTERNAL \
        --option="dns forwarder = $DC_DNS_FORWARDER" \
        --option="ad dc functional level = $fl_str" \
        -U"${DC_NETBIOS}\\${DC_ADMIN_USER}" \
        --password="$DC_ADMIN_PASS" 2>&1 | tail -20; then
        apply_hardening_to_smb_conf
        post_provision_setup "$DC_REALM" "$DC_DNS_FORWARDER"
        register_own_ptr "$dc_ip" "$DC_NETBIOS" "$DC_ADMIN_USER" "$DC_ADMIN_PASS" "$DC_REALM" || true
        seed_sysvol "$dc_ip" "$DC_NETBIOS" "$DC_ADMIN_USER" "$DC_ADMIN_PASS" "$DC_REALM" || true
        configure_chrony_for_domain "$dc_ip"
        _generate_tls_cert_core
        info "Joined as RODC (FL=$fl_str)!\nRealm: $DC_REALM"
    else
        info "RODC join FAILED."
    fi
}

#===============================================================================
# 3. POST-DOMAIN SETUP
#===============================================================================
menu_post_domain() {
    is_provisioned || { info "Not provisioned yet. Use Domain Operations (2) first."; return; }

    while true; do
        local choice
        choice=$(whiptail --title "Post-Domain Setup" \
            --menu "Configure services after domain provisioning." \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Enable Domain Logins (winbind + NSS + PAM)" \
            "2" "Grant sudo to Domain Admins" \
            "3" "Configure NTP (Chrony) for AD" \
            "4" "Reset Administrator Password" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) setup_domain_logins ;;
            2) setup_domain_sudo ;;
            3) setup_chrony ;;
            4) reset_admin_password ;;
            B|b) return ;;
        esac
    done
}

setup_domain_logins() {
    yesno "Enable AD domain account logins via SSH?\n\nThis adds winbind to NSS, configures PAM mkhomedir,\nand sets default shell to /bin/bash." || return

    local nss="/etc/nsswitch.conf"
    cp "$nss" "${nss}.bak-$(date +%s)"

    if ! grep -q 'winbind' "$nss"; then
        sed -i 's/^passwd:\s*.*/passwd:         files winbind/' "$nss"
        sed -i 's/^group:\s*.*/group:          files winbind/' "$nss"
    fi

    pam-auth-update --enable mkhomedir 2>/dev/null || {
        grep -q 'pam_mkhomedir' /etc/pam.d/common-session 2>/dev/null || \
            echo "session required pam_mkhomedir.so skel=/etc/skel umask=0022" >> /etc/pam.d/common-session
    }

    local smb="/etc/samba/smb.conf"
    if ! grep -q 'template homedir' "$smb" 2>/dev/null; then
        sed -i '/\[global\]/a\\n        template homedir = /home/%U\n        template shell = /bin/bash' "$smb"
    fi

    systemctl restart samba-ad-dc
    sleep 2

    local test_output
    test_output=$(wbinfo -u 2>&1 | head -5)
    info "Domain logins configured.\n\nwbinfo -u:\n${test_output}\n\nSSH: ssh DOMAIN\\\\user@server"
}

setup_domain_sudo() {
    local netbios
    netbios=$(get_netbios)
    [[ "$netbios" == "(not provisioned)" ]] && { info "Not provisioned."; return; }

    local sudo_group
    sudo_group=$(whiptail --inputbox "Domain group to grant sudo:" \
        10 64 "Domain Admins" 3>&1 1>&2 2>&3) || return

    local sudoers_file="/etc/sudoers.d/domain-admins"
    cat > "$sudoers_file" << SUDOEOF
%${netbios}\\\\${sudo_group}  ALL=(ALL:ALL) ALL
SUDOEOF
    chmod 440 "$sudoers_file"

    if visudo -cf "$sudoers_file" &>/dev/null; then
        info "Sudo granted to '${netbios}\\${sudo_group}'."
    else
        rm -f "$sudoers_file"
        info "ERROR: Syntax validation failed. Entry removed."
    fi
}

setup_chrony() {
    local subnet
    subnet=$(whiptail --inputbox "Network subnet for NTP clients (e.g., 192.168.1.0/24):" \
        10 64 "192.168.1.0/24" 3>&1 1>&2 2>&3) || return

    cat > /etc/chrony/chrony.conf << CHRONEOF
server time.cloudflare.com iburst
server time.google.com iburst
pool 2.debian.pool.ntp.org iburst
driftfile /var/lib/chrony/drift
allow ${subnet}
ntpsigndsocket /var/lib/samba/ntp_signd
makestep 1.0 3
CHRONEOF

    mkdir -p /var/lib/samba/ntp_signd
    chown root:_chrony /var/lib/samba/ntp_signd 2>/dev/null || \
    chown root:chrony /var/lib/samba/ntp_signd 2>/dev/null || true
    chmod 750 /var/lib/samba/ntp_signd

    systemctl enable chrony
    systemctl restart chrony
    info "Chrony configured.\nClients allowed from: $subnet\nNTP signing enabled."
}

reset_admin_password() {
    local new_pass confirm_pass
    new_pass=$(whiptail --passwordbox "New Administrator password:" 10 64 3>&1 1>&2 2>&3) || return
    confirm_pass=$(whiptail --passwordbox "Confirm:" 10 64 3>&1 1>&2 2>&3) || return
    [[ "$new_pass" != "$confirm_pass" ]] && { info "Passwords don't match."; return; }

    if samba-tool user setpassword administrator --newpassword="$new_pass" 2>&1; then
        info "Password updated."
    else
        info "ERROR: Check complexity requirements."
    fi
}

#===============================================================================
# 4. SYSVOL REPLICATION
#===============================================================================
SYSVOL_SYNC_KEY="/root/.ssh/sysvol-sync"
SYSVOL_SYNC_CRED="/etc/samba/sysvol-sync.cred"

menu_sysvol_sync() {
    is_provisioned || { info "Not provisioned."; return; }

    while true; do
        local choice
        choice=$(whiptail --title "SYSVOL Replication" \
            --menu "Samba has no DFSR — this menu sets up an out-of-band replacement.\n  ssh: rsync-over-SSH (Samba ↔ Samba; remote DC must run sshd)\n  smb: smbclient pull from //REMOTE/sysvol (works against Windows DCs)" \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Configure SYSVOL Sync" \
            "2" "Generate SSH Key Pair (ssh transport)" \
            "3" "Dry Run (test sync)" \
            "4" "Run Sync Now" \
            "5" "Reset SYSVOL ACLs" \
            "6" "Show Sync Status" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) configure_sysvol_sync ;;
            2) generate_sync_sshkey ;;
            3) test_sysvol_sync ;;
            4) run_sysvol_sync ;;
            5) reset_sysvol_acls ;;
            6) show_sync_status ;;
            B|b) return ;;
        esac
    done
}

configure_sysvol_sync() {
    local transport
    transport=$(whiptail --title "Sync Transport" \
        --menu "Choose how to replicate SYSVOL from the remote DC.\n\n  ssh: rsync-over-SSH (Samba ↔ Samba only; remote DC must run sshd)\n  smb: smbclient pull from //REMOTE/sysvol (pull-only; works against Windows DCs)" \
        15 72 2 \
        "ssh" "rsync over SSH (requires sshd on remote)" \
        "smb" "smbclient pull (works against Windows DCs; pull-only)" \
        3>&1 1>&2 2>&3) || return

    local remote_dc interval
    remote_dc=$(whiptail --inputbox "FQDN or IP of the remote DC:" 10 64 "" 3>&1 1>&2 2>&3) || return
    [[ -z "$remote_dc" ]] && { info "Remote DC is required."; return; }

    interval=$(whiptail --inputbox "Sync interval (minutes, 1-59):" 10 64 "5" 3>&1 1>&2 2>&3) || return
    [[ "$interval" =~ ^[0-9]+$ ]] || { info "Interval must be a positive integer."; return; }
    (( interval >= 1 && interval <= 59 )) || { info "Interval must be between 1 and 59 minutes."; return; }

    case "$transport" in
        ssh)
            local sync_role remote_user
            sync_role=$(whiptail --title "Sync Role" \
                --menu "Is this DC the PRIMARY (push) or REPLICA (pull)?" 12 60 2 \
                "pull" "REPLICA — pull from primary" \
                "push" "PRIMARY — push to replica" \
                3>&1 1>&2 2>&3) || return

            remote_user=$(whiptail --inputbox \
                "SSH login user on remote DC (needs access to /var/lib/samba/sysvol/):" \
                11 68 "root" 3>&1 1>&2 2>&3) || return
            [[ -z "$remote_user" ]] && { info "Remote user is required."; return; }

            # Generate SSH key BEFORE the cron entry is installed, so the
            # first scheduled run can't fire while the key file is still
            # missing (the v1 flow left a window where cron.d/sysvol-sync
            # would log a keyfile error every few minutes until the user
            # hit menu item 2).
            if [[ ! -f "$SYSVOL_SYNC_KEY" ]]; then
                mkdir -p /root/.ssh; chmod 700 /root/.ssh
                ssh-keygen -t ed25519 -f "$SYSVOL_SYNC_KEY" -N "" \
                    -C "sysvol-sync@$(hostname -s)" >/dev/null
            fi

            umask 077
            cat > /etc/samba/sysvol-sync.conf <<SCEOF
SYNC_TRANSPORT="ssh"
SYNC_ROLE="${sync_role}"
REMOTE_DC="${remote_dc}"
REMOTE_USER="${remote_user}"
SSH_KEY="${SYSVOL_SYNC_KEY}"
SCEOF
            chmod 640 /etc/samba/sysvol-sync.conf
            umask 022

            whiptail --title "SSH public key" --scrolltext --msgbox \
                "Add this key to ${remote_user}@${remote_dc}'s authorized_keys before the cron timer next fires:\n\n$(cat "${SYSVOL_SYNC_KEY}.pub")" \
                16 76
            ;;

        smb)
            local admin_netbios admin_user admin_pass
            admin_netbios=$(whiptail --inputbox \
                "NetBIOS domain for smbclient authentication:" \
                10 64 "$(get_netbios)" 3>&1 1>&2 2>&3) || return
            [[ -z "$admin_netbios" ]] && { info "NetBIOS domain is required."; return; }

            admin_user=$(whiptail --inputbox \
                "Account used to read //${remote_dc}/sysvol (Administrator or any account with read access):" \
                12 68 "Administrator" 3>&1 1>&2 2>&3) || return
            [[ -z "$admin_user" ]] && { info "Admin user is required."; return; }

            admin_pass=$(whiptail --passwordbox \
                "Password for ${admin_netbios}\\\\${admin_user} (existing account — NOT being created):" \
                10 68 3>&1 1>&2 2>&3) || return
            [[ -z "$admin_pass" ]] && { info "Password is required."; return; }

            # smbclient -A reads username=/password=/domain= lines. Keep the
            # file root-only — it contains a domain admin password.
            umask 077
            cat > "$SYSVOL_SYNC_CRED" <<CRED
username = ${admin_user}
password = ${admin_pass}
domain = ${admin_netbios}
CRED
            chmod 600 "$SYSVOL_SYNC_CRED"
            chown root:root "$SYSVOL_SYNC_CRED"

            cat > /etc/samba/sysvol-sync.conf <<SCEOF
SYNC_TRANSPORT="smb"
SYNC_ROLE="pull"
REMOTE_DC="${remote_dc}"
SMB_CRED_FILE="${SYSVOL_SYNC_CRED}"
SCEOF
            chmod 640 /etc/samba/sysvol-sync.conf
            umask 022
            ;;
    esac

    # Install the cron job LAST — only now that the key file / credentials
    # file actually exist. PATH is set explicitly because cron's default
    # leaves out /usr/local/sbin and some Samba installs put samba-tool there.
    cat > /etc/cron.d/sysvol-sync <<CRON
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${interval} * * * * root /usr/local/sbin/sysvol-sync
CRON
    chmod 644 /etc/cron.d/sysvol-sync

    info "Configured.\nTransport: ${transport} | Remote: ${remote_dc} | Every ${interval} min\n\nNext: run Dry Run (menu 3) to verify, then Run Sync Now (menu 4)."
}

generate_sync_sshkey() {
    [[ -f "$SYSVOL_SYNC_KEY" ]] && ! yesno "Key exists. Overwrite?" && return

    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    ssh-keygen -t ed25519 -f "$SYSVOL_SYNC_KEY" -N "" -C "sysvol-sync@$(hostname -s)"

    whiptail --title "Public Key" --scrolltext --msgbox \
        "Copy to remote DC's authorized_keys:\n\n$(cat "${SYSVOL_SYNC_KEY}.pub")" 14 76
}

test_sysvol_sync() {
    [[ -f /etc/samba/sysvol-sync.conf ]] || { info "Not configured."; return; }
    # shellcheck disable=SC1091
    source /etc/samba/sysvol-sync.conf
    whiptail --infobox "Dry run..." 6 40
    local output
    case "${SYNC_TRANSPORT:-ssh}" in
        ssh)
            [[ -f "${SSH_KEY:-}" ]] || { info "SSH key '${SSH_KEY:-}' missing. Generate it (menu 2) or re-run configure."; return; }
            case "${SYNC_ROLE:-pull}" in
                pull) output=$(rsync -avzn --delete --max-delete=100 \
                        -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o BatchMode=yes" \
                        "${REMOTE_USER}@${REMOTE_DC}:/var/lib/samba/sysvol/" \
                        "/var/lib/samba/sysvol/" --exclude='*.tmp' 2>&1) ;;
                push) output=$(rsync -avzn --delete --max-delete=100 \
                        -e "ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o BatchMode=yes" \
                        "/var/lib/samba/sysvol/" \
                        "${REMOTE_USER}@${REMOTE_DC}:/var/lib/samba/sysvol/" --exclude='*.tmp' 2>&1) ;;
            esac
            ;;
        smb)
            [[ -f "${SMB_CRED_FILE:-}" ]] || { info "Credentials file '${SMB_CRED_FILE:-}' missing. Re-run configure."; return; }
            local realm_lower
            realm_lower=$(get_realm | tr '[:upper:]' '[:lower:]')
            output=$(smbclient "//${REMOTE_DC}/sysvol" -A "$SMB_CRED_FILE" \
                -c "ls ${realm_lower}\\*" 2>&1)
            ;;
        *)
            info "Unknown SYNC_TRANSPORT '${SYNC_TRANSPORT}'."
            return
            ;;
    esac
    whiptail --title "Dry Run (${SYNC_TRANSPORT:-ssh})" --scrolltext --msgbox "$output" 20 76
}

run_sysvol_sync() {
    [[ -f /etc/samba/sysvol-sync.conf ]] || { info "Not configured."; return; }
    yesno "Run SYSVOL sync now?" || return
    whiptail --infobox "Syncing..." 6 40
    /usr/local/sbin/sysvol-sync 2>&1
    info "Done. Log: /var/log/samba/sysvol-sync.log"
}

reset_sysvol_acls() {
    yesno "Reset SYSVOL ACLs?" || return
    # Older deployments provisioned/joined before the idmap-config fix will
    # loop here forever with "idmap range not specified for domain '*'".
    # Calling ensure_idmap_config is idempotent and cheap; it guarantees
    # sysvolreset can make progress regardless of how smb.conf got there.
    ensure_idmap_config
    local output; output=$(samba-tool ntacl sysvolreset 2>&1)
    info "ACLs reset.\n${output}"
}

show_sync_status() {
    local st="SYSVOL Sync Status\n==================\n\n"
    if [[ -f /etc/samba/sysvol-sync.conf ]]; then
        # shellcheck disable=SC1091
        source /etc/samba/sysvol-sync.conf
        st+="Transport: ${SYNC_TRANSPORT:-ssh} | Role: ${SYNC_ROLE:-?} | Remote: ${REMOTE_DC:-?}\n"
        case "${SYNC_TRANSPORT:-ssh}" in
            ssh) st+="User: ${REMOTE_USER:-?} | Key: ${SSH_KEY:-?}\n\n" ;;
            smb) st+="Credentials file: ${SMB_CRED_FILE:-?}\n\n" ;;
        esac
    else
        st+="Not configured.\n\n"
    fi
    [[ -f /etc/cron.d/sysvol-sync ]] && st+="Cron:\n$(cat /etc/cron.d/sysvol-sync)\n\n" || st+="Cron: not installed\n\n"
    [[ -f /var/log/samba/sysvol-sync.log ]] && st+="Last 10 lines:\n$(tail -10 /var/log/samba/sysvol-sync.log)\n" || st+="No sync log yet.\n"
    whiptail --title "Sync Status" --scrolltext --msgbox "$st" 22 76
}

#===============================================================================
# 5. SECURITY HARDENING
#===============================================================================
menu_hardening() {
    while true; do
        local choice
        choice=$(whiptail --title "Security Hardening" \
            --menu "Harden for production and Windows Server 2025 compatibility." \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Apply SMB/LDAP/Kerberos Hardening (WS2025)" \
            "2" "Enable AD DC Firewall (nftables)" \
            "3" "Disable Firewall" \
            "4" "Generate Self-Signed TLS Certificate" \
            "5" "Show Hardening Status" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) apply_ws2025_hardening ;;
            2) enable_firewall ;;
            3) disable_firewall ;;
            4) generate_tls_cert ;;
            5) show_hardening_status ;;
            B|b) return ;;
        esac
    done
}

apply_ws2025_hardening() {
    is_provisioned || { info "Not provisioned."; return; }
    yesno "Apply WS2025 hardening?\n\n- SMB3 mandatory signing\n- AES-only Kerberos\n- LDAP strong auth\n- NTLMv2 only\n- TLS 1.2+\n\nEnsure all clients support these." || return

    apply_hardening_to_smb_conf
    systemctl restart samba-ad-dc

    is_addc_running && info "Hardening applied and service restarted." || \
        info "WARNING: Service failed. Check journalctl -u samba-ad-dc"
}

enable_firewall() {
    [[ -f /etc/nftables-samba-addc.conf ]] || { info "Ruleset not found. Re-run prepare-image.sh."; return; }
    yesno "Enable AD DC firewall?\nOnly AD ports + SSH will be open." || return

    cp /etc/nftables-samba-addc.conf /etc/nftables.conf
    systemctl enable nftables
    nft -f /etc/nftables.conf
    info "Firewall enabled. Verify: nft list ruleset"
}

disable_firewall() {
    yesno "Disable firewall?" || return
    nft flush ruleset 2>/dev/null || true
    systemctl disable nftables 2>/dev/null || true
    info "Firewall disabled."
}

# Non-TUI core of TLS cert generation. Writes a self-signed cert with SAN
# entries (DNS fqdn, short hostname, IPv4), installs `tls keyfile/certfile/cafile`
# into smb.conf's [global] section, and restarts samba-ad-dc. Called from
# both the TUI menu 5 and automatically after a successful join so the
# appliance never advertises Samba's SAN-less auto-generated cert to clients.
_generate_tls_cert_core() {
    local realm fqdn shortname ip cert_dir
    realm=$(get_realm)
    fqdn=$(get_fqdn 2>/dev/null)
    shortname=$(hostname -s)
    # fallback compose if hostname -f is unreliable post-join
    if [[ "$fqdn" == "(not set)" || -z "$fqdn" || "$fqdn" == "$shortname" ]]; then
        fqdn="${shortname}.${realm,,}"
    fi
    ip=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    cert_dir="/var/lib/samba/private/tls"
    mkdir -p "$cert_dir"

    echo "[sconfig] generating TLS cert (CN=${fqdn}, SAN=DNS:${fqdn},DNS:${shortname},IP:${ip})"
    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" \
        -subj "/CN=${fqdn}/O=${realm}" \
        -addext "subjectAltName=DNS:${fqdn},DNS:${shortname},IP:${ip}" \
        -addext "basicConstraints=CA:FALSE" \
        -addext "keyUsage=digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=serverAuth,clientAuth" \
        2>/dev/null

    cp "$cert_dir/cert.pem" "$cert_dir/ca.pem"
    chmod 600 "$cert_dir/key.pem"
    chmod 644 "$cert_dir/cert.pem" "$cert_dir/ca.pem"

    local smb="/etc/samba/smb.conf"
    if ! grep -q 'tls keyfile' "$smb" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        awk -v cd="$cert_dir" '
            BEGIN { ins=0 }
            /^\[global\][[:space:]]*$/ && !ins {
                print
                print "\ttls keyfile = " cd "/key.pem"
                print "\ttls certfile = " cd "/cert.pem"
                print "\ttls cafile = " cd "/ca.pem"
                ins=1; next
            }
            { print }
        ' "$smb" > "$tmp" && mv "$tmp" "$smb"
    fi

    systemctl restart samba-ad-dc 2>/dev/null || true
    echo "[sconfig] TLS cert installed"
}

generate_tls_cert() {
    is_provisioned || { info "Not provisioned."; return; }
    local cert_dir="/var/lib/samba/private/tls"
    [[ -f "$cert_dir/cert.pem" ]] && ! yesno "Cert exists. Regenerate?" && return
    whiptail --infobox "Generating TLS certificate..." 6 50
    _generate_tls_cert_core
    info "TLS cert generated at ${cert_dir}/\nReplace with CA-signed cert for production."
}

show_hardening_status() {
    local st=""
    if is_provisioned; then
        local smb="/etc/samba/smb.conf"
        st+="SMB Signing:     $(grep -q 'server signing = mandatory' "$smb" 2>/dev/null && echo 'ENFORCED' || echo 'not enforced')\n"
        st+="Min Protocol:    $(grep -oP '(?<=server min protocol = ).*' "$smb" 2>/dev/null | head -1 || echo 'default')\n"
        st+="LDAP Strong:     $(grep -q 'ldap server require strong auth = yes' "$smb" 2>/dev/null && echo 'YES' || echo 'no')\n"
        st+="Kerberos:        $(grep -q 'aes256' "$smb" 2>/dev/null && echo 'AES only' || echo 'default (incl RC4)')\n"
        st+="NTLM:            $(grep -oP '(?<=ntlm auth = ).*' "$smb" 2>/dev/null | head -1 || echo 'default')\n"
        st+="TLS Enabled:     $(grep -q 'tls enabled = yes' "$smb" 2>/dev/null && echo 'YES' || echo 'no')\n"
        st+="TLS Cert:        $([[ -f /var/lib/samba/private/tls/cert.pem ]] && echo 'present' || echo 'not generated')\n"
        st+="Audit:           $(grep -q 'auth_audit:3' "$smb" 2>/dev/null && echo 'enabled' || echo 'default')\n"
    else
        st+="Domain not provisioned.\n"
    fi
    st+="\nFirewall:        $(nft list ruleset 2>/dev/null | grep -q 'filter' && echo 'active' || echo 'inactive')\n"
    st+="PowerShell SSH:  $(grep -q 'Subsystem.*powershell' /etc/ssh/sshd_config 2>/dev/null && echo 'enabled' || echo 'not configured')\n"
    st+="Update Policy:   $(get_update_policy)\n"

    whiptail --title "Hardening Status" --msgbox "$st" 22 64
}

#===============================================================================
# 6. DIAGNOSTICS
#===============================================================================
menu_diagnostics() {
    while true; do
        local choice
        choice=$(whiptail --title "Diagnostics" \
            --menu "Run tests on this DC." \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Full Sanity Check" \
            "2" "Test DNS Records" \
            "3" "Test Kerberos (kinit)" \
            "4" "Test SMB Shares" \
            "5" "Domain Level & FSMO Roles" \
            "6" "Replication Status" \
            "7" "Samba Logs (last 50)" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) run_full_sanity ;;
            2) test_dns ;;
            3) test_kerberos ;;
            4) test_smb ;;
            5) show_domain_info ;;
            6) test_replication ;;
            7) show_logs ;;
            B|b) return ;;
        esac
    done
}

run_full_sanity() {
    local r="" pass=0 fail=0 wrn=0
    r+="=== Sanity Check === $(date)\nHost: $(get_fqdn)\n\n"

    # Services
    r+="[Services]\n"
    is_addc_running && { r+="  ✓ samba-ad-dc running\n"; ((pass++)); } || { r+="  ✗ samba-ad-dc NOT running\n"; ((fail++)); }
    systemctl is-active chrony &>/dev/null && { r+="  ✓ chrony running\n"; ((pass++)); } || { r+="  ! chrony not running\n"; ((wrn++)); }

    # DNS
    r+="\n[DNS]\n"
    local rl fq
    rl=$(get_realm | tr '[:upper:]' '[:lower:]' 2>/dev/null)
    fq=$(get_fqdn)

    dig @localhost "$fq" +short 2>/dev/null | grep -q '[0-9]' && { r+="  ✓ A record resolves\n"; ((pass++)); } || { r+="  ✗ A record missing\n"; ((fail++)); }
    dig -t SRV @localhost "_ldap._tcp.${rl}" +short 2>/dev/null | grep -q '[0-9]' && { r+="  ✓ _ldap._tcp SRV\n"; ((pass++)); } || { r+="  ✗ _ldap._tcp SRV missing\n"; ((fail++)); }
    dig -t SRV @localhost "_kerberos._tcp.${rl}" +short 2>/dev/null | grep -q '[0-9]' && { r+="  ✓ _kerberos._tcp SRV\n"; ((pass++)); } || { r+="  ✗ _kerberos._tcp SRV missing\n"; ((fail++)); }
    dig @localhost google.com +short 2>/dev/null | grep -q '[0-9]' && { r+="  ✓ DNS forwarding works\n"; ((pass++)); } || { r+="  ! forwarding failed\n"; ((wrn++)); }

    # Kerberos
    r+="\n[Kerberos]\n"
    klist -s 2>/dev/null && { r+="  ✓ Valid TGT\n"; ((pass++)); } || { r+="  ! No TGT (run kinit)\n"; ((wrn++)); }

    # SMB
    r+="\n[SMB]\n"
    smbclient -L localhost -U% -N 2>/dev/null | grep -q 'sysvol' && { r+="  ✓ sysvol accessible\n"; ((pass++)); } || { r+="  ✗ sysvol missing\n"; ((fail++)); }
    smbclient -L localhost -U% -N 2>/dev/null | grep -q 'netlogon' && { r+="  ✓ netlogon accessible\n"; ((pass++)); } || { r+="  ✗ netlogon missing\n"; ((fail++)); }

    # Winbind
    r+="\n[Winbind]\n"
    wbinfo -p 2>/dev/null | grep -q 'succeeded' && { r+="  ✓ winbind ping OK\n"; ((pass++)); } || { r+="  ! winbind ping failed\n"; ((wrn++)); }
    getent passwd administrator &>/dev/null && { r+="  ✓ NSS resolves administrator\n"; ((pass++)); } || { r+="  ! cannot resolve administrator\n"; ((wrn++)); }

    # Hostname
    r+="\n[Hostname]\n"
    local hosts_ip actual_ip
    hosts_ip=$(grep -m1 "$(hostname -s)" /etc/hosts 2>/dev/null | awk '{print $1}')
    actual_ip=$(get_ip | cut -d/ -f1)
    [[ "$hosts_ip" == "$actual_ip" ]] && { r+="  ✓ /etc/hosts matches interface\n"; ((pass++)); } || { r+="  ✗ IP mismatch (hosts=$hosts_ip iface=$actual_ip)\n"; ((fail++)); }

    # PowerShell
    r+="\n[PowerShell]\n"
    command -v pwsh &>/dev/null && { r+="  ✓ pwsh installed ($(pwsh --version 2>/dev/null))\n"; ((pass++)); } || { r+="  ! pwsh not installed\n"; ((wrn++)); }
    grep -q 'Subsystem.*powershell' /etc/ssh/sshd_config 2>/dev/null && { r+="  ✓ SSH remoting configured\n"; ((pass++)); } || { r+="  ! SSH remoting not configured\n"; ((wrn++)); }

    r+="\n========================================\n"
    r+="PASSED: $pass | WARNINGS: $wrn | FAILED: $fail\n"
    [[ $fail -eq 0 ]] && r+="\nOverall: HEALTHY" || r+="\nOverall: ISSUES DETECTED"

    whiptail --title "Sanity Check" --scrolltext --msgbox "$r" 34 76
}

test_dns() {
    is_provisioned || { info "Not provisioned."; return; }
    local rl fq out
    rl=$(get_realm | tr '[:upper:]' '[:lower:]'); fq=$(get_fqdn)
    out="=== DNS Tests ===\n\n"
    out+="A ($fq):\n$(dig @localhost "$fq" +short 2>&1)\n\n"
    out+="_ldap._tcp:\n$(dig -t SRV @localhost "_ldap._tcp.${rl}" +short 2>&1)\n\n"
    out+="_kerberos._tcp:\n$(dig -t SRV @localhost "_kerberos._tcp.${rl}" +short 2>&1)\n\n"
    out+="_gc._tcp:\n$(dig -t SRV @localhost "_gc._tcp.${rl}" +short 2>&1)\n\n"
    out+="Forwarding (google.com):\n$(dig @localhost google.com +short 2>&1)\n"
    whiptail --title "DNS" --scrolltext --msgbox "$out" 26 76
}

test_kerberos() {
    is_provisioned || { info "Not provisioned."; return; }
    local pass; pass=$(whiptail --passwordbox "Administrator password:" 10 60 3>&1 1>&2 2>&3) || return
    local out; out=$(echo "$pass" | kinit administrator 2>&1); out+="\n\n$(klist 2>&1)"
    whiptail --title "Kerberos" --scrolltext --msgbox "$out" 20 76
}

test_smb() {
    whiptail --title "SMB" --scrolltext --msgbox "$(smbclient -L localhost -U% -N 2>&1)" 20 76
}

show_domain_info() {
    is_provisioned || { info "Not provisioned."; return; }
    local out="=== Domain ===\n\n$(samba-tool domain level show 2>&1)\n\nFSMO:\n$(samba-tool fsmo show 2>&1)\n"
    whiptail --title "Domain Info" --scrolltext --msgbox "$out" 24 76
}

test_replication() {
    is_provisioned || { info "Not provisioned."; return; }
    whiptail --title "Replication" --scrolltext --msgbox "$(samba-tool drs showrepl 2>&1)" 24 76
}

show_logs() {
    whiptail --title "Logs (last 50)" --scrolltext --msgbox "$(journalctl -u samba-ad-dc -n 50 --no-pager 2>&1)" 24 76
}

#===============================================================================
# 7. SERVICE MANAGEMENT
#===============================================================================
menu_services() {
    while true; do
        local addc chr nft
        addc=$(systemctl is-active samba-ad-dc 2>/dev/null || echo "inactive")
        chr=$(systemctl is-active chrony 2>/dev/null || echo "inactive")
        nft=$(systemctl is-active nftables 2>/dev/null || echo "inactive")

        local choice
        choice=$(whiptail --title "Services" \
            --menu "samba-ad-dc: $addc | chrony: $chr | nftables: $nft" \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Start samba-ad-dc" \
            "2" "Stop samba-ad-dc" \
            "3" "Restart samba-ad-dc" \
            "4" "Start chrony" \
            "5" "Restart chrony" \
            "6" "Full status" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) systemctl start samba-ad-dc; info "Started." ;;
            2) systemctl stop samba-ad-dc; info "Stopped." ;;
            3) systemctl restart samba-ad-dc; sleep 2
               is_addc_running && info "Restarted." || info "FAILED. Check logs." ;;
            4) systemctl start chrony; info "Started." ;;
            5) systemctl restart chrony; info "Restarted." ;;
            6) whiptail --title "Status" --scrolltext --msgbox \
                "$(systemctl status samba-ad-dc chrony nftables 2>&1 | head -40)" 24 76 ;;
            B|b) return ;;
        esac
    done
}

#===============================================================================
# 8. POWER
#===============================================================================
menu_power() {
    local choice
    choice=$(whiptail --title "Power" --menu "" 12 50 4 \
        "1" "Reboot" "2" "Shutdown" "B" "Back" \
        3>&1 1>&2 2>&3) || return
    case "$choice" in
        1) yesno "Reboot now?" && reboot ;;
        2) yesno "Shutdown now?" && shutdown -h now ;;
    esac
}

#===============================================================================
# HEADLESS CLI (testing / automation)
#
# The TUI is the primary UX. These subcommands mirror a subset of the TUI
# operations for scripted verification (see test-results/ regression runs)
# and so `run-tests.sh` can drive the appliance without `expect`.
# Add new commands here when a test needs to exercise TUI behavior. Prefer a
# narrow command that reuses existing helpers over automating whiptail screens;
# the latter is brittle and tends to hide the real failure output.
#===============================================================================
cli_probe_fl() {
    local dc="${1:?usage: samba-sconfig probe-fl <dc-fqdn-or-ip>}"
    probe_forest_fl "$dc"
}

cli_join_dc() {
    : "${SC_REALM:?SC_REALM env var required}"
    : "${SC_NETBIOS:?SC_NETBIOS env var required}"
    : "${SC_DC:?SC_DC env var required (target DC FQDN or IP)}"
    : "${SC_PASS:?SC_PASS env var required}"
    SC_FWD="${SC_FWD:-$SC_DC}"
    SC_ROLE="${SC_ROLE:-DC}"           # DC or RODC
    SC_ADMIN="${SC_ADMIN:-Administrator}"

    local DC_REALM="${SC_REALM^^}"
    local DC_NETBIOS="${SC_NETBIOS^^}"
    local DC_ADMIN_USER="$SC_ADMIN"
    local DC_ADMIN_PASS="$SC_PASS"
    local DC_DNS_FORWARDER="$SC_FWD"

    local dc_ip
    if ! dc_ip=$(resolve_dc_ip "$SC_DC"); then
        echo "[sconfig] cannot resolve SC_DC='$SC_DC' via the current resolver — pass an IP or fix /etc/resolv.conf" >&2
        return 1
    fi

    local fl_str
    fl_str=$(probe_forest_fl "$dc_ip")
    echo "[sconfig] forest FL probe: $fl_str"

    rm -f /etc/samba/smb.conf
    systemctl stop samba-ad-dc 2>/dev/null || true
    write_krb5_conf "$DC_REALM"
    echo -e "search ${DC_REALM,,}\nnameserver ${dc_ip}" > /etc/resolv.conf

    echo "[sconfig] joining $DC_REALM as $SC_ROLE via $SC_DC ($dc_ip), user=${DC_NETBIOS}\\${DC_ADMIN_USER}, FL=$fl_str..."
    if samba-tool domain join "$DC_REALM" "$SC_ROLE" \
        --dns-backend=SAMBA_INTERNAL \
        --option="dns forwarder = $DC_DNS_FORWARDER" \
        --option="ad dc functional level = $fl_str" \
        -U"${DC_NETBIOS}\\${DC_ADMIN_USER}" \
        --password="$DC_ADMIN_PASS"; then
        apply_hardening_to_smb_conf
        post_provision_setup "$DC_REALM" "$DC_DNS_FORWARDER"
        register_own_ptr "$dc_ip" "$DC_NETBIOS" "$DC_ADMIN_USER" "$DC_ADMIN_PASS" "$DC_REALM" || true
        seed_sysvol "$dc_ip" "$DC_NETBIOS" "$DC_ADMIN_USER" "$DC_ADMIN_PASS" "$DC_REALM" || true
        configure_chrony_for_domain "$dc_ip"
        _generate_tls_cert_core
        echo "[sconfig] JOIN SUCCESS (FL=$fl_str) — TLS cert has SAN, PTR registered, SYSVOL seeded"
    else
        local rc=$?
        echo "[sconfig] JOIN FAILED (rc=$rc)" >&2
        return "$rc"
    fi
}

usage_cli() {
    cat <<USAGE
Usage: samba-sconfig                  # interactive TUI
       samba-sconfig probe-fl <dc>    # print detected forest FL string
       samba-sconfig join-dc          # headless join
           required env: SC_REALM, SC_NETBIOS, SC_DC (FQDN or IP), SC_PASS
           optional env: SC_FWD (default: SC_DC)
                         SC_ROLE=DC|RODC (default: DC)
                         SC_ADMIN (default: Administrator) — any domain
                                  account with join rights
USAGE
}

#===============================================================================
# ENTRY
#===============================================================================
check_root

case "${1:-}" in
    "")           main_menu ;;
    probe-fl)     shift; cli_probe_fl "$@" ;;
    join-dc)      cli_join_dc ;;
    -h|--help)    usage_cli ;;
    *)            echo "Unknown subcommand: $1" >&2; usage_cli >&2; exit 2 ;;
esac
