#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Build the lab's NAT gateway / DHCP / DNS-forwarder VM from a reusable
    Debian generic-cloud VHDX, configured via cloud-init NoCloud seed ISO.

.DESCRIPTION
    The router VM is the lab's link to the outside world. It provides:
      - NAT (nftables) from the Lab-NAT internal switch to an external switch
      - DHCP for the lab subnet (dnsmasq)
      - DNS forwarder to public DNS, with a delegation for `lab.test` to the
        AD DCs (WS2025-DC1 at .10 and samba-dc1 at .20)

    Prerequisites (produced outside Hyper-V, staged onto the host at D:\ISO\):
      - debian-13-router-base.vhdx   — Debian 13 genericcloud, qcow2→VHDX
                                       (qemu-img convert, dynamic subformat)
      - router1-seed.iso             — NoCloud seed (CIDATA label) with the
                                       cloud-init user-data/meta-data/network-config
                                       baked into it.

    Both are generated on the Mac side and copied into /Volumes/ISO (i.e.
    D:\ISO\ on the host). See the repo's README / CLAUDE.md v2 for how.

    This script is idempotent: if the VM already exists it skips creation.

.PARAMETER VMName
    Hyper-V VM name. Default: router1.

.PARAMETER BaseVhdxSource
    Path to the shared read-only base VHDX on the host. Default:
    D:\ISO\debian-13-router-base.vhdx.

.PARAMETER SeedIso
    Path to the NoCloud seed ISO. Default: D:\ISO\router1-seed.iso.

.PARAMETER LabPath
    Root folder for per-VM files (VHDX copy, etc.). Default D:\Lab.

.PARAMETER LanSwitchName
    Name of the internal Hyper-V switch this router's LAN attaches to.
    Created if missing. Default: Lab-NAT.

.PARAMETER WanSwitchName
    Name of the external Hyper-V switch this router's WAN attaches to.
    Must already exist. Default: 'PCI 1G Port 1'.

.PARAMETER LanHostIP / LanHostPrefix
    The Hyper-V HOST vNIC IP on the internal switch (Windows side). Default
    not set — the host does NOT need an IP on this switch for the lab to
    work; the VM is the gateway.

.PARAMETER MemoryMB / VCpu / DiskGB
    VM resource sizing. Defaults: 1024 MB / 1 / 8 (but the base VHDX is
    ~3 GiB already, so this is a floor).

.EXAMPLE
    .\New-LabRouter.ps1

.EXAMPLE
    .\New-LabRouter.ps1 -VMName router2 -SeedIso D:\ISO\router2-seed.iso
#>
[CmdletBinding()]
param(
    [string]$VMName         = 'router1',
    [string]$BaseVhdxSource = 'D:\ISO\debian-13-router-base.vhdx',
    [string]$SeedIso        = 'D:\ISO\router1-seed.iso',
    [string]$LabPath        = 'D:\Lab',
    [string]$LanSwitchName  = 'Lab-NAT',
    [string]$WanSwitchName  = 'PCI 1G Port 1',
    [int]   $MemoryMB       = 1024,
    [int]   $VCpu           = 1,
    [string]$LanMacAddress  = ''     # optional, pinned MAC for deterministic routing
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "    + $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    ! $m" -ForegroundColor Yellow }

# ── 1. SANITY CHECKS ─────────────────────────────────────────────────────────
Write-Step "Sanity checks"
if (-not (Test-Path $BaseVhdxSource)) {
    throw "Base VHDX not found at $BaseVhdxSource. Stage it from the Mac side first."
}
if (-not (Test-Path $SeedIso)) {
    throw "Seed ISO not found at $SeedIso. Generate it first (hdiutil makehybrid -iso -joliet)."
}
if (-not (Get-VMSwitch -Name $WanSwitchName -ErrorAction SilentlyContinue)) {
    throw "WAN switch '$WanSwitchName' not found. Existing external switches: " +
          ((Get-VMSwitch | Where-Object SwitchType -eq 'External').Name -join ', ')
}
Write-OK "Base VHDX: $BaseVhdxSource"
Write-OK "Seed ISO:  $SeedIso"

# ── 2. LAN SWITCH ────────────────────────────────────────────────────────────
Write-Step "LAN switch: $LanSwitchName"
$lanSw = Get-VMSwitch -Name $LanSwitchName -ErrorAction SilentlyContinue
if ($lanSw) {
    Write-OK "Switch exists ($($lanSw.SwitchType))"
} else {
    New-VMSwitch -Name $LanSwitchName -SwitchType Internal | Out-Null
    Write-OK "Created internal switch"
    # Deliberately leave the host vNIC unconfigured — the VM is the sole gateway.
    # Routing host ↔ VM traffic only needs host vNIC up, IP optional.
}

# ── 3. SKIP IF VM ALREADY EXISTS ─────────────────────────────────────────────
Write-Step "Checking for existing VM: $VMName"
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Warn "VM already exists — skipping creation. To rebuild: Remove-VM $VMName -Force"
    exit 0
}

# ── 4. PER-VM FOLDERS + VHDX COPY ────────────────────────────────────────────
Write-Step "Preparing per-VM storage"
$vmFolder = Join-Path $LabPath $VMName
$vhdxDest = Join-Path $vmFolder "$VMName.vhdx"
$isoDest  = Join-Path $vmFolder 'seed.iso'
New-Item -Path $vmFolder -ItemType Directory -Force | Out-Null

Copy-Item -Path $BaseVhdxSource -Destination $vhdxDest -Force
Copy-Item -Path $SeedIso        -Destination $isoDest  -Force
Write-OK "VHDX copied to $vhdxDest ($([math]::Round((Get-Item $vhdxDest).Length / 1MB)) MB)"
Write-OK "Seed ISO copied to $isoDest"

# Base VHDX is 3 GiB — most lab routers won't need more. If the caller set
# a larger disk by touching the file, we respect it; we don't shrink.
# Optional: resize if caller wants. Skipped for simplicity.

# ── 5. CREATE GEN2 VM ────────────────────────────────────────────────────────
Write-Step "Creating VM: $VMName"
$vm = New-VM -Name $VMName `
    -MemoryStartupBytes ($MemoryMB * 1MB) `
    -Generation 2 `
    -SwitchName $WanSwitchName `
    -VHDPath $vhdxDest `
    -Path $LabPath

Set-VMProcessor -VMName $VMName -Count $VCpu
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false

# WAN = primary NIC (already attached via New-VM). Rename for clarity.
Rename-VMNetworkAdapter -VMName $VMName -Name 'Network Adapter' -NewName 'WAN' -ErrorAction SilentlyContinue

# LAN NIC
Add-VMNetworkAdapter -VMName $VMName -Name 'LAN' -SwitchName $LanSwitchName
if ($LanMacAddress) {
    Set-VMNetworkAdapter -VMName $VMName -Name 'LAN' -StaticMacAddress $LanMacAddress
}

# Boot order: VHDX first
$drive = Get-VMHardDiskDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $drive

# SecureBoot OFF — Debian cloud images work with SecureBoot via the MS UEFI CA
# template, but disabling avoids surprises on older Hyper-V hosts.
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

# Attach cloud-init seed ISO (SCSI DVD drive)
Add-VMScsiController -VMName $VMName -ErrorAction SilentlyContinue | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $isoDest

# Hyper-V Integration Services — enable guest-services / heartbeat / time sync
Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'
Enable-VMIntegrationService -VMName $VMName -Name 'Heartbeat'
Enable-VMIntegrationService -VMName $VMName -Name 'Time Synchronization'
Enable-VMIntegrationService -VMName $VMName -Name 'Key-Value Pair Exchange'

Write-OK "VM created: Gen2, $VCpu vCPU, $MemoryMB MB, SecureBoot off"
Write-OK "NICs: WAN=$WanSwitchName  LAN=$LanSwitchName"

# ── 6. START + SHOW STATUS ───────────────────────────────────────────────────
Write-Step "Starting VM"
Start-VM -Name $VMName
Start-Sleep -Seconds 2

Write-OK "Started. Cloud-init will apply config on first boot (~2-3 min)."
Write-Host ""
Write-Host "To monitor first-boot progress:" -ForegroundColor DarkGray
Write-Host "    (Get-VMNetworkAdapter -VMName $VMName -Name LAN).IPAddresses" -ForegroundColor DarkGray
Write-Host "    # wait for IPs to appear, then:" -ForegroundColor DarkGray
Write-Host "    ssh hm@10.10.10.1 'cat /var/log/router-ready.marker'" -ForegroundColor DarkGray
