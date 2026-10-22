<#
.SYNOPSIS
  Removes the CompuLab agent from this lab PC (start-up task, firewall
  rules, program files).

.DESCRIPTION
  Kept unless you say otherwise:
    * C:\ProgramData\CompuLab Agent - events still waiting to be sent and the
      last-contact status. If you reinstall later, waiting events (up to 24
      hours old) are sent then. Add -RemoveData to delete it too.
  Add -KeepFiles to keep the program folder (including this PC's
  agent_config.local.json, which holds the agent secret).

  Afterwards, in CompuLab, delete or edit this PC if it is no longer a lab PC.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramFiles\CompuLab Agent",
    [string]$DataDir = "$env:ProgramData\CompuLab Agent",
    [switch]$KeepFiles,
    [switch]$RemoveData
)

. "$PSScriptRoot\agent-common.ps1"
Assert-Admin

$pendingFile = Join-Path $DataDir 'pending_callbacks.json'
$queued = 0
if (Test-Path $pendingFile) { try { $queued = @(Get-Content $pendingFile -Raw | ConvertFrom-Json).Count } catch { } }

Get-ScheduledTask -TaskName 'CompuLab Agent' -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-ScheduledTask -TaskName 'CompuLab Agent' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'CompuLab Agent' -Confirm:$false
}
Stop-Agent $InstallDir
Get-NetFirewallRule -DisplayName 'CompuLab Agent', 'CompuLab ping' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Write-Ok 'Start-up task and firewall rules removed'

if (-not $KeepFiles -and (Test-Path $InstallDir)) {
    # If this script runs from $InstallDir\tools, Windows may keep that folder
    # until the window closes; the note below covers that.
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) { Write-Note "Some files in $InstallDir are in use; delete the folder after a restart." }
    else { Write-Ok "Removed $InstallDir" }
}
if ($RemoveData) {
    Remove-Item $DataDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($queued) { Write-Note "$queued queued event(s) were deleted with the data folder." }
    Write-Ok "Removed $DataDir"
} elseif (Test-Path $DataDir) {
    Write-Ok "Kept $DataDir ($queued queued event(s); delete it with -RemoveData)"
}
Write-Host 'CompuLab agent removed. In CompuLab, delete or edit this PC if it is no longer a lab PC.' -ForegroundColor Green
