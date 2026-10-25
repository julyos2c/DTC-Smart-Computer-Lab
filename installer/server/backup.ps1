<#
.SYNOPSIS
  Backs up the CompuLab database, uploaded files and settings.

.DESCRIPTION
  Creates <BackupRoot>\compulab-YYYYMMDD-HHMMSS\ containing:
    database.sql   - full dump (mysqldump --single-transaction, no downtime)
    media.zip      - uploaded avatars and activity-log spreadsheets
    env.txt        - a copy of .env (contains passwords: keep backups private)
  Keeps the newest 14 daily backups plus one per week for 8 weeks.
  Runs every night from the "CompuLab nightly backup" scheduled task
  (install-server.ps1); can also be run by hand at any time ("Back Up
  CompuLab Now" in the Start menu).

  Without -BackupRoot it uses the configured backup folder: COMPULAB_BACKUP_ROOT
  in .env (set by install-server.ps1 -BackupRoot), else the nightly task's
  folder, else C:\CompuLab\backups - so manual and nightly backups go to the
  same place.

  Put BackupRoot on a SECOND disk, USB drive or network share: a backup on
  the same disk is lost together with the disk.

.PARAMETER Log
  Also write everything to logs\backup-<time>.log (the newest 60 are kept)
  and end with exit code 1 on failure. The nightly task uses it, so a
  failed night shows in Task Scheduler ("Last Run Result") and in logs\.
#>
[CmdletBinding()]
param(
    [string]$BackupRoot = '',
    [switch]$Log,
    # The yyyyMMdd-HHmmss part of the new folder's name; default: now. Only
    # for the installer tests (two backups with the same name).
    [string]$Stamp = ''
)

. "$PSScriptRoot\common.ps1"
if ($Log) {
    $logPath = Start-InstallLog 'backup'
    Get-ChildItem (Join-Path $script:AppDir 'logs') -Filter 'backup-*.log' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -Skip 60 | Remove-Item -Force -ErrorAction SilentlyContinue
}
try {
    if (-not $BackupRoot) {
        $configured = Get-ConfiguredBackupRoot
        $BackupRoot = $configured.Path
        Write-Host "Backup folder: $BackupRoot (from $($configured.Source))"
    }
    $rootProblem = Test-BackupRoot $BackupRoot
    if ($rootProblem) { throw $rootProblem }
    $envValues = Read-DotEnv
    # The dump program of the server on DB_PORT (MySQL's mysqldump can fail
    # against MariaDB; MariaDB 11 may only have mariadb-dump.exe).
    $dump = Find-DbClient 'dump' $envValues['DB_PORT'] $envValues['DB_HOST']
    if (-not $dump) { throw 'mysqldump.exe / mariadb-dump.exe not found (is MariaDB/MySQL still installed?).' }

    $stamp = if ($Stamp -match '^\d{8}-\d{6}$') { $Stamp } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
    $target = Join-Path $BackupRoot "compulab-$stamp"
    # Never write into an existing backup (two runs in the same second).
    for ($n = 2; Test-Path -LiteralPath $target; $n++) { $target = Join-Path $BackupRoot "compulab-$stamp-$n" }
    New-Item -ItemType Directory -Path $target | Out-Null

    Write-Step "Backing up to $target"
    $cnf = New-MySqlDefaultsFile $envValues['DB_USER'] $envValues['DB_PASSWORD'] $envValues['DB_HOST'] $envValues['DB_PORT']
    try {
        # --no-tablespaces: MySQL 8.0.21+ otherwise needs the PROCESS privilege,
        # which the CompuLab database user does not have (and does not need).
        & $dump "--defaults-extra-file=$cnf" --single-transaction --routines --triggers --no-tablespaces --default-character-set=utf8mb4 `
            "--result-file=$(Join-Path $target 'database.sql')" $envValues['DB_NAME']
        if ($LASTEXITCODE -ne 0) { throw 'The database dump failed.' }
    } finally {
        Remove-Item $cnf -Force -ErrorAction SilentlyContinue
    }
    Write-Ok 'Database saved'

    $media = Join-Path $script:AppDir 'media'
    if (Test-Path $media) {
        Compress-Archive -Path (Join-Path $media '*') -DestinationPath (Join-Path $target 'media.zip') -Force
        Write-Ok 'Uploaded files saved'
    }
    Copy-Item $script:EnvFile (Join-Path $target 'env.txt')
    & icacls $target /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' "*$(Get-CurrentUserSid):(OI)(CI)F" | Out-Null
    Write-Ok 'Settings saved'

    # Retention: 14 newest + the newest backup of each of the last 8 weeks.
    $all = Get-ChildItem $BackupRoot -Directory -Filter 'compulab-*' | Sort-Object Name -Descending
    $keep = @($all | Select-Object -First 14)
    $weekly = $all | Group-Object { $_.CreationTime.AddDays(-[int]$_.CreationTime.DayOfWeek).ToString('yyyyMMdd') } |
        Select-Object -First 8 | ForEach-Object { $_.Group | Select-Object -First 1 }
    $keep += $weekly
    $keep += Get-Item -LiteralPath $target   # never the backup just made
    foreach ($dir in $all) {
        if ($keep.FullName -notcontains $dir.FullName) { Remove-Item $dir.FullName -Recurse -Force }
    }
    Write-Ok "Done. Backups kept: $(@(Get-ChildItem $BackupRoot -Directory -Filter 'compulab-*').Count)"
    Write-Host "Backup saved in $target" -ForegroundColor Green
    # The newest backup folder, for scripts that call this one (update, restore, tests).
    $target
} catch {
    if (-not $Log) { throw }
    Write-Host "Backup FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($logPath) { Write-Host "  Log: $logPath" }
    Stop-InstallLog
    exit 1
}
if ($Log) { Stop-InstallLog }
