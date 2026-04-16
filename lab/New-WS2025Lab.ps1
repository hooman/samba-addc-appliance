#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Build the Samba AD DC test lab on Hyper-V.

.DESCRIPTION
    Creates (idempotently):
      1. Hyper-V internal switch "Lab-Internal" with host vNIC at 172.22.0.1/24
      2. WS2025 Server Core DC VM at 172.22.0.10 (lab.test / LAB)
         - Uses DISM to apply install.wim to a VHDX
         - Injects autounattend.xml + FirstLogon script into the VHDX
         - Boots; FirstLogon promotes to DC on first run

    Does NOT create Samba test VMs — use New-SambaTestVM.ps1 for that.
    Does NOT tear down existing infrastructure.

.PARAMETER IsoPath
    Path to Windows Server 2025 ISO.

.PARAMETER LabPath
    Root folder for VM files (VHDX, etc.).

.PARAMETER AdminPassword
    Local Administrator password (must satisfy AD complexity).

.EXAMPLE
    .\New-WS2025Lab.ps1 -IsoPath 'D:\ISO\26100.32230...SERVER_EVAL_x64FRE_en-us.iso'
#>

[CmdletBinding()]
param(
    [string]$IsoPath          = 'D:\ISO\26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso',
    [string]$LabPath          = 'D:\Lab',
    [string]$SwitchName       = 'Lab-Internal',
    [string]$SubnetCIDR       = '172.22.0.0/24',
    [string]$HostIP           = '172.22.0.1',
    [int]   $PrefixLength     = 24,
    [string]$DcVMName         = 'WS2025-DC1',
    [int]   $DcMemoryGB       = 4,
    [int]   $DcVCpu           = 2,
    [int]   $DcDiskGB         = 60,
    [string]$AdminPassword    = 'P@ssword123456!',
    [int]   $WimIndex         = 1,   # 1=Standard Core Eval, 3=Datacenter Core Eval
    [string]$UnattendTemplate = "$PSScriptRoot\unattend-ws2025-core.xml",
    [string]$FirstLogonScript = "$PSScriptRoot\FirstLogon-PromoteToDC.ps1"
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "    ✓ $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    ! $m" -ForegroundColor Yellow }

# ══════════════════════════════════════════════════════════════════════════════
# 1. CREATE INTERNAL SWITCH
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Checking Hyper-V switch: $SwitchName"

$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($switch) {
    Write-OK "Switch exists (Type: $($switch.SwitchType))"
} else {
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Write-OK "Created internal switch"
}

# Configure host vNIC
$hostNic = Get-NetAdapter "vEthernet ($SwitchName)" -ErrorAction SilentlyContinue
if ($hostNic) {
    $existingIp = Get-NetIPAddress -InterfaceIndex $hostNic.ifIndex -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $HostIP }
    if (-not $existingIp) {
        Get-NetIPAddress -InterfaceIndex $hostNic.ifIndex -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false `
            -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $hostNic.ifIndex -IPAddress $HostIP `
            -PrefixLength $PrefixLength | Out-Null
        Write-OK "Host vNIC configured: $HostIP/$PrefixLength"
    } else {
        Write-OK "Host vNIC already has $HostIP"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# 2. PREPARE LAB DIRECTORIES
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Preparing lab directory structure"
$VmFolder  = Join-Path $LabPath $DcVMName
$VhdxPath  = Join-Path $VmFolder "$DcVMName.vhdx"
$WorkDir   = Join-Path $LabPath 'work'

foreach ($d in @($LabPath, $VmFolder, $WorkDir)) {
    if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
}
Write-OK "Lab path: $LabPath"

# ══════════════════════════════════════════════════════════════════════════════
# 3. CHECK IF DC ALREADY EXISTS
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Checking for existing VM: $DcVMName"
$existingVm = Get-VM -Name $DcVMName -ErrorAction SilentlyContinue
if ($existingVm) {
    Write-OK "VM already exists (State: $($existingVm.State))"
    Write-Warn "Skipping VM creation. To rebuild, remove VM first: Remove-VM $DcVMName -Force"
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
# 4. MOUNT ISO AND LOCATE install.wim
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Mounting Windows Server 2025 ISO"
if (-not (Test-Path $IsoPath)) { throw "ISO not found: $IsoPath" }

$iso = Mount-DiskImage -ImagePath $IsoPath -PassThru
$isoVol = ($iso | Get-Volume).DriveLetter
$wimPath = "${isoVol}:\sources\install.wim"

if (-not (Test-Path $wimPath)) {
    # Some ISOs use install.esd
    $wimPath = "${isoVol}:\sources\install.esd"
}
if (-not (Test-Path $wimPath)) {
    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    throw "install.wim/esd not found on ISO"
}
Write-OK "ISO mounted at ${isoVol}: ($wimPath)"

# List images in the WIM for reference
Write-Host "`n    Images in install.wim:" -ForegroundColor DarkGray
Get-WindowsImage -ImagePath $wimPath | ForEach-Object {
    $marker = if ($_.ImageIndex -eq $WimIndex) { ' ← selected' } else { '' }
    Write-Host "      $($_.ImageIndex): $($_.ImageName)$marker" -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════════════════════
# 5. CREATE VHDX AND APPLY WIM
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Creating VHDX: $VhdxPath"
$diskSizeBytes = $DcDiskGB * 1GB
New-VHD -Path $VhdxPath -SizeBytes $diskSizeBytes -Dynamic | Out-Null
Write-OK "VHDX created ($DcDiskGB GB dynamic)"

Write-Step "Mounting VHDX and initializing partitions"
$vhd = Mount-VHD -Path $VhdxPath -PassThru
$disk = Get-Disk -Number $vhd.DiskNumber
Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false
$efiPart = New-Partition -DiskNumber $disk.Number -Size 100MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
Format-Volume -Partition $efiPart -FileSystem FAT32 -Force -Confirm:$false | Out-Null
$msrPart = New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
$osPart  = New-Partition -DiskNumber $disk.Number -UseMaximumSize `
    -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -AssignDriveLetter
Format-Volume -Partition $osPart -FileSystem NTFS -NewFileSystemLabel 'Windows' -Force -Confirm:$false | Out-Null
$osDrive = ($osPart | Get-Volume).DriveLetter

$efiPart | Add-PartitionAccessPath -AssignDriveLetter
$efiDrive = ($efiPart | Get-Volume).DriveLetter
Write-OK "Partitions: EFI=$efiDrive, OS=$osDrive"

Write-Step "Applying WIM (index $WimIndex) — this takes a few minutes"
Expand-WindowsImage -ImagePath $wimPath -Index $WimIndex `
    -ApplyPath "${osDrive}:\" | Out-Null
Write-OK "WIM applied"

Write-Step "Writing BCD boot files"
bcdboot "${osDrive}:\Windows" /s "${efiDrive}:" /f UEFI | Out-Null
Write-OK "Boot files written"

# ══════════════════════════════════════════════════════════════════════════════
# 6. INJECT UNATTEND.XML AND FIRSTLOGON SCRIPT
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Injecting unattend.xml and FirstLogon script"

$pantherPath = "${osDrive}:\Windows\Panther\Unattend"
$setupPath   = "${osDrive}:\Setup"
New-Item -Path $pantherPath -ItemType Directory -Force | Out-Null
New-Item -Path $setupPath   -ItemType Directory -Force | Out-Null

# Load unattend template and substitute password
if (-not (Test-Path $UnattendTemplate)) { throw "Unattend template not found: $UnattendTemplate" }
$unattendContent = Get-Content -Path $UnattendTemplate -Raw
$unattendContent = $unattendContent -replace '__ADMIN_PASSWORD_PLACEHOLDER__', $AdminPassword
Set-Content -Path "$pantherPath\Unattend.xml" -Value $unattendContent -Encoding UTF8
Write-OK "Unattend.xml injected → $pantherPath\Unattend.xml"

# Copy FirstLogon script
if (-not (Test-Path $FirstLogonScript)) { throw "FirstLogon script not found: $FirstLogonScript" }
Copy-Item -Path $FirstLogonScript -Destination "$setupPath\FirstLogon-PromoteToDC.ps1"
Write-OK "FirstLogon script copied → $setupPath\FirstLogon-PromoteToDC.ps1"

# ══════════════════════════════════════════════════════════════════════════════
# 7. DISMOUNT VHDX AND ISO
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Dismounting VHDX and ISO"
Dismount-VHD -Path $VhdxPath
Dismount-DiskImage -ImagePath $IsoPath | Out-Null
Write-OK "Dismounted"

# ══════════════════════════════════════════════════════════════════════════════
# 8. CREATE VM (Gen2)
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Creating Hyper-V VM: $DcVMName"

$vm = New-VM -Name $DcVMName `
    -MemoryStartupBytes ($DcMemoryGB * 1GB) `
    -Generation 2 `
    -SwitchName $SwitchName `
    -VHDPath $VhdxPath `
    -Path $LabPath

Set-VMProcessor -VMName $DcVMName -Count $DcVCpu
Set-VMMemory -VMName $DcVMName -DynamicMemoryEnabled $false

# Enable TPM and Secure Boot for Gen2 (Server 2025 friendly)
$owner = Get-HgsGuardian -Name 'UntrustedGuardian' -ErrorAction SilentlyContinue
if (-not $owner) {
    $owner = New-HgsGuardian -Name 'UntrustedGuardian' -GenerateCertificates
}
$kp = New-HgsKeyProtector -Owner $owner -AllowUntrustedRoot
Set-VMKeyProtector -VMName $DcVMName -KeyProtector $kp.RawData
Enable-VMTPM -VMName $DcVMName

Set-VMFirmware -VMName $DcVMName -EnableSecureBoot On `
    -SecureBootTemplate 'MicrosoftWindows'

# Enable guest services (for Copy-VMFile etc.)
Enable-VMIntegrationService -VMName $DcVMName -Name 'Guest Service Interface'

Write-OK "VM created: $DcVCpu vCPU, $DcMemoryGB GB RAM, TPM+SecureBoot enabled"

# ══════════════════════════════════════════════════════════════════════════════
# 9. START VM
# ══════════════════════════════════════════════════════════════════════════════
Write-Step "Starting VM — initial boot will take ~5-10 minutes for specialize pass"
Start-VM -Name $DcVMName
Write-OK "VM started"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Lab build complete. Monitor progress with:                  ║" -ForegroundColor Green
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "║    vmconnect localhost $DcVMName                             ║" -ForegroundColor Green
Write-Host "║    (or) Get-VM $DcVMName | Format-List State,Uptime          ║" -ForegroundColor Green
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "║  Once 'C:\Setup\setup-complete.marker' exists on the VM,    ║" -ForegroundColor Green
Write-Host "║  the DC is ready. Check via PowerShell Direct:               ║" -ForegroundColor Green
Write-Host "║                                                              ║" -ForegroundColor Green
Write-Host "║    Invoke-Command -VMName $DcVMName -Credential LAB\Administrator {" -ForegroundColor Green
Write-Host "║      Test-Path C:\Setup\setup-complete.marker                ║" -ForegroundColor Green
Write-Host "║    }                                                         ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
