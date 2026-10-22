<#
.SYNOPSIS
  Shows the CompuLab agent's state on this lab PC: server address, last
  successful contact, queued events, and whether the server answers now.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File "C:\Program Files\CompuLab Agent\tools\agent-status.ps1"

.DESCRIPTION
  Changes nothing. "Server unreachable" here is a campus network or server
  problem (cable, Wi-Fi, server switched off, wrong address) - the lab PCs
  never need the internet.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramFiles\CompuLab Agent",
    [string]$DataDir = "$env:ProgramData\CompuLab Agent"
)

. "$PSScriptRoot\agent-common.ps1"
$ErrorActionPreference = 'Continue'
Write-Host "`nCompuLab agent on $env:COMPUTERNAME" -ForegroundColor Cyan

$localConfig = Join-Path $InstallDir 'agent_config.local.json'
$serverUrl = ''
if (Test-Path $localConfig) { $serverUrl = (Read-AgentConfig $localConfig).server_url }
Write-Host "  Server address     : $(if ($serverUrl) { $serverUrl } else { '(not configured)' })"

$task = Get-ScheduledTask -TaskName 'CompuLab Agent' -ErrorAction SilentlyContinue
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName 'CompuLab Agent' -ErrorAction SilentlyContinue
    Write-Host "  Start-up task      : $($task.State) (last run $($info.LastRunTime), result $($info.LastTaskResult))"
} else { Write-Host '  Start-up task      : NOT INSTALLED (run install-agent.ps1)' -ForegroundColor Red }
$running = @(Get-Process pythonw, python, CompuLabAgent -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$InstallDir*" })
Write-Host "  Agent running      : $(if ($running.Count) { 'yes' } else { 'no (it starts when a user signs in to Windows)' })"

$statusFile = Join-Path $DataDir 'agent_status.json'
if (Test-Path $statusFile) {
    $s = Get-Content $statusFile -Raw | ConvertFrom-Json
    Write-Host "  Agent version      : $($s.agent_version)"
    Write-Host "  Last contact       : $(if ($s.last_contact_at) { $s.last_contact_at } else { 'never' })"
    Write-Host "  Last check         : $($s.checked_at) ($(if ($s.server_reachable) { 'server reachable' } else { 'server unreachable' }))"
    if ($s.last_error) { Write-Host "  Last error         : $($s.last_error)" -ForegroundColor Yellow }
} else { Write-Host '  Last contact       : no status recorded yet (agent not started since installing 2.2?)' }

Write-Host "  Queued events      : $(Get-QueuedEventCount $DataDir) (session-end messages waiting for the server to confirm them)"

if ($serverUrl) {
    $check = Test-CompuLabServer $serverUrl
    if ($check.Ok) { Write-Host '  Live check         : server answers' -ForegroundColor Green }
    else { Write-Host "  Live check         : server unreachable - $($check.Detail)" -ForegroundColor Red }
}
$fw = Get-NetFirewallRule -DisplayName 'CompuLab Agent' -ErrorAction SilentlyContinue
Write-Host "  Firewall rule      : $(if ($fw) { 'present' } else { 'MISSING (run set-agent-server.ps1 as Administrator)' })"
Write-Host "  Data folder        : $DataDir`n"
