#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Create a Debian 13 cloud-init VM for the Samba AD DC appliance.

.DESCRIPTION
    Builds a Gen2 VM on Lab-NAT from a pre-staged Debian genericcloud
    base VHDX and a per-VM cloud-init seed ISO. Both come from
    lab/stage-samba-base.sh on the Mac.

    The base VHDX is shared across all Samba VMs (read-mostly); each VM
    gets its own differencing disk rooted on the base. That keeps a fresh
    test VM tens of MB on disk until prepare-image.sh writes a lot.

    MAC is pinned so the router1 dnsmasq reservation hands out a fixed
    LAN IP. lab-v2 reservation scheme:

      samba-dc1   00:15:5D:0A:0A:14   10.10.10.20
      samba-dc2   00:15:5D:0A:0A:15   10.10.10.21
      samba-dc3   00:15:5D:0A:0A:16   10.10.10.22

    Replaces the previous netinst-ISO-driven flow that needed a human at
    vmconnect to click through the installer.

.PARAMETER VMName
    Hyper-V VM name. Required.

.PARAMETER BaseVhdxPath
    Path on the Hyper-V host to the staged base VHDX produced by
    stage-samba-base.sh. Default 'D:\ISO\debian-13-samba-base.vhdx'.

.PARAMETER SeedIso
    Path on the Hyper-V host to the per-VM cloud-init seed ISO. Defaults
    to 'D:\ISO\<VMName>-seed.iso' (matches stage-samba-base.sh's output
    naming convention).

.PARAMETER StaticMacAddress
    Pinned NIC MAC, no separators. Default '00155D0A0A14' = samba-dc1.

.EXAMPLE
    .\New-SambaTestVM.ps1 -VMName samba-dc1 -Start

.EXAMPLE
    .\New-SambaTestVM.ps1 -VMName samba-dc2 -StaticMacAddress 00155D0A0A15 -Start
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [string]$BaseVhdxPath     = 'D:\ISO\debian-13-samba-base.vhdx',
    [string]$SeedIso          = '',     # default derived from $VMName below
    [string]$LabPath          = 'D:\Lab',
    [string]$SwitchName       = 'Lab-NAT',
    [int]   $MemoryGB         = 2,
    [int]   $VCpu             = 2,
    [int]   $DiskGB           = 20,
    [string]$StaticMacAddress = '00155D0A0A14',
    [switch]$Start
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "    + $m" -ForegroundColor Green }

if (-not $SeedIso) { $SeedIso = "D:\ISO\${VMName}-seed.iso" }

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    throw "VM '$VMName' already exists. Remove it first: Remove-VM $VMName -Force"
}
if (-not (Test-Path $BaseVhdxPath)) {
    throw "Base VHDX not found: $BaseVhdxPath. Run lab/stage-samba-base.sh on the Mac first."
}
if (-not (Test-Path $SeedIso)) {
    throw "Seed ISO not found: $SeedIso. Run lab/stage-samba-base.sh on the Mac first."
}
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Switch '$SwitchName' not found. Build the lab router first (New-LabRouter.ps1)."
}

Write-Step "Creating Samba test VM: $VMName on $SwitchName"

$VmFolder = Join-Path $LabPath $VMName
New-Item -Path $VmFolder -ItemType Directory -Force | Out-Null

# Differencing VHDX rooted on the shared base. Cheap to create, cheap to
# throw away — perfect for "build a fresh test VM" cycles.
$DiffVhdxPath = Join-Path $VmFolder "$VMName.vhdx"
if (Test-Path $DiffVhdxPath) { Remove-Item -Force $DiffVhdxPath }
New-VHD -Path $DiffVhdxPath -ParentPath $BaseVhdxPath -Differencing | Out-Null

# Resize the differencing virtual size so the guest sees room to grow
# beyond the cloud image's stock 2 GB. The on-disk file stays small until
# the workload writes to it.
Resize-VHD -Path $DiffVhdxPath -SizeBytes ($DiskGB * 1GB)

$null = New-VM -Name $VMName `
    -MemoryStartupBytes ($MemoryGB * 1GB) `
    -Generation 2 `
    -SwitchName $SwitchName `
    -VHDPath $DiffVhdxPath `
    -Path $LabPath

Set-VMProcessor -VMName $VMName -Count $VCpu
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false

Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress $StaticMacAddress
Write-OK "MAC pinned: $StaticMacAddress (router1 dnsmasq -> reserved IP)"

# Mount the cloud-init seed as a DVD. cloud-init's NoCloud datasource
# discovers it by the CIDATA volume label set by stage-samba-base.sh.
Add-VMDvdDrive -VMName $VMName -Path $SeedIso

# Cloud images are signed for normal Debian boot, NOT Microsoft secure
# boot. Disable SecureBoot so the bootloader on the base VHDX can run.
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
Set-VMFirmware -VMName $VMName -FirstBootDevice (Get-VMHardDiskDrive -VMName $VMName)

Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'
Enable-VMIntegrationService -VMName $VMName -Name 'Heartbeat'
Enable-VMIntegrationService -VMName $VMName -Name 'Time Synchronization'

Write-OK "VM created"
Write-OK "  vCPU: $VCpu | RAM: $MemoryGB GB | Disk virt: $DiskGB GB"
Write-OK "  Base: $BaseVhdxPath"
Write-OK "  Diff: $DiffVhdxPath"
Write-OK "  Seed: $SeedIso"

if ($Start) {
    Write-Step "Starting VM"
    Start-VM -Name $VMName
    Write-OK "Started — cloud-init typically takes ~20s; the appliance is reachable"
    Write-OK "via SSH at the dnsmasq-reserved IP for $StaticMacAddress once cloud-init"
    Write-OK "writes /var/log/samba-base-ready.marker."
}
