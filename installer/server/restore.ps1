<#
.SYNOPSIS
  Restores CompuLab from a backup made by backup.ps1.

.DESCRIPTION
  WARNING: replaces the CURRENT database and uploaded files with the
  backup's. Anything recorded after that backup is lost. A safety backup of
  the current state is taken first.

    powershell -ExecutionPolicy Bypass -File installer\server\restore.ps1 -BackupFolder D:\CompuLabBackups\compulab-20261022-013000

  Steps: safety backup -> stop services -> load database.sql -> restore
  media.zip -> start services -> health check. The .env in the backup is
  NOT applied automatically (compare it by hand if this is a new machine).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BackupFolder,
    [string]$SafetyBackupRoot = '',
    # Skip the "type RESTORE" question (for scripted use). The safety backup
    # of the current data is still taken first.
    [switch]$Force
)

. "$PSScriptRoot\common.ps1"
if ((Get-OwnService $script:WebService) -or (Get-OwnService $script:WorkerService)) { Assert-Admin }
$sqlFile = Join-Path $BackupFolder 'database.sql'
if (-not (Test-Path $sqlFile)) { throw "No database.sql in $BackupFolder" }
$dbSettings = Read-DotEnv
$mysql = Find-DbClient 'client' $dbSettings['DB_PORT'] $dbSettings['DB_HOST']
if (-not $mysql) { throw 'mysql.exe / mariadb.exe not found.' }

Write-Host "This replaces the current CompuLab data with the backup from $BackupFolder." -ForegroundColor Yellow
if (-not $Force) {
    $answer = Read-Host 'Type RESTORE to continue'
    if ($answer -ne 'RESTORE') { Write-Host 'Cancelled.'; return }
}

Write-Step 'Safety backup of the current data'
if (-not $SafetyBackupRoot) { $SafetyBackupRoot = Join-Path (Get-ConfiguredBackupRoot).Path 'before-restore' }
& "$PSScriptRoot\backup.ps1" -BackupRoot $SafetyBackupRoot | Out-Null

Stop-CompuLabServices
$envValues = Read-DotEnv
$cnf = New-MySqlDefaultsFile $envValues['DB_USER'] $envValues['DB_PASSWORD'] $envValues['DB_HOST'] $envValues['DB_PORT']
try {
    Write-Step 'Loading the database'
    # Let the client read the file itself: piping through PowerShell 5.1
    # would re-encode it and damage non-ASCII names.
    $sourcePath = (Resolve-Path $sqlFile).Path.Replace('\', '/')
    & $mysql "--defaults-extra-file=$cnf" --default-character-set=utf8mb4 $envValues['DB_NAME'] -e "source $sourcePath"
    if ($LASTEXITCODE -ne 0) { throw 'Loading the database failed. The safety backup is in ' + $SafetyBackupRoot }
    Write-Ok 'Database restored'
} finally {
    Remove-Item $cnf -Force -ErrorAction SilentlyContinue
}

$mediaZip = Join-Path $BackupFolder 'media.zip'
if (Test-Path $mediaZip) {
    Expand-Archive -Path $mediaZip -DestinationPath (Join-Path $script:AppDir 'media') -Force
    Write-Ok 'Uploaded files restored'
}

Write-Step 'Applying any newer database changes'
Invoke-Manage @('migrate', '--noinput')
if (Get-OwnService $script:WebService) {
    Start-CompuLabServices
    if (Wait-Healthy "http://127.0.0.1:$(Get-SitePort)/healthz" 90) { Write-Ok 'CompuLab is running again' }
    else { Write-Note 'CompuLab did not answer yet; check Services and the logs folder.' }
} else { Write-Ok 'Restore complete (no CompuLab services on this computer to restart).' }
