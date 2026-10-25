<#
.SYNOPSIS
  Removes the CompuLab services, firewall rules and backup task from this
  server. Keeps all data.

.DESCRIPTION
  Run as Administrator (or use "Uninstall CompuLab Server.cmd", or
  Settings > Apps > CompuLab Server when it was installed with
  CompuLab-Server-Setup.exe).

  Removed:  the CompuLab Web and CompuLab Worker services, the
            CompuLabMariaDB service (CompuLab's own database server; it is
            stopped cleanly first), the firewall rules "CompuLab Web" and
            "CompuLab Web (Tailscale)", the "CompuLab nightly backup" task,
            and the Tailscale serve setting (only with -RemoveRemoteAccess).
  Kept:     the database (data\mariadb with data\db-admin.cnf, or the
            external MariaDB), .env (settings and secrets), media\ (uploads),
            backups\, logs\ and the program folder. Running install-server.ps1
            again (or the setup) brings everything back as it was.

  To remove the data as well, after making a final backup:
    1. installer\server\backup.ps1 -BackupRoot E:\CompuLabFinalBackup
    2. CompuLab's own database: delete the data\ folder. An external MariaDB
       (as root):  DROP DATABASE compulab_db;  DROP USER 'compulab'@'localhost';  DROP USER 'compulab'@'127.0.0.1';
    3. Delete the CompuLab folder.
  This script never does those steps itself, and never touches any other
  database on this computer.
#>
[CmdletBinding()]
param([switch]$RemoveRemoteAccess, [switch]$Quiet)

. "$PSScriptRoot\common.ps1"
# Only this folder's services count (names are global; another CompuLab
# installation's services are never removed from here).
$installedServices = @($script:WebService, $script:WorkerService, $script:BundledDbService | Where-Object { Get-OwnService $_ })
if (-not (Test-IsAdmin) -and -not $installedServices.Count) {
    # An installation without Windows services (-SkipServices, e.g. a test):
    # only CompuLab's own database process needs stopping, so its files can
    # be removed. Its data is kept.
    Stop-BundledDb
    Write-Ok 'No CompuLab services to remove; CompuLab''s database process (if any) stopped. Data kept.'
    return
}
Assert-Admin
if (-not $Quiet) {
    Write-Host 'This removes the CompuLab services, firewall rules and backup task. The database and all files are kept.' -ForegroundColor Yellow
    if ((Read-Host 'Type UNINSTALL to continue') -ne 'UNINSTALL') { Write-Host 'Cancelled.'; return }
}

Write-Step 'Stopping and removing the services'
foreach ($id in $script:WorkerService, $script:WebService) {
    $exe = Join-Path $script:ServiceDir "$id.exe"
    if (Get-OwnService $id) {
        if (Test-Path $exe) { Invoke-Quiet $exe @('stop') | Out-Null; Invoke-Quiet $exe @('uninstall') | Out-Null }
        else { Stop-Service $id -Force -ErrorAction SilentlyContinue; & sc.exe delete $id | Out-Null }
        Write-Ok "Removed $id"
    }
}
# CompuLab's own database: stopped cleanly (its data stays in data\mariadb),
# then its service removed. Other databases are never touched.
Stop-BundledDb
if (Get-OwnService $script:BundledDbService) {
    Invoke-Quiet 'sc.exe' @('delete', $script:BundledDbService) | Out-Null
    Write-Ok "Removed $($script:BundledDbService) (its data is kept in $($script:BundledDbData))"
}

Write-Step 'Removing the firewall rules and the backup task'
Get-NetFirewallRule -DisplayName 'CompuLab Web', 'CompuLab Web (Tailscale)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-ScheduledTask -TaskName $script:BackupTaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
Write-Ok 'Done'

if ($RemoveRemoteAccess) {
    $ts = Find-Tailscale
    if ($ts) { Invoke-Quiet $ts @('serve', 'reset') | Out-Null; Write-Ok 'Tailscale serve setting removed' }
}

Write-Host "`nCompuLab services removed. Data kept in $($script:AppDir) (and in the external MariaDB, if one was used)." -ForegroundColor Green
Write-Host '  Reinstall or repair at any time with install-server.ps1 (or CompuLab-Server-Setup.exe).'
