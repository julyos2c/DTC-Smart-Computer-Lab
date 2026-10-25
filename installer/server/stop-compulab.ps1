<#
.SYNOPSIS
  Stops CompuLab cleanly on this server: the CompuLab Worker and CompuLab Web
  services, then CompuLab's own database (its service, or its background
  process when CompuLab was installed without services). Other databases on
  this computer are never stopped.

.DESCRIPTION
  CompuLab-Server-Setup.exe runs this before it replaces the program files
  (update / repair). By hand, as Administrator:
      powershell -ExecutionPolicy Bypass -File installer\server\stop-compulab.ps1
  Start everything again with install-server.ps1 (Repair) or by restarting
  the computer.
#>
[CmdletBinding()]
param([switch]$Quiet)

. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = 'Continue'
try {
    Stop-CompuLabServices
    $hadDb = (Get-OwnService $script:BundledDbService) -or @(Get-BundledDbProcess).Count
    Stop-BundledDb
    if ($hadDb) { Write-Ok "CompuLab's database stopped" }
    exit 0
} catch {
    if (-not $Quiet) { Write-Host "Could not stop everything: $($_.Exception.Message)" -ForegroundColor Red }
    exit 1
}
