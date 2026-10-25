<#
.SYNOPSIS
  Runs CompuLab in this window (website + background work in one process),
  for a first test or when the Windows services are not installed yet.
  Close the window or press Ctrl+C to stop.
  With CompuLab's own database (installed with -SkipServices), it starts
  that database first if it is not running (it keeps running afterwards).
#>
param([int]$Port = 0)
. "$PSScriptRoot\common.ps1"
Set-Location $script:AppDir
if ($Port -le 0) { $Port = Get-SitePort }
$values = Read-DotEnv
if ($values['COMPULAB_DB_MODE'] -eq 'bundled' -and -not (Get-OwnService $script:BundledDbService)) {
    Start-BundledDb ([int]$values['DB_PORT']) | Out-Null
    Write-Host "CompuLab's database is running on 127.0.0.1:$($values['DB_PORT'])." -ForegroundColor Cyan
}
$env:COMPULAB_BACKGROUND_TASKS = 'True'
Write-Host "CompuLab on http://0.0.0.0:$Port  (Ctrl+C to stop)" -ForegroundColor Cyan
& (Get-AppPython) -m waitress "--listen=0.0.0.0:$Port" --threads=8 compulab.wsgi:application
