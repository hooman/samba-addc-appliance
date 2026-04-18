<#
.SYNOPSIS
    Stop a VM, restore a named checkpoint, and start it again.

.DESCRIPTION
    Tiny wrapper around Stop-VM / Restore-VMCheckpoint / Start-VM used by
    lab/run-scenario.sh to cycle samba-dc1 back to its 'golden-image'
    checkpoint between test runs. Deliberately does no waiting — the caller
    polls SSH on the VM's IP to determine readiness.

.PARAMETER VMName
    VM to revert. Required.
.PARAMETER Checkpoint
    Checkpoint name to restore. Default 'golden-image'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$VMName,
    [string]$Checkpoint = 'golden-image'
)

$ErrorActionPreference = 'Stop'

$cp = Get-VMCheckpoint -VMName $VMName -Name $Checkpoint -ErrorAction SilentlyContinue
if (-not $cp) {
    throw "Checkpoint '$Checkpoint' not found on VM '$VMName'."
}

Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue
Restore-VMCheckpoint -Name $Checkpoint -VMName $VMName -Confirm:$false
Start-VM -Name $VMName

"Reverted $VMName to '$Checkpoint' and started."
