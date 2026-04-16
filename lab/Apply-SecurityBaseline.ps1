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
    [string]$DcPolicyPattern = '*Domain Controller*',
    [string]$MemberPolicyPattern = '*Member Server*'
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
    param($DcPattern, $MemberPattern)
    Import-Module GroupPolicy

    # DC baseline → Domain Controllers OU
    $dcGpo = Get-GPO -All | Where-Object { $_.DisplayName -like $DcPattern } |
             Select-Object -First 1
    if ($dcGpo) {
        New-GPLink -Name $dcGpo.DisplayName `
            -Target 'OU=Domain Controllers,DC=lab,DC=test' `
            -LinkEnabled Yes -ErrorAction SilentlyContinue | Out-Null
        Write-Host "    ✓ Linked '$($dcGpo.DisplayName)' → Domain Controllers"
    }

    # Member Server baseline → Lab/TestServers OU
    $memberGpo = Get-GPO -All | Where-Object { $_.DisplayName -like $MemberPattern } |
                 Select-Object -First 1
    if ($memberGpo) {
        New-GPLink -Name $memberGpo.DisplayName `
            -Target 'OU=TestServers,OU=Lab,DC=lab,DC=test' `
            -LinkEnabled Yes -ErrorAction SilentlyContinue | Out-Null
        Write-Host "    ✓ Linked '$($memberGpo.DisplayName)' → Lab/TestServers"
    }

    # Force GP update on DC
    gpupdate /force | Out-Null
} -ArgumentList $DcPolicyPattern, $MemberPolicyPattern

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
