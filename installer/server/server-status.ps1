<#
.SYNOPSIS
  Shows whether every part of the CompuLab server is working, one layer at
  a time, so a problem can be placed quickly: Windows services -> website
  -> database -> background worker -> internet / email / cloud -> Tailscale.

.DESCRIPTION
  Run on the server (as Administrator for the full report):
      powershell -ExecutionPolicy Bypass -File installer\server\server-status.ps1
  Changes nothing. Add -StartServices to start stopped CompuLab services.

  Without administrator rights the report is LIMITED and says so: the
  settings file (.env), the firewall rule and the backup task can only be
  read by an administrator; those lines show "needs administrator".
  (Start menu > CompuLab Server Status offers to ask for the rights.)
#>
[CmdletBinding()]
param([switch]$StartServices)

. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = 'Continue'
function Show([string]$Label, $Ok, [string]$Detail) {
    $mark, $color = if ($Ok -eq $true) { 'OK  ', 'Green' } elseif ($Ok -eq $false) { 'FAIL', 'Red' } else { '--  ', 'Yellow' }
    Write-Host ("  [{0}] {1,-28} {2}" -f $mark, $Label, $Detail) -ForegroundColor $color
}

$isAdmin = Test-IsAdmin
$envReadable = $true
try { $values = Read-DotEnv; $port = Get-SitePort } catch { $values = @{}; $port = 8000; $envReadable = $false }
Write-Host "`nCompuLab server status ($env:COMPUTERNAME)" -ForegroundColor Cyan
if (-not $isAdmin) {
    Write-Host '  LIMITED REPORT: not running as administrator. The settings file, the firewall rule and the backup task' -ForegroundColor Yellow
    Write-Host '  are not checked (shown as "needs administrator"). For the full report: Start menu > CompuLab Server Status > F,' -ForegroundColor Yellow
    Write-Host '  or run this script in PowerShell opened with "Run as administrator".' -ForegroundColor Yellow
}
if (-not $envReadable) { Write-Host "  The settings file (.env) could not be read: web port assumed to be $port." -ForegroundColor Yellow }

Write-Host "`n1. Windows services"
# The database service CompuLab Web depends on (set by install-server.ps1).
$db = @((Get-Service $script:WebService -ErrorAction SilentlyContinue).ServicesDependedOn | Where-Object { $_ } | ForEach-Object { $_.Name }) | Select-Object -First 1
if (-not $db) { try { $db = Get-DbServiceName } catch { Show 'Database service' $null $_.Exception.Message } }
if ($db) { $s = Get-Service $db; Show 'Database service' ($s.Status -eq 'Running') "$db is $($s.Status) (start type $($s.StartType))" }
else { Show 'Database service' $null 'No MariaDB/MySQL service found (external database?)' }
foreach ($name in $script:WebService, $script:WorkerService) {
    $svc = Get-Service $name -ErrorAction SilentlyContinue
    if (-not $svc) { Show $name $false 'not installed (run install-server.ps1)'; continue }
    if ($svc.Status -ne 'Running' -and $StartServices) { Start-Service $name -ErrorAction SilentlyContinue; $svc.Refresh() }
    Show $name ($svc.Status -eq 'Running') "$($svc.Status), start type $($svc.StartType)"
}
if ($envReadable -and $values['DB_PORT']) {
    # CompuLab's own database must never be reachable from the network.
    $addresses = Get-ListenerAddresses ([int]$values['DB_PORT'])
    if ($values['COMPULAB_DB_MODE'] -eq 'bundled') {
        $okLocal = Test-LocalOnlyAddresses $addresses
        Show 'Database port' $okLocal $(if (-not $addresses.Count) { "nothing listens on $($values['DB_PORT']): CompuLab's database is not running" } elseif ($okLocal) { "$($values['DB_PORT']) on 127.0.0.1 only (CompuLab's own database, data in data\mariadb)" } else { "$($values['DB_PORT']) is open on $($addresses -join ', '): it should be 127.0.0.1 only (run install-server.ps1 to repair)" })
    } else {
        Show 'Database port' ($addresses.Count -gt 0) "$($values['DB_HOST']):$($values['DB_PORT']) (external MariaDB/MySQL)$(if ($addresses.Count) { ', listening on ' + ($addresses -join ', ') })"
    }
} elseif (-not $envReadable) { Show 'Database port' $null 'needs administrator (settings file)' }

Write-Host "`n2. Website on this computer"
$web = $false
try { $r = Invoke-WebRequest "http://127.0.0.1:$port/healthz" -UseBasicParsing -TimeoutSec 5; $web = ((Get-ResponseText $r).Trim() -eq 'ok') } catch { }
Show "http://127.0.0.1:$port" $web $(if ($web) { 'answers' } else { 'no answer: see logs\compulab.log and logs\CompuLabWeb*.log' })
Show 'Campus address (SITE_URL)' $null $(if ($envReadable) { $values['SITE_URL'] } else { 'needs administrator (settings file)' })
$lanOk = $false
if ($values['SITE_URL']) {
    try { $r = Invoke-WebRequest ($values['SITE_URL'] + '/healthz') -UseBasicParsing -TimeoutSec 5; $lanOk = ((Get-ResponseText $r).Trim() -eq 'ok') } catch { }
    Show 'Campus address answers' $lanOk $(if ($lanOk) { 'lab PCs on the campus network can use it' } else { 'not answering on that address: is this still the server''s IP? (set-server-address.ps1)' })
}
if ($isAdmin) {
    $fw = Get-NetFirewallRule -DisplayName 'CompuLab Web' -ErrorAction SilentlyContinue
    Show 'Firewall rule' ([bool]$fw) $(if ($fw) { "port $port open for campus/VPN addresses" } else { 'missing: lab PCs and staff cannot connect (re-run install-server.ps1)' })
} else { Show 'Firewall rule' $null 'needs administrator' }

Write-Host "`n2b. Backups"
$backup = Get-ConfiguredBackupRoot
Show 'Backup folder' $null "$($backup.Path) (from $($backup.Source))"
if ($isAdmin) {
    $task = Get-ScheduledTask -TaskName $script:BackupTaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo
        $taskRoot = Get-BackupRootFromTaskArguments ([string]$task.Actions[0].Arguments)
        $okRun = $info.LastTaskResult -eq 0 -or $info.LastRunTime -lt [datetime]'2000-01-01'
        Show 'Nightly backup task' $okRun "last run $($info.LastRunTime) result $($info.LastTaskResult); next $($info.NextRunTime)"
        if ($taskRoot -and $taskRoot -ne $backup.Path) { Show 'Task backup folder' $false "the task writes to ${taskRoot}: run install-server.ps1 -BackupRoot `"$($backup.Path)`" to make them agree" }
    } else { Show 'Nightly backup task' $false 'missing (re-run install-server.ps1)' }
} else { Show 'Nightly backup task' $null 'needs administrator' }
$newest = Get-ChildItem -LiteralPath $backup.Path -Directory -Filter 'compulab-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($newest) {
    $age = (Get-Date) - $newest.CreationTime
    Show 'Newest backup' ($age.TotalHours -lt 36) "$($newest.Name) ($([int]$age.TotalHours) hours old)"
} else { Show 'Newest backup' $(if ($isAdmin) { $false } else { $null }) $(if ($isAdmin) { "none in $($backup.Path)" } else { 'none found (the folder may need administrator rights)' }) }

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
