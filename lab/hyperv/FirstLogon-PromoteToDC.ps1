#Requires -RunAsAdministrator
<#
.SYNOPSIS
    First-logon script for the WS2025 lab DC (lab-v2 topology).

.DESCRIPTION
    Runs automatically on first login after OOBE via autounattend.xml
    FirstLogonCommands. On its first invocation (Phase 1), it:
      - Enables PSRemoting + OpenSSH
      - Converts the DHCP-reserved address to a static assignment (10.10.10.10)
      - Installs the AD DS role
      - Registers a RunOnce entry that re-invokes this script at the next
        autologon (critical — <FirstLogonCommands> only fires once, so without
        RunOnce the phase-2 block below never executes)
      - Triggers Install-ADDSForest which reboots into a promoted state

    On the second autologon (Phase 2), it:
      - Sets the DNS client to self (127.0.0.1)
      - Configures DNS forwarders (to the router, which handles upstream)
      - Creates the reverse lookup zone for 10.10.10.0/24
      - Creates Lab / TestDCs / TestServers OUs
      - Writes the completion marker and disables autologon

.NOTES
    Lab-v2 network:
      router1 (10.10.10.1)  — NAT + dnsmasq DHCP/DNS
      WS2025-DC1 (10.10.10.10) — this host
      samba-dc1 (10.10.10.20) — the appliance under test
#>

$ErrorActionPreference = 'Stop'
$LogFile = 'C:\Setup\firstlogon.log'

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$ts  $Message"
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

# ── Lab-v2 parameters ────────────────────────────────────────────────────────
$ComputerName   = 'WS2025-DC1'
$IPAddress      = '10.10.10.10'
$PrefixLength   = 24
$DefaultGateway = '10.10.10.1'
$RouterDNS      = '10.10.10.1'       # before promotion, resolve via router
$DomainName     = 'lab.test'
$NetBiosName    = 'LAB'
$DsrmPassword   = 'P@ssword123456!'
$ReverseZone    = '10.10.10.in-addr.arpa'

$SafeModePwd = ConvertTo-SecureString $DsrmPassword -AsPlainText -Force

# ── Start ────────────────────────────────────────────────────────────────────
New-Item -Path (Split-Path $LogFile) -ItemType Directory -Force | Out-Null
Write-Log "===== First Logon Setup invoked ====="
Write-Log "Computer: $ComputerName | Domain: $DomainName | IP: $IPAddress"

$PhaseMarker = 'C:\Setup\phase2.marker'
$CompleteMarker = 'C:\Setup\setup-complete.marker'

if (-not (Test-Path $PhaseMarker)) {

    # ═══════════════════ PHASE 1: Pre-promotion ═══════════════════
    Write-Log "Phase 1: Configuring network and installing AD DS role"

    # PowerShell remoting + OpenSSH
    Write-Log "Enabling PowerShell remoting..."
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
    Write-Log "  PSRemoting enabled; TrustedHosts=*"

    Write-Log "Enabling OpenSSH server..."
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    Start-Service sshd -ErrorAction SilentlyContinue
    Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 `
        -ErrorAction SilentlyContinue | Out-Null
    Write-Log "  OpenSSH enabled"

    # Network — convert DHCP-reserved address to static. The dnsmasq reservation
    # on router1 already gave us the right IP; we just pin it so DCPROMO
    # doesn't warn and the IP survives any future DHCP-pool changes.
    Write-Log "Configuring static network..."
    $Adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    if (-not $Adapter) { Write-Log "  ERROR: no active adapter"; exit 1 }
    Write-Log "  Using adapter: $($Adapter.Name)"

    # Disable DHCP FIRST — otherwise Remove-NetIPAddress leaves the lease
    # active, DHCP client re-binds immediately, and New-NetIPAddress fails
    # with 'Instance MSFT_NetIPAddress already exists'. See Windows networking
    # quirk — DHCP client won't release until the interface stops asking.
    Set-NetIPInterface -InterfaceIndex $Adapter.ifIndex -Dhcp Disabled `
        -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    # Idempotent assignment: if the static IP already exists (from a prior
    # interrupted run) New-NetIPAddress errors with "already exists" — in
    # that case trust the existing config and move on.
    try {
        New-NetIPAddress -InterfaceIndex $Adapter.ifIndex `
            -IPAddress $IPAddress -PrefixLength $PrefixLength `
            -DefaultGateway $DefaultGateway -ErrorAction Stop | Out-Null
    } catch {
        if ($_.Exception.Message -match 'already exists') {
            Write-Log "  IP $IPAddress already present — leaving as-is"
        } else { throw }
    }
    Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $RouterDNS
    Write-Log "  Static $IPAddress/$PrefixLength gw=$DefaultGateway dns=$RouterDNS"

    # Install AD DS role (no promotion yet — that's next)
    Write-Log "Installing AD DS role..."
    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
    Write-Log "  AD DS role installed"

    # Register RunOnce for phase 2. <FirstLogonCommands> in autounattend.xml
    # only fires on the first pass; we rely on RunOnce to re-invoke this
    # script after the Install-ADDSForest reboot.
    $RunOnceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    $cmd = 'powershell.exe -ExecutionPolicy Bypass -NoProfile -File C:\Setup\FirstLogon-PromoteToDC.ps1'
    Set-ItemProperty -Path $RunOnceKey -Name 'FirstLogonPhase2' -Value $cmd
    Write-Log "  RunOnce 'FirstLogonPhase2' registered -> $cmd"

    # Mark phase 2 pending BEFORE Install-ADDSForest triggers the reboot
    New-Item -Path $PhaseMarker -ItemType File -Force | Out-Null

    Write-Log "Promoting to first DC in new forest: $DomainName"
    Install-ADDSForest `
        -DomainName $DomainName `
        -DomainNetbiosName $NetBiosName `
        -DomainMode WinThreshold `
        -ForestMode WinThreshold `
        -InstallDns `
        -DatabasePath 'C:\Windows\NTDS' `
        -LogPath 'C:\Windows\NTDS' `
        -SysvolPath 'C:\Windows\SYSVOL' `
        -SafeModeAdministratorPassword $SafeModePwd `
        -Force `
        -NoRebootOnCompletion:$false

    # Install-ADDSForest initiates its own reboot; nothing after this runs
    Write-Log "Install-ADDSForest initiated reboot"
    exit 0
}

# ═══════════════════ PHASE 2: Post-promotion ═══════════════════
Write-Log "Phase 2: Post-promotion configuration"

# Wait for AD DS to be ready. On a fresh promotion, the database may still be
# initializing when the RunOnce fires. Retry up to 5 min.
Write-Log "Waiting for AD DS services..."
$tries = 0
while ($tries -lt 30) {
    try {
        Get-ADDomain -ErrorAction Stop | Out-Null
        Write-Log "  AD DS ready ($(((Get-ADDomain).DNSRoot)))"
        break
    } catch {
        Start-Sleep -Seconds 10
        $tries++
    }
}
if ($tries -ge 30) {
    Write-Log "  ERROR: AD DS never became ready"
    exit 1
}

# DNS to self now that we're a DC
Write-Log "Setting DNS to self (127.0.0.1)..."
$Adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses '127.0.0.1'

# Router handles upstream DNS; point our DNS forwarders there so recursive
# lookups for non-lab.test go via router → public.
Write-Log "Configuring DNS forwarder -> $RouterDNS"
try {
    # Remove any stale forwarders first so we don't accumulate
    $existing = Get-DnsServerForwarder -ErrorAction SilentlyContinue
    foreach ($ip in $existing.IPAddress) {
        if ($ip.IPAddressToString -ne $RouterDNS) {
            Remove-DnsServerForwarder -IPAddress $ip.IPAddressToString -Force -ErrorAction SilentlyContinue
        }
    }
    Add-DnsServerForwarder -IPAddress $RouterDNS -PassThru -ErrorAction SilentlyContinue | Out-Null
} catch {
    Write-Log "  DNS forwarder setup: $_"
}

# Reverse lookup zone — required so KCC can establish replica links from
# additional DCs (WS2016+ KCC returns 8524 DNS-lookup-failure without it).
Write-Log "Creating reverse lookup zone $ReverseZone ..."
Add-DnsServerPrimaryZone -NetworkId '10.10.10.0/24' -ReplicationScope 'Domain' `
    -ErrorAction SilentlyContinue

# Lab OU structure — where additional DCs + member servers go during testing.
Write-Log "Creating Lab OU structure..."
foreach ($ou in @(
    @{Name='Lab';          Path='DC=lab,DC=test'},
    @{Name='TestDCs';      Path='OU=Lab,DC=lab,DC=test'},
    @{Name='TestServers';  Path='OU=Lab,DC=lab,DC=test'}
)) {
    try {
        New-ADOrganizationalUnit -Name $ou.Name -Path $ou.Path -ErrorAction Stop
        Write-Log "  + OU $($ou.Name) in $($ou.Path)"
    } catch [Microsoft.ActiveDirectory.Management.ADException] {
        Write-Log "  = OU $($ou.Name) already present"
    } catch {
        Write-Log "  ! failed OU $($ou.Name): $_"
    }
}

# Make sure sshd is running on this (now-promoted) machine
Start-Service sshd -ErrorAction SilentlyContinue

# Completion marker
New-Item -Path $CompleteMarker -ItemType File -Force | Out-Null
Write-Log "===== First Logon Setup COMPLETE ====="

# Disable autologon
$WinLogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $WinLogon -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $WinLogon -Name DefaultPassword -ErrorAction SilentlyContinue
