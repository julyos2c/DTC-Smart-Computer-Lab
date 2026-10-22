<#
.SYNOPSIS
  Shows or changes the CompuLab server address this lab PC's agent uses.

.EXAMPLE
  # Show the current address and whether it answers:
  powershell -ExecutionPolicy Bypass -File "C:\Program Files\CompuLab Agent\tools\set-agent-server.ps1"
  # Change it (as Administrator):
  powershell -ExecutionPolicy Bypass -File "C:\Program Files\CompuLab Agent\tools\set-agent-server.ps1" -ServerUrl http://192.168.1.10:8000

.DESCRIPTION
  Changing the address keeps the agent secret and every other setting,
  updates the firewall rules to the new server's IP, and restarts the
  agent. Events still waiting on this PC are kept and sent to the new
  address.
#>
[CmdletBinding()]
param(
    [string]$ServerUrl = '',
    [string]$InstallDir = "$env:ProgramFiles\CompuLab Agent",
    [int]$AgentPort = 5555,
    [switch]$Force   # save even if the new address does not answer right now
)

. "$PSScriptRoot\agent-common.ps1"
$localConfig = Join-Path $InstallDir 'agent_config.local.json'
if (-not (Test-Path $localConfig)) { throw "No agent settings at $localConfig. Install the agent first (install-agent.ps1)." }
$config = Read-AgentConfig $localConfig
Write-Host "Current server address: $($config.server_url)"

if (-not $ServerUrl) {
    $check = Test-CompuLabServer $config.server_url
    if ($check.Ok) { Write-Ok 'It answers.' } else { Write-Note "It does not answer: $($check.Detail)" }
    return
}

Assert-Admin
$ServerUrl = Test-ServerUrlFormat $ServerUrl
$check = Test-CompuLabServer $ServerUrl
if ($check.Ok) { Write-Ok "$ServerUrl answers" }
elseif (-not $Force) { throw "$ServerUrl does not answer ($($check.Detail)). Check the address, or add -Force to save it anyway." }
else { Write-Note "$ServerUrl does not answer right now; saved anyway (-Force). The agent keeps trying." }

Set-AgentServerUrl $localConfig $ServerUrl
Protect-AgentConfig $localConfig
Write-Ok "Saved: $ServerUrl"
Set-AgentFirewall $ServerUrl $AgentPort

Stop-Agent $InstallDir
$task = Get-ScheduledTask -TaskName 'CompuLab Agent' -ErrorAction SilentlyContinue
if ($task) { Start-ScheduledTask -TaskName 'CompuLab Agent' -ErrorAction SilentlyContinue }
Write-Note 'The agent restarts with the new address now, or at the next Windows sign-in if no one is signed in.'
