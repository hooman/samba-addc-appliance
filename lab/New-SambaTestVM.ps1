#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Create a Debian 13 VM for Samba AD DC testing.

.DESCRIPTION
    Creates a Gen2 VM attached to the Lab-Internal switch, with the Debian
    netinst ISO mounted for manual or preseeded install.

    After install completes manually (or via preseed), run:
      1. scp prepare-image.sh samba-sconfig.sh root@<vm-ip>:/root/
      2. ssh -J nmadmin@__HYPERV_HOST__ root@<vm-ip>
      3. bash /root/prepare-image.sh
      4. Checkpoint-VM -Name <vm-name> -SnapshotName 'after-prepare-image'
      5. Run sconfig tests

.EXAMPLE
    .\New-SambaTestVM.ps1 -VMName samba-dc1 -IPAddress 172.22.0.20
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [string]$DebianIsoPath = 'D:\ISO\debian-13.4.0-amd64-netinst.iso',
    [string]$LabPath       = 'D:\Lab',
    [string]$SwitchName    = 'Lab-Internal',
    [int]   $MemoryGB      = 2,
    [int]   $VCpu          = 2,
    [int]   $DiskGB        = 20,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "    ✓ $m" -ForegroundColor Green }

# Check existing
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    throw "VM '$VMName' already exists. Remove it first: Remove-VM $VMName -Force"
}

if (-not (Test-Path $DebianIsoPath)) { throw "ISO not found: $DebianIsoPath" }
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Switch '$SwitchName' not found. Run New-WS2025Lab.ps1 first."
}

Write-Step "Creating Debian test VM: $VMName"

$VmFolder = Join-Path $LabPath $VMName
$VhdxPath = Join-Path $VmFolder "$VMName.vhdx"
New-Item -Path $VmFolder -ItemType Directory -Force | Out-Null

# Create Gen2 VM (Debian 13 supports UEFI boot)
$vm = New-VM -Name $VMName `
    -MemoryStartupBytes ($MemoryGB * 1GB) `
    -Generation 2 `
    -SwitchName $SwitchName `
    -NewVHDPath $VhdxPath `
    -NewVHDSizeBytes ($DiskGB * 1GB) `
    -Path $LabPath

Set-VMProcessor -VMName $VMName -Count $VCpu
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false

# Attach ISO and set as boot device
Add-VMDvdDrive -VMName $VMName -Path $DebianIsoPath
$dvd = Get-VMDvdDrive -VMName $VMName

# Disable Secure Boot for Debian (Debian supports SB but simpler to disable for lab)
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

# Set boot order: DVD first, then VHDX
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd

# Enable guest services (enables Copy-VMFile to VM)
Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'

Write-OK "VM created"
Write-OK "  vCPU: $VCpu | RAM: $MemoryGB GB | Disk: $DiskGB GB"
Write-OK "  Switch: $SwitchName"
Write-OK "  DVD: $DebianIsoPath"

if ($Start) {
    Write-Step "Starting VM"
    Start-VM -Name $VMName
    Write-OK "Started"
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Connect: vmconnect localhost $VMName"
Write-Host "  2. Install Debian (minimal install, SSH server only, no desktop)"
Write-Host "  3. During install, configure:"
Write-Host "       - hostname: $VMName"
Write-Host "       - static IP on 172.22.0.0/24 (e.g., 172.22.0.20)"
Write-Host "       - gateway: 172.22.0.1 (the Hyper-V host)"
Write-Host "       - DNS: 172.22.0.10 (WS2025 DC)"
Write-Host "  4. After reboot, remove DVD: Set-VMDvdDrive -VMName $VMName -Path `$null"
Write-Host "  5. Copy prepare-image.sh + samba-sconfig.sh via SCP"
Write-Host "  6. Run prepare-image.sh, then checkpoint as 'golden-image'"
