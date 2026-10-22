<#
.SYNOPSIS
  Puts a "CompuLab" shortcut on a staff computer's desktop.

.EXAMPLE
  .\install-launcher.ps1 -LanUrl http://192.168.1.10:8000
  .\install-launcher.ps1 -LanUrl http://192.168.1.10:8000 -RemoteUrl http://100.64.0.10:8000

  The shortcut checks which address answers (campus first, then the VPN
  address for staff working from outside) and opens it in the default
  browser. No administrator rights needed; installs for the current user.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LanUrl,
    [string]$RemoteUrl = ''
)
$ErrorActionPreference = 'Stop'
$target = Join-Path $env:LOCALAPPDATA 'CompuLab Launcher'
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'compulab-launcher.ps1') $target -Force
@{ lan_url = $LanUrl.TrimEnd('/'); remote_url = $RemoteUrl.TrimEnd('/') } | ConvertTo-Json |
    Set-Content -Path (Join-Path $target 'launcher.json') -Encoding UTF8

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'CompuLab.lnk'))
$shortcut.TargetPath = 'powershell.exe'
$shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$target\compulab-launcher.ps1`""
$shortcut.WorkingDirectory = $target
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
$shortcut.Description = 'Open CompuLab'
$shortcut.Save()
Write-Host 'Desktop shortcut "CompuLab" created.' -ForegroundColor Green
