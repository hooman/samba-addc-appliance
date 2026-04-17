#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Build the WS2025 DC of the Samba lab (lab-v2 topology).

.DESCRIPTION
    Assumes:
      - Lab-NAT switch exists (created by New-LabRouter.ps1)
      - router1 is up and serving DHCP on 10.10.10.0/24 with a reservation
        for `WS2025-DC1` at 10.10.10.10

    Creates (idempotently):
      - WS2025-DC1 VM: Gen2, Server Core, injected FirstLogon script
      - Injects unattend.xml + FirstLogon-PromoteToDC.ps1 into the VHDX
      - Boots; FirstLogon runs twice (Phase 1 pre-promotion, Phase 2 via
        RunOnce post-promotion reboot) and writes setup-complete.marker

    Does NOT create Samba test VMs — use New-SambaTestVM.ps1.

.PARAMETER IsoPath
    Path to Windows Server 2025 ISO.

.PARAMETER LabPath
    Root folder for VM files (VHDX, etc.).

.PARAMETER AdminPassword
    Local Administrator password (must satisfy AD complexity).
#>

[CmdletBinding()]
param(
    [string]$IsoPath          = 'D:\ISO\26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso',
    [string]$LabPath          = 'D:\Lab',
    [string]$SwitchName       = 'Lab-NAT',
    [string]$DcVMName         = 'WS2025-DC1',
    [int]   $DcMemoryGB       = 4,
    [int]   $DcVCpu           = 2,
    [int]   $DcDiskGB         = 60,
    [string]$AdminPassword    = 'P@ssword123456!',
    [int]   $WimIndex         = 1,   # 1 = Std Core Eval, 3 = Datacenter Core Eval
    [string]$UnattendTemplate = "$PSScriptRoot\unattend-ws2025-core.xml",
    [string]$FirstLogonScript = "$PSScriptRoot\FirstLogon-PromoteToDC.ps1",
    [string]$StaticMacAddress = '00155D0A0A0A'   # matches dnsmasq reservation
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "    + $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    ! $m" -ForegroundColor Yellow }

# ── 1. SWITCH CHECK ──────────────────────────────────────────────────────────
Write-Step "Lab-NAT switch check"
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Switch '$SwitchName' not found. Run New-LabRouter.ps1 first."
}
Write-OK "Switch '$SwitchName' present"

# ── 2. SKIP IF VM EXISTS ─────────────────────────────────────────────────────
Write-Step "Checking for existing VM: $DcVMName"
if (Get-VM -Name $DcVMName -ErrorAction SilentlyContinue) {
    Write-Warn "VM exists — skipping. To rebuild: Remove-VM $DcVMName -Force"
    exit 0
}

# ── 3. PATHS ─────────────────────────────────────────────────────────────────
Write-Step "Preparing lab directory structure"
$VmFolder = Join-Path $LabPath $DcVMName
$VhdxPath = Join-Path $VmFolder "$DcVMName.vhdx"
foreach ($d in @($LabPath, $VmFolder)) {
    if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
}
Write-OK "Lab path: $LabPath"

# ── 4. MOUNT ISO ─────────────────────────────────────────────────────────────
Write-Step "Mounting Windows Server 2025 ISO"
if (-not (Test-Path $IsoPath)) { throw "ISO not found: $IsoPath" }
$iso = Mount-DiskImage -ImagePath $IsoPath -PassThru
$isoVol = ($iso | Get-Volume).DriveLetter
$wimPath = "${isoVol}:\sources\install.wim"
if (-not (Test-Path $wimPath)) { $wimPath = "${isoVol}:\sources\install.esd" }
if (-not (Test-Path $wimPath)) {
    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    throw "install.wim/esd not found on ISO"
}
Write-OK "ISO mounted at ${isoVol}:"

Write-Host "`n    Images in install.wim:" -ForegroundColor DarkGray
Get-WindowsImage -ImagePath $wimPath | ForEach-Object {
    $marker = if ($_.ImageIndex -eq $WimIndex) { ' <- selected' } else { '' }
    Write-Host "      $($_.ImageIndex): $($_.ImageName)$marker" -ForegroundColor DarkGray
}

# ── 5. VHDX + PARTITIONS + APPLY WIM ─────────────────────────────────────────
Write-Step "Creating VHDX: $VhdxPath"
New-VHD -Path $VhdxPath -SizeBytes ($DcDiskGB * 1GB) -Dynamic | Out-Null
Write-OK "VHDX ($DcDiskGB GB dynamic)"

Write-Step "Mounting VHDX + initializing partitions"
$vhd = Mount-VHD -Path $VhdxPath -PassThru
$disk = Get-Disk -Number $vhd.DiskNumber
Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false
$efiPart = New-Partition -DiskNumber $disk.Number -Size 100MB `
    -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
Format-Volume -Partition $efiPart -FileSystem FAT32 -Force -Confirm:$false | Out-Null
$null    = New-Partition -DiskNumber $disk.Number -Size 16MB `
    -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
$osPart  = New-Partition -DiskNumber $disk.Number -UseMaximumSize `
    -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -AssignDriveLetter
Format-Volume -Partition $osPart -FileSystem NTFS -NewFileSystemLabel 'Windows' `
    -Force -Confirm:$false | Out-Null
$osDrive = ($osPart | Get-Volume).DriveLetter
$efiPart | Add-PartitionAccessPath -AssignDriveLetter
$efiDrive = ($efiPart | Get-Volume).DriveLetter
Write-OK "Partitions: EFI=$efiDrive, OS=$osDrive"

Write-Step "Applying WIM (index $WimIndex)"
Expand-WindowsImage -ImagePath $wimPath -Index $WimIndex -ApplyPath "${osDrive}:\" | Out-Null
bcdboot "${osDrive}:\Windows" /s "${efiDrive}:" /f UEFI | Out-Null
Write-OK "WIM applied, boot files written"

# ── 6. INJECT UNATTEND + FIRSTLOGON ──────────────────────────────────────────
Write-Step "Injecting unattend.xml + FirstLogon script"
$pantherPath = "${osDrive}:\Windows\Panther\Unattend"
$setupPath   = "${osDrive}:\Setup"
New-Item -Path $pantherPath -ItemType Directory -Force | Out-Null
New-Item -Path $setupPath   -ItemType Directory -Force | Out-Null

if (-not (Test-Path $UnattendTemplate)) { throw "Unattend template missing: $UnattendTemplate" }
$unattend = (Get-Content $UnattendTemplate -Raw) `
    -replace '__ADMIN_PASSWORD_PLACEHOLDER__', $AdminPassword
Set-Content -Path "$pantherPath\Unattend.xml" -Value $unattend -Encoding UTF8
Write-OK "Unattend.xml -> $pantherPath"

if (-not (Test-Path $FirstLogonScript)) { throw "FirstLogon script missing: $FirstLogonScript" }
Copy-Item -Path $FirstLogonScript -Destination "$setupPath\FirstLogon-PromoteToDC.ps1"
Write-OK "FirstLogon script -> $setupPath"

# ── 7. DISMOUNT ──────────────────────────────────────────────────────────────
Write-Step "Dismounting VHDX + ISO"
Dismount-VHD -Path $VhdxPath
Dismount-DiskImage -ImagePath $IsoPath | Out-Null
Write-OK "Dismounted"

# ── 8. CREATE GEN2 VM ────────────────────────────────────────────────────────
Write-Step "Creating Hyper-V VM: $DcVMName"
$vm = New-VM -Name $DcVMName `
    -MemoryStartupBytes ($DcMemoryGB * 1GB) `
    -Generation 2 `
    -SwitchName $SwitchName `
    -VHDPath $VhdxPath `
    -Path $LabPath

Set-VMProcessor -VMName $DcVMName -Count $DcVCpu
Set-VMMemory -VMName $DcVMName -DynamicMemoryEnabled $false

# Pin MAC to match the dnsmasq DHCP reservation on router1 for 10.10.10.10
Set-VMNetworkAdapter -VMName $DcVMName -StaticMacAddress $StaticMacAddress
Write-OK "NIC: $SwitchName  MAC=$StaticMacAddress (reservation -> 10.10.10.10)"

# TPM + SecureBoot for Server 2025
$owner = Get-HgsGuardian -Name 'UntrustedGuardian' -ErrorAction SilentlyContinue
if (-not $owner) { $owner = New-HgsGuardian -Name 'UntrustedGuardian' -GenerateCertificates }
$kp = New-HgsKeyProtector -Owner $owner -AllowUntrustedRoot
Set-VMKeyProtector -VMName $DcVMName -KeyProtector $kp.RawData
Enable-VMTPM -VMName $DcVMName
Set-VMFirmware -VMName $DcVMName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'

Enable-VMIntegrationService -VMName $DcVMName -Name 'Guest Service Interface'
Enable-VMIntegrationService -VMName $DcVMName -Name 'Heartbeat'
Enable-VMIntegrationService -VMName $DcVMName -Name 'Time Synchronization'

Write-OK "VM created: Gen2, $DcVCpu vCPU, $DcMemoryGB GB, TPM+SecureBoot"

# ── 9. START ─────────────────────────────────────────────────────────────────
Write-Step "Starting VM"
Start-VM -Name $DcVMName
Write-OK "VM started. Promotion path (FirstLogon Phase 1 -> reboot -> Phase 2"
Write-OK "via RunOnce -> setup-complete.marker) takes ~10-15 min."
Write-Host ""
Write-Host "Monitor via:" -ForegroundColor DarkGray
Write-Host '  pwsh -Command "do { Start-Sleep 30; try {' -ForegroundColor DarkGray
Write-Host '    $c = New-Object PSCredential(\"LAB\Administrator\",' -ForegroundColor DarkGray
Write-Host '      (ConvertTo-SecureString \"P@ssword123456!\" -AsPlainText -Force));' -ForegroundColor DarkGray
Write-Host '    $r = Invoke-Command -VMName WS2025-DC1 -Credential $c -ScriptBlock {' -ForegroundColor DarkGray
Write-Host '      Test-Path C:\Setup\setup-complete.marker } -ErrorAction Stop;' -ForegroundColor DarkGray
Write-Host '    Write-Host ""complete: $r""' -ForegroundColor DarkGray
Write-Host '  } catch { Write-Host still-booting } } while (-not $r)"' -ForegroundColor DarkGray
