#Requires -RunAsAdministrator
<#
.SYNOPSIS
    First-logon script for WS2025 lab DC.

.DESCRIPTION
    Runs automatically on first login after OOBE via autounattend.xml
    FirstLogonCommands. Configures static network, installs AD DS role,
    promotes to domain controller, then reboots.

    Parameters are hard-coded below — modify before running New-WS2025Lab.ps1
    if you want different network/domain values.

.NOTES
    Logs to C:\Setup\firstlogon.log
    After promotion reboot, the DC is ready for security baseline import.
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

# ── Lab parameters ────────────────────────────────────────────────────────────
$ComputerName   = 'WS2025-DC1'
$IPAddress      = '172.22.0.10'
$PrefixLength   = 24
$DefaultGateway = '172.22.0.1'
$DnsServer      = '127.0.0.1'        # Once it's a DC, uses itself
$DomainName     = 'lab.test'         # Realm (not .local!)
$NetBiosName    = 'LAB'
$DsrmPassword   = 'P@ssword123456!'  # Directory Services Restore Mode password

# Same password as local Administrator (set via autounattend.xml)
$SafeModePwd = ConvertTo-SecureString $DsrmPassword -AsPlainText -Force

# ── Start ──────────────────────────────────────────────────────────────────────
New-Item -Path (Split-Path $LogFile) -ItemType Directory -Force | Out-Null
Write-Log "===== First Logon Setup Started ====="
Write-Log "Computer: $ComputerName | Domain: $DomainName | IP: $IPAddress"

# ── Phase detection ───────────────────────────────────────────────────────────
# This script runs twice: before promotion (Phase 1) and after reboot (Phase 2)
$PhaseMarker = 'C:\Setup\phase2.marker'

if (-not (Test-Path $PhaseMarker)) {

    # ═══════════════════ PHASE 1: Pre-promotion ═══════════════════

    Write-Log "Phase 1: Configuring network and installing AD DS role"

    # Enable WinRM and PS Remoting
    Write-Log "Enabling PowerShell remoting..."
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
    Write-Log "  PSRemoting enabled; TrustedHosts=*"

    # Enable SSH server (OpenSSH ships with Server 2025)
    Write-Log "Enabling OpenSSH server..."
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    Start-Service sshd -ErrorAction SilentlyContinue
    Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 `
        -ErrorAction SilentlyContinue | Out-Null
    Write-Log "  OpenSSH enabled"

    # Configure static network
    Write-Log "Configuring static network..."
    $Adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if (-not $Adapter) {
        Write-Log "  ERROR: No active adapter found!"
        exit 1
    }
    Write-Log "  Using adapter: $($Adapter.Name)"

    # Remove any existing IP config
    $Adapter | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    $Adapter | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceIndex $Adapter.ifIndex `
        -IPAddress $IPAddress -PrefixLength $PrefixLength `
        -DefaultGateway $DefaultGateway | Out-Null

    # Initially use external DNS for getting updates; after promotion, self
    Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex `
        -ServerAddresses '1.1.1.1','8.8.8.8'
    Write-Log "  Static IP $IPAddress/$PrefixLength on $($Adapter.Name)"

    # Install AD DS role
    Write-Log "Installing AD DS role..."
    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
    Write-Log "  AD DS role installed"

    # Create Phase 2 marker
    New-Item -Path $PhaseMarker -ItemType File -Force | Out-Null

    # Promote to DC (this triggers a reboot)
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

    # Install-ADDSForest triggers its own reboot; nothing below runs
    Write-Log "Install-ADDSForest initiated reboot"
}
else {

    # ═══════════════════ PHASE 2: Post-promotion ═══════════════════

    Write-Log "Phase 2: Post-promotion configuration"

    # Wait for AD DS to be ready
    Write-Log "Waiting for AD DS services..."
    $Tries = 0
    while ($Tries -lt 30) {
        try {
            Get-ADDomain -ErrorAction Stop | Out-Null
            Write-Log "  AD DS ready"
            break
        } catch {
            Start-Sleep -Seconds 10
            $Tries++
        }
    }

    # Now set DNS to self
    Write-Log "Setting DNS to self (127.0.0.1)..."
    $Adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses '127.0.0.1'

    # Configure DNS forwarder for external resolution
    Write-Log "Configuring DNS forwarder..."
    Add-DnsServerForwarder -IPAddress '1.1.1.1','8.8.8.8' -ErrorAction SilentlyContinue

    # Create reverse lookup zone
    Write-Log "Creating reverse lookup zone..."
    Add-DnsServerPrimaryZone -NetworkId '172.22.0.0/24' -ReplicationScope 'Domain' `
        -ErrorAction SilentlyContinue

    # Create an OU for test servers
    Write-Log "Creating Lab OU structure..."
    try {
        New-ADOrganizationalUnit -Name 'Lab' -Path "DC=lab,DC=test" -ErrorAction Stop
        New-ADOrganizationalUnit -Name 'TestServers' -Path "OU=Lab,DC=lab,DC=test" -ErrorAction Stop
        New-ADOrganizationalUnit -Name 'TestDCs' -Path "OU=Lab,DC=lab,DC=test" -ErrorAction Stop
        Write-Log "  OUs created: Lab/TestServers, Lab/TestDCs"
    } catch {
        Write-Log "  OUs already exist or creation failed: $_"
    }

    # Ensure SSH is running
    Start-Service sshd -ErrorAction SilentlyContinue

    # Mark as complete
    New-Item -Path 'C:\Setup\setup-complete.marker' -ItemType File -Force | Out-Null
    Write-Log "===== First Logon Setup COMPLETE ====="

    # Disable autologon now that setup is done
    $WinLogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $WinLogon -Name AutoAdminLogon -Value '0'
    Remove-ItemProperty -Path $WinLogon -Name DefaultPassword -ErrorAction SilentlyContinue
}
