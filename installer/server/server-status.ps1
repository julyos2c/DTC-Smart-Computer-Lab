<#
.SYNOPSIS
  Shows whether every part of the CompuLab server is working, one layer at
  a time, so a problem can be placed quickly: Windows services -> website
  -> database -> background worker -> internet / email / cloud -> Tailscale.

.DESCRIPTION
  Run on the server (as Administrator for the full report):
      powershell -ExecutionPolicy Bypass -File installer\server\server-status.ps1
  Changes nothing. Add -StartServices to start stopped CompuLab services.
#>
[CmdletBinding()]
param([switch]$StartServices)

. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = 'Continue'
function Show([string]$Label, $Ok, [string]$Detail) {
    $mark, $color = if ($Ok -eq $true) { 'OK  ', 'Green' } elseif ($Ok -eq $false) { 'FAIL', 'Red' } else { '--  ', 'Yellow' }
    Write-Host ("  [{0}] {1,-28} {2}" -f $mark, $Label, $Detail) -ForegroundColor $color
}

$port = Get-SitePort
$values = Read-DotEnv
Write-Host "`nCompuLab server status ($env:COMPUTERNAME)" -ForegroundColor Cyan

Write-Host "`n1. Windows services"
$db = Get-DbServiceName
if ($db) { $s = Get-Service $db; Show 'Database service' ($s.Status -eq 'Running') "$db is $($s.Status) (start type $($s.StartType))" }
else { Show 'Database service' $null 'No MariaDB/MySQL service found (external database?)' }
foreach ($name in $script:WebService, $script:WorkerService) {
    $svc = Get-Service $name -ErrorAction SilentlyContinue
    if (-not $svc) { Show $name $false 'not installed (run install-server.ps1)'; continue }
    if ($svc.Status -ne 'Running' -and $StartServices) { Start-Service $name -ErrorAction SilentlyContinue; $svc.Refresh() }
    Show $name ($svc.Status -eq 'Running') "$($svc.Status), start type $($svc.StartType)"
}

Write-Host "`n2. Website on this computer"
$web = $false
try { $r = Invoke-WebRequest "http://127.0.0.1:$port/healthz" -UseBasicParsing -TimeoutSec 5; $web = ((Get-ResponseText $r).Trim() -eq 'ok') } catch { }
Show "http://127.0.0.1:$port" $web $(if ($web) { 'answers' } else { 'no answer: see logs\compulab.log and logs\CompuLabWeb*.log' })
Show 'Campus address (SITE_URL)' $null $values['SITE_URL']
$lanOk = $false
if ($values['SITE_URL']) {
    try { $r = Invoke-WebRequest ($values['SITE_URL'] + '/healthz') -UseBasicParsing -TimeoutSec 5; $lanOk = ((Get-ResponseText $r).Trim() -eq 'ok') } catch { }
    Show 'Campus address answers' $lanOk $(if ($lanOk) { 'lab PCs on the campus network can use it' } else { 'not answering on that address: is this still the server''s IP? (set-server-address.ps1)' })
}
$fw = Get-NetFirewallRule -DisplayName 'CompuLab Web' -ErrorAction SilentlyContinue
Show 'Firewall rule' ([bool]$fw) $(if ($fw) { "port $port open for campus/VPN addresses" } else { 'missing: lab PCs and staff cannot connect (re-run install-server.ps1)' })

Write-Host "`n3. Inside CompuLab (from /healthz/ready)"
if ($web) {
    try {
        $ready = Invoke-RestMethod "http://127.0.0.1:$port/healthz/ready" -TimeoutSec 15
        Write-Host "  $($ready.headline)" -ForegroundColor White
        Show 'Database' $ready.database.ok $ready.database.detail
        Show 'Background worker' ([bool]$ready.worker.alive -and -not $ready.worker.problems) $(if ($ready.worker.alive) { "last cycle $($ready.worker.last_heartbeat) $($ready.worker.problems -join '; ')" } else { 'not running: start the CompuLab Worker service' })
        Show 'Internet' $ready.internet.ok "since $($ready.internet.since)"
        Show 'Email (SMTP)' $(if ($ready.smtp.configured) { $ready.smtp.ok } else { $null }) $(if ($ready.smtp.configured) { "$($ready.email_outbox.waiting) waiting, $($ready.email_outbox.dead) rejected" } else { 'not configured (optional: configure-email.ps1)' })
        if ($ready.cloud.configured) {
            Show 'Cloud receiver' $ready.cloud.ok $ready.cloud.detail
            Show 'Cloud sync queue' ($ready.cloud_sync.failed -eq 0 -and $ready.cloud_sync.conflicts -eq 0 -and -not $ready.cloud_sync.paused) "$($ready.cloud_sync.pending) waiting, $($ready.cloud_sync.failed) failed, $($ready.cloud_sync.conflicts) conflicts, last success $($ready.cloud_sync.last_success)$(if ($ready.cloud_sync.paused) { ", PAUSED ($($ready.cloud_sync.paused))" })"
        } else { Show 'Cloud sync' $null 'not configured (optional)' }
        Show 'Lab PC agents' $null "$($ready.lab_agents.recent) of $($ready.lab_agents.pcs) PCs called in the last 10 min; $($ready.lab_agents.offline) offline; last contact $($ready.lab_agents.last_contact)"
    } catch { Show '/healthz/ready' $false $_.Exception.Message }
} else { Show 'Details' $null 'skipped: the website is not answering' }

Write-Host "`n4. Remote access (Tailscale, optional)"
$remote = $values['COMPULAB_REMOTE_URL']
$ts = Find-Tailscale
if (-not $remote) { Show 'Remote address' $null 'not configured (optional: configure-remote-access.ps1)' }
else { Show 'Remote address' $null $remote }
if ($ts) {
    $self = Get-TailscaleSelf $ts
    if ($self) { Show 'Tailscale' ($self.State -eq 'Running') "$($self.State) as $($self.DnsName) $($self.IPv4)" }
    else { Show 'Tailscale' $false 'installed, but "tailscale status" failed (service stopped?)' }
    if ($remote) {
        $remoteOk = $false
        try { $r = Invoke-WebRequest "$remote/healthz" -UseBasicParsing -TimeoutSec 8; $remoteOk = ((Get-ResponseText $r).Trim() -eq 'ok') } catch { }
        Show 'Remote address answers' $remoteOk $(if ($remoteOk) { 'from this server (test from an outside device too)' } else { 'not from this server: see REMOTE_ACCESS.md, Troubleshooting' })
    }
} elseif ($remote) { Show 'Tailscale' $false 'COMPULAB_REMOTE_URL is set but Tailscale is not installed' }

Write-Host "`nLogs: $(Join-Path $script:AppDir 'logs')   Status page (Admins): $($values['SITE_URL'])/system/status/`n"
