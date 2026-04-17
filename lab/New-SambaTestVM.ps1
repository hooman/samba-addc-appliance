#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Create a Debian 13 VM for Samba AD DC testing (lab-v2 topology).

.DESCRIPTION
    Creates a Gen2 VM attached to the Lab-NAT switch, with the Debian
    netinst ISO mounted for manual install. This version of the lab uses
    a pinned MAC that matches the router1 dnsmasq reservation for the
    target IP — no static IP config is needed at install time.

    Default MAC/IP reservation scheme:
      samba-dc1       00:15:5D:0A:0A:14  ->  10.10.10.20
      samba-dc2       00:15:5D:0A:0A:15  ->  10.10.10.21   (caller-provided)
      samba-dc3       00:15:5D:0A:0A:16  ->  10.10.10.22   (caller-provided)

    After manual install:
      1. Set up `debadmin` with sudo NOPASSWD and SSH authorized_keys at
         install time (see HANDOFF.md v2).
      2. scp prepare-image.sh samba-sconfig.sh debadmin@10.10.10.20:/tmp/
      3. sudo install both to /root/ or /usr/local/sbin respectively
      4. Run sudo bash /root/prepare-image.sh
      5. Shutdown, Checkpoint-VM -Name <vm> -SnapshotName 'golden-image'

.EXAMPLE
    .\New-SambaTestVM.ps1 -VMName samba-dc1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [string]$DebianIsoPath = 'D:\ISO\debian-13.4.0-amd64-netinst.iso',
    [string]$LabPath       = 'D:\Lab',
    [string]$SwitchName    = 'Lab-NAT',
    [int]   $MemoryGB      = 2,
    [int]   $VCpu          = 2,
    [int]   $DiskGB        = 20,
    [string]$StaticMacAddress = '00155D0A0A14',  # matches router1 dnsmasq reservation
    [switch]$Start
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "    + $m" -ForegroundColor Green }

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    throw "VM '$VMName' already exists. Remove it first: Remove-VM $VMName -Force"
}
if (-not (Test-Path $DebianIsoPath)) { throw "ISO not found: $DebianIsoPath" }
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Switch '$SwitchName' not found. Run New-LabRouter.ps1 first."
}

Write-Step "Creating Debian test VM: $VMName on $SwitchName"

$VmFolder = Join-Path $LabPath $VMName
$VhdxPath = Join-Path $VmFolder "$VMName.vhdx"
New-Item -Path $VmFolder -ItemType Directory -Force | Out-Null

$vm = New-VM -Name $VMName `
    -MemoryStartupBytes ($MemoryGB * 1GB) `
    -Generation 2 `
    -SwitchName $SwitchName `
    -NewVHDPath $VhdxPath `
    -NewVHDSizeBytes ($DiskGB * 1GB) `
    -Path $LabPath

Set-VMProcessor -VMName $VMName -Count $VCpu
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false

# Pin MAC for dnsmasq reservation lookup
Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress $StaticMacAddress
Write-OK "MAC pinned: $StaticMacAddress (router1 dnsmasq -> reserved IP)"

Add-VMDvdDrive -VMName $VMName -Path $DebianIsoPath
$dvd = Get-VMDvdDrive -VMName $VMName

Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd

Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'
Enable-VMIntegrationService -VMName $VMName -Name 'Heartbeat'
Enable-VMIntegrationService -VMName $VMName -Name 'Time Synchronization'

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
Write-Host "Next steps for the installer:" -ForegroundColor Yellow
Write-Host "  1. Connect: vmconnect localhost $VMName"
Write-Host "  2. Debian minimal install, SSH server only, no desktop"
Write-Host "  3. During install, configure:"
Write-Host "       - hostname: $VMName"
Write-Host "       - NETWORK: DHCP (no static IP — router1 will reserve one)"
Write-Host "       - root password (remember it — needed once)"
Write-Host "       - debadmin user + strong password"
Write-Host "  4. At the 'software selection' step, choose ONLY 'SSH server' and"
Write-Host "     'standard system utilities' — uncheck everything else"
Write-Host "  5. After install, LOG IN AS ROOT at the console and run:"
Write-Host "       apt update && apt install -y sudo"
Write-Host "       echo 'debadmin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/debadmin"
Write-Host "       chmod 440 /etc/sudoers.d/debadmin"
Write-Host "       # then scp ~/.ssh/id_ed25519.pub from Mac to VM and:"
Write-Host "       sudo -u debadmin mkdir -p /home/debadmin/.ssh && chmod 700 /home/debadmin/.ssh"
Write-Host "       # (then append pubkey to /home/debadmin/.ssh/authorized_keys with right perms)"
Write-Host "  6. Shutdown; remove DVD: Set-VMDvdDrive -VMName $VMName -Path `$null"
Write-Host ""
Write-Host "Then Claude Code can proceed with prepare-image.sh and testing." -ForegroundColor Yellow
