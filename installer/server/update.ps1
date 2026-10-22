<#
.SYNOPSIS
  Updates CompuLab to a new version on this server.

.DESCRIPTION
  1. Replace the application files with the new version first:
       - with Git:  git pull   (in the CompuLab folder), or
       - by copying the new release folder over this one, keeping .env,
         media\, logs\, backups\, venv\ and service\.
  2. Then run, as Administrator:
       powershell -ExecutionPolicy Bypass -File installer\server\update.ps1

  It backs up, stops the services, installs any new packages, shows and
  applies database migrations, collects static files, starts the services
  and checks health. If the site does not come back, restore the backup it
  just made with restore.ps1.
#>
[CmdletBinding()]
param([string]$BackupRoot = '')

. "$PSScriptRoot\common.ps1"
Assert-Admin
if (-not $BackupRoot) { $BackupRoot = Join-Path $script:AppDir 'backups' }

Write-Step 'Backup before updating'
& "$PSScriptRoot\backup.ps1" -BackupRoot $BackupRoot

Stop-CompuLabServices
Write-Step 'Installing packages'
& $script:VenvPython -m pip install --disable-pip-version-check -r (Join-Path $PSScriptRoot 'requirements-server.txt')
if ($LASTEXITCODE -ne 0) { throw 'Package installation failed; services left stopped. Fix the error or restore the backup.' }

Write-Step 'Database changes in this update'
Invoke-Manage @('migrate', '--plan')
Invoke-Manage @('migrate', '--noinput')
Invoke-Manage @('collectstatic', '--noinput')
Invoke-Manage @('check')

Start-CompuLabServices
$port = Get-SitePort
if (Wait-Healthy "http://127.0.0.1:$port/healthz" 90) { Write-Ok 'Update complete - CompuLab is running' }
else {
    Write-Note 'CompuLab did not come back. Check logs\. To roll back: restore the code (git checkout <previous tag>)'
    Write-Note "and, only if the database changes must be undone, run restore.ps1 with the backup in $BackupRoot."
}
