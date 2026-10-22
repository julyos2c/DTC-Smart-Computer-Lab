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
  (install-server.ps1); can also be run by hand at any time.

  Put BackupRoot on a SECOND disk, USB drive or network share: a backup on
  the same disk is lost together with the disk.
#>
[CmdletBinding()]
param(
    [string]$BackupRoot = ''
)

. "$PSScriptRoot\common.ps1"
if (-not $BackupRoot) { $BackupRoot = Join-Path $script:AppDir 'backups' }
$envValues = Read-DotEnv
$dump = Find-MySqlTool 'mysqldump.exe'
if (-not $dump) { $dump = Find-MySqlTool 'mariadb-dump.exe' }
if (-not $dump) { throw 'mysqldump.exe / mariadb-dump.exe not found.' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$target = Join-Path $BackupRoot "compulab-$stamp"
New-Item -ItemType Directory -Force -Path $target | Out-Null

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
foreach ($dir in $all) {
    if ($keep.FullName -notcontains $dir.FullName) { Remove-Item $dir.FullName -Recurse -Force }
}
Write-Ok "Done. Backups kept: $(@(Get-ChildItem $BackupRoot -Directory -Filter 'compulab-*').Count)"
# The newest backup folder, for scripts that call this one (update, restore, tests).
$target
