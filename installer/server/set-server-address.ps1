<#
.SYNOPSIS
  Updates the campus address CompuLab answers on, after the server's IP
  address or name changed.

.DESCRIPTION
  Sets SITE_URL (the campus address used by lab PCs, staff browsers and
  links in emails) and the list of accepted names/addresses, then restarts
  the CompuLab services. The remote (Tailscale) address is separate:
  configure-remote-access.ps1 sets COMPULAB_REMOTE_URL, which CompuLab
  accepts automatically.

.EXAMPLE
  .\set-server-address.ps1                      # use this PC's current LAN addresses
  .\set-server-address.ps1 -Primary 192.168.1.10
  .\set-server-address.ps1 -Primary compulab-server -Extra 192.168.1.10
#>
[CmdletBinding()]
param(
    [string]$Primary = '',
    [string[]]$Extra = @(),
    [int]$Port = 0,
    [switch]$NoRestart
)

. "$PSScriptRoot\common.ps1"
if (-not $NoRestart) { Assert-Admin }
if ($Port -le 0) { $Port = Get-SitePort }
$check = Test-InstallSettings @{ ServerAddress = $Primary; Port = $Port; DbName = 'x'; DbUser = 'x'; DbPort = 3306; AllowFrom = @() }
if ($check.Count) { throw ($check -join ' ') }
$addresses = @(Get-LanAddresses)
if (-not $Primary) { $Primary = if ($addresses.Count) { $addresses[0] } else { '127.0.0.1' } }
$hosts = @('127.0.0.1', 'localhost', $env:COMPUTERNAME.ToLower(), $Primary) + $addresses + $Extra | Select-Object -Unique
$origins = $hosts | ForEach-Object { "http://$($_):$Port" }
Set-DotEnvValue 'DJANGO_ALLOWED_HOSTS' ($hosts -join ',')
Set-DotEnvValue 'DJANGO_CSRF_TRUSTED_ORIGINS' ($origins -join ',')
Set-DotEnvValue 'SITE_URL' "http://$($Primary):$Port"
Set-DotEnvValue 'COMPULAB_PORT' "$Port"
Write-Ok "Campus address: http://$($Primary):$Port"
Write-Ok "Accepted names/addresses: $($hosts -join ', ')"
$remote = (Read-DotEnv)['COMPULAB_REMOTE_URL']
if ($remote) { Write-Ok "Remote address (kept): $remote" }
if (-not $NoRestart) {
    Stop-CompuLabServices
    Start-CompuLabServices
    Write-Note 'Lab PCs use the campus address in their agent settings: run installer\agent\set-agent-server.ps1 on each PC, or re-download its Agent config.'
}
