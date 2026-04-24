#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Import the Windows Server 2025 Security Baseline into the lab domain.

.DESCRIPTION
    This script runs ON THE HYPER-V HOST and uses PowerShell Direct to push
    the baseline ZIP to the DC VM, then invokes Baseline-ADImport.ps1 inside.

    Afterwards it links the DC policy to the Domain Controllers OU and the
    Member Server policy to Lab\TestServers OU.

    The ZIP must be at $BaselineZipPath on the host (defaults to
    D:\ISO\WS2025-2602-Security-Baseline.zip).

.EXAMPLE
    .\Apply-SecurityBaseline.ps1
#>

[CmdletBinding()]
param(
    [string]$BaselineZipPath = 'D:\ISO\WS2025-2602-Security-Baseline.zip',
    [string]$DcVMName        = 'WS2025-DC1',
    [string]$DomainName      = 'lab.test',
    [string]$NetBiosName     = 'LAB',
    [string]$AdminPassword   = 'P@ssword123456!',
    # Intended link targets for each baseline GPO. Empty Target means "skip".
    # Keyed by exact DisplayName to avoid the *Member Server* wildcard trap
    # (matches both Member Server and Member Server Credential Guard).
    [hashtable]$BaselineLinks = @{
        # Domain-wide: account/audit policies, defender, legacy IE compat
        'MSFT Windows Server 2025 v2602 - Domain Security'  = 'DC=lab,DC=test'
        'MSFT Windows Server 2025 v2602 - Defender Antivirus' = 'DC=lab,DC=test'
        'MSFT Internet Explorer 11 - Computer'               = 'DC=lab,DC=test'
        'MSFT Internet Explorer 11 - User'                   = 'DC=lab,DC=test'

        # Domain Controllers OU: DC-specific hardening (LDAP, DRS, SYSVOL) + VBS
        'MSFT Windows Server 2025 v2602 - Domain Controller' = 'OU=Domain Controllers,DC=lab,DC=test'
        'MSFT Windows Server 2025 v2602 - Domain Controller Virtualization Based Security' = 'OU=Domain Controllers,DC=lab,DC=test'

        # Member Servers OU: general server hardening + Credential Guard
        'MSFT Windows Server 2025 v2602 - Member Server'     = 'OU=TestServers,OU=Lab,DC=lab,DC=test'
        'MSFT Windows Server 2025 v2602 - Member Server Credential Guard' = 'OU=TestServers,OU=Lab,DC=lab,DC=test'
    }
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "    ✓ $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    ! $m" -ForegroundColor Yellow }

if (-not (Test-Path $BaselineZipPath)) {
    throw "Baseline ZIP not found: $BaselineZipPath"
}

# ── Build credential for PSDirect ─────────────────────────────────────────────
$SecPass = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
$Cred = New-Object System.Management.Automation.PSCredential("$NetBiosName\Administrator", $SecPass)

# Wait for DC to be fully up (setup-complete.marker)
Write-Step "Waiting for DC setup to complete"
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $ready = Invoke-Command -VMName $DcVMName -Credential $Cred -ScriptBlock {
            Test-Path 'C:\Setup\setup-complete.marker'
        } -ErrorAction Stop
        if ($ready) { break }
    } catch {
        # Still booting or promoting
    }
    Start-Sleep -Seconds 10
    Write-Host "    ...waiting ($($i*10)s)"
}
if (-not $ready) { throw "DC did not signal setup-complete within 5 minutes" }
Write-OK "DC setup complete"

# ── Copy baseline ZIP to DC ───────────────────────────────────────────────────
Write-Step "Copying baseline ZIP to DC"
$ZipName = Split-Path $BaselineZipPath -Leaf
Copy-VMFile -Name $DcVMName -SourcePath $BaselineZipPath `
    -DestinationPath "C:\Setup\$ZipName" -FileSource Host -CreateFullPath -Force
Write-OK "Copied → C:\Setup\$ZipName"

# ── Extract and import on DC ──────────────────────────────────────────────────
Write-Step "Extracting and importing GPOs on DC"

Invoke-Command -VMName $DcVMName -Credential $Cred -ScriptBlock {
    param($ZipName)
    $ErrorActionPreference = 'Stop'
    $ExtractPath = 'C:\Setup\SecurityBaseline'

    if (Test-Path $ExtractPath) { Remove-Item -Path $ExtractPath -Recurse -Force }
    Expand-Archive -Path "C:\Setup\$ZipName" -DestinationPath $ExtractPath -Force

    # Locate baseline root (scripts expect to run from Scripts folder)
    $baselineRoot = Get-ChildItem -Path $ExtractPath -Directory | Select-Object -First 1
    if (-not $baselineRoot) { throw "Could not locate baseline root directory in ZIP" }

    $scriptsDir = Join-Path $baselineRoot.FullName 'Scripts'
    $importScript = Join-Path $scriptsDir 'Baseline-ADImport.ps1'

    if (-not (Test-Path $importScript)) {
        throw "Baseline-ADImport.ps1 not found at $importScript"
    }

    Write-Host "  Running Baseline-ADImport.ps1..."
    Push-Location $scriptsDir
    & $importScript
    Pop-Location

    # Copy ADMX/ADML to Central Store
    Write-Host "  Copying ADMX/ADML templates to SYSVOL central store..."
    $centralStore = "C:\Windows\SYSVOL\sysvol\lab.test\Policies\PolicyDefinitions"
    if (-not (Test-Path $centralStore)) {
        New-Item -Path $centralStore -ItemType Directory -Force | Out-Null
        New-Item -Path "$centralStore\en-US" -ItemType Directory -Force | Out-Null
    }

    $templatesDir = Join-Path $baselineRoot.FullName 'Templates'
    if (Test-Path $templatesDir) {
        Get-ChildItem -Path $templatesDir -Filter '*.admx' | Copy-Item -Destination $centralStore -Force
        Get-ChildItem -Path "$templatesDir\en-US" -Filter '*.adml' -ErrorAction SilentlyContinue |
            Copy-Item -Destination "$centralStore\en-US" -Force
    }

    Write-Host "  ✓ Import complete. Listing imported GPOs..."
    Get-GPO -All | Where-Object { $_.DisplayName -like 'MSFT*2025*' -or $_.DisplayName -like '*Server 2025*' } |
        Select-Object DisplayName, CreationTime
} -ArgumentList $ZipName

Write-OK "Baseline GPOs imported into domain"

# ── Link GPOs to appropriate OUs ──────────────────────────────────────────────
Write-Step "Linking baseline GPOs to OUs"

Invoke-Command -VMName $DcVMName -Credential $Cred -ScriptBlock {
    param($LinkMap)
    Import-Module GroupPolicy

    foreach ($entry in $LinkMap.GetEnumerator() | Sort-Object Name) {
        $name = $entry.Key
        $target = $entry.Value
        if (-not $target) { continue }

        $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
        if (-not $gpo) {
            Write-Host "    ! GPO '$name' not found in domain"
            continue
        }

        # Idempotent: if a link on this target already exists, skip creation
        $inh = Get-GPInheritance -Target $target -ErrorAction SilentlyContinue
        $already = $inh.GpoLinks | Where-Object DisplayName -eq $name
        if ($already) {
            Write-Host "    = '$name' already linked -> $target"
            continue
        }

        try {
            New-GPLink -Name $name -Target $target -LinkEnabled Yes -ErrorAction Stop | Out-Null
            Write-Host "    + Linked '$name' -> $target"
        } catch {
            Write-Host "    ! New-GPLink failed for '$name' -> $target : $_"
        }
    }

    # Force GP update on DC
    gpupdate /force | Out-Null
} -ArgumentList $BaselineLinks

Write-OK "Baseline applied and linked"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Security baseline applied.                                  ║" -ForegroundColor Green
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "║  Verify with:                                                ║" -ForegroundColor Green
Write-Host "║    Invoke-Command -VMName $DcVMName -Credential LAB\Administrator {" -ForegroundColor Green
Write-Host "║      Get-GPO -All; gpresult /R                               ║" -ForegroundColor Green
Write-Host "║    }                                                         ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
