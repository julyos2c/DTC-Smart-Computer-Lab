<#
.SYNOPSIS
  Runs CompuLab in this window (website + background work in one process),
  for a first test or when the Windows services are not installed yet.
  Close the window or press Ctrl+C to stop.
#>
param([int]$Port = 0)
. "$PSScriptRoot\common.ps1"
Set-Location $script:AppDir
if ($Port -le 0) { $Port = Get-SitePort }
$env:COMPULAB_BACKGROUND_TASKS = 'True'
Write-Host "CompuLab on http://0.0.0.0:$Port  (Ctrl+C to stop)" -ForegroundColor Cyan
& (Join-Path $script:AppDir 'venv\Scripts\waitress-serve.exe') "--listen=0.0.0.0:$Port" --threads=8 compulab.wsgi:application
