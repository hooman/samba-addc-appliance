<#
.SYNOPSIS
    Verify an additional-DC join from the WS2025-DC1 perspective.

.DESCRIPTION
    Runs PSDirect into WS2025-DC1 and reports, per check, one of:
      OK    — check passed
      WARN  — inconclusive but not a hard failure
      FAIL  — scenario verify() should treat this as failing

    Checks:
      - PTR record for the new DC's IP in the /24 reverse zone
      - DC A record in the forward zone
      - NTDSA (Sites\Servers\<hostname>) object
      - replication partners reference the new DC
      - repadmin /showrepl /errorsonly reports no errors

    Lines are printed one per check, parseable by grep '^FAIL'.

.PARAMETER SambaIP
    IPv4 address of the newly-joined DC (e.g. 10.10.10.20). Required.
.PARAMETER SambaHostname
    Short hostname of the new DC. Default 'samba-dc1'.
.PARAMETER Realm
    AD realm DNS root. Default 'lab.test'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$SambaIP,
    [string]$SambaHostname = 'samba-dc1',
    [string]$Realm         = 'lab.test',
    [string]$VMName        = 'WS2025-DC1',
    [string]$Username      = 'LAB\Administrator',
    [string]$PasswordPlain = 'P@ssword123456!'
)

$ErrorActionPreference = 'Stop'

$cred = New-Object PSCredential(
    $Username,
    (ConvertTo-SecureString $PasswordPlain -AsPlainText -Force))

$inside = {
    param([string]$SambaIP, [string]$SambaHostname, [string]$Realm)

    $ErrorActionPreference = 'Continue'
    $findings = @()

    $octets  = $SambaIP -split '\.'
    $revZone = "$($octets[2]).$($octets[1]).$($octets[0]).in-addr.arpa"
    $revHost = $octets[3]
    $fqdn    = "$SambaHostname.$Realm"

    # PTR
    $ptr = Get-DnsServerResourceRecord -ZoneName $revZone -RRType PTR -ErrorAction SilentlyContinue |
        Where-Object { $_.HostName -eq $revHost }
    if ($ptr) {
        $findings += "OK    PTR $revHost.$revZone -> $($ptr.RecordData.PtrDomainName)"
    } else {
        $findings += "FAIL  PTR missing for $SambaIP in $revZone"
    }

    # Forward A
    $a = Get-DnsServerResourceRecord -ZoneName $Realm -RRType A -ErrorAction SilentlyContinue |
        Where-Object { $_.HostName -ieq $SambaHostname }
    if ($a) {
        $findings += "OK    A $fqdn -> $($a.RecordData.IPv4Address)"
    } else {
        $findings += "FAIL  A record missing for $fqdn"
    }

    # NTDSA
    $confRoot = (Get-ADRootDSE).configurationNamingContext
    $srv = Get-ADObject -SearchBase "CN=Sites,$confRoot" -Filter "Name -eq '$SambaHostname'" `
        -ErrorAction SilentlyContinue
    if ($srv) {
        $findings += "OK    Sites\Servers entry present: $($srv.DistinguishedName)"
    } else {
        $findings += "FAIL  no Sites\Servers\$SambaHostname (NTDSA missing)"
    }

    # Replication partners
    $reps = repadmin /showrepl /csv 2>$null
    if ($reps -and ($reps | Select-String -Pattern $SambaHostname -Quiet)) {
        $findings += "OK    replication topology references $SambaHostname"
    } else {
        $findings += "WARN  no replication link references $SambaHostname yet"
    }

    # Replication errors
    $errs = (repadmin /showrepl /errorsonly 2>&1 | Out-String).Trim()
    if ($errs -and ($errs -match '\b8524\b|failed|error')) {
        $findings += "FAIL  replication errors:"
        foreach ($line in ($errs -split "`r?`n")) {
            if ($line) { $findings += "        $line" }
        }
    } else {
        $findings += "OK    no replication errors"
    }

    $findings -join "`n"
}

Invoke-Command -VMName $VMName -Credential $cred `
    -ArgumentList $SambaIP, $SambaHostname, $Realm -ScriptBlock $inside
