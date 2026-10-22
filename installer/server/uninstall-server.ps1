<#
.SYNOPSIS
  Removes the CompuLab services, firewall rules and backup task from this
  server. Keeps all data.

.DESCRIPTION
  Run as Administrator (or use "Uninstall CompuLab Server.cmd", or
  Settings > Apps > CompuLab Server when it was installed with
  CompuLab-Server-Setup.exe).

  Removed:  the CompuLab Web and CompuLab Worker services, the firewall
            rules "CompuLab Web" and "CompuLab Web (Tailscale)", the
            "CompuLab nightly backup" task, and the Tailscale serve setting
            (only with -RemoveRemoteAccess).
  Kept:     the database (in MariaDB), .env (settings and secrets), media\
            (uploads), backups\, logs\ and the program folder. Running
            install-server.ps1 again brings everything back as it was.

  To remove the data as well, after making a final backup:
    1. installer\server\backup.ps1 -BackupRoot E:\CompuLabFinalBackup
    2. In MariaDB (as root):  DROP DATABASE compulab_db;  DROP USER 'compulab'@'localhost';  DROP USER 'compulab'@'127.0.0.1';
    3. Delete the CompuLab folder.
  This script never does those steps itself.
#>
[CmdletBinding()]
param([switch]$RemoveRemoteAccess, [switch]$Quiet)

. "$PSScriptRoot\common.ps1"
Assert-Admin
if (-not $Quiet) {
    Write-Host 'This removes the CompuLab services, firewall rules and backup task. The database and all files are kept.' -ForegroundColor Yellow
    if ((Read-Host 'Type UNINSTALL to continue') -ne 'UNINSTALL') { Write-Host 'Cancelled.'; return }
}

Write-Step 'Stopping and removing the services'
foreach ($id in $script:WorkerService, $script:WebService) {
    $exe = Join-Path $script:ServiceDir "$id.exe"
    if (Get-Service -Name $id -ErrorAction SilentlyContinue) {
        if (Test-Path $exe) { Invoke-Quiet $exe @('stop') | Out-Null; Invoke-Quiet $exe @('uninstall') | Out-Null }
        else { Stop-Service $id -Force -ErrorAction SilentlyContinue; & sc.exe delete $id | Out-Null }
        Write-Ok "Removed $id"
    }
}

Write-Step 'Removing the firewall rules and the backup task'
Get-NetFirewallRule -DisplayName 'CompuLab Web', 'CompuLab Web (Tailscale)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-ScheduledTask -TaskName $script:BackupTaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
Write-Ok 'Done'

if ($RemoveRemoteAccess) {
    $ts = Find-Tailscale
    if ($ts) { Invoke-Quiet $ts @('serve', 'reset') | Out-Null; Write-Ok 'Tailscale serve setting removed' }
}

Write-Host "`nCompuLab services removed. Data kept in $($script:AppDir) and in the MariaDB database." -ForegroundColor Green
Write-Host '  Reinstall or repair at any time with install-server.ps1 (or CompuLab-Server-Setup.exe).'
