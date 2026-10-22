<#
.SYNOPSIS
  Installs (or upgrades) the CompuLab server on this Windows computer.

.DESCRIPTION
  Run once on the dedicated CompuLab server, as Administrator, from the
  CompuLab folder:

      powershell -ExecutionPolicy Bypass -File installer\server\install-server.ps1

  It is safe to run again: existing settings (.env), the database and
  uploaded files are kept; it only adds what is missing and applies new
  database migrations (after taking a backup).

  What it does:
    1. Checks Windows, PowerShell, the CompuLab files, Python and the
       database server (MariaDB 10.5+ / MySQL 8.0.11+; MariaDB 10.11 or 11.4
       LTS recommended). Stops with a clear message if something is missing.
    2. Creates the Python environment (venv) and installs the packages.
    3. Asks for this server's campus address and writes .env with random
       secrets (first run only; -ServerAddress / -Port change it later).
    4. Creates the database and a dedicated database user (first run only).
    5. Backs up (on upgrade), applies migrations, collects static files.
    6. Creates the first Administrator account (first run only, interactive).
    7. Installs two Windows services that start automatically at boot and
       restart themselves if they stop:
         CompuLab Web     - the website (waitress)
         CompuLab Worker  - background work: PC status, email, cloud sync, jobs
    8. Opens the web port in Windows Firewall for private (campus / VPN)
       addresses only.
    9. Schedules a nightly backup.
   10. Checks that the site answers, then prints the addresses to use.

  Works without internet, email, Tailscale or cloud credentials: those are
  optional and configured later (configure-email.ps1,
  configure-remote-access.ps1, CLOUD_* in .env).

  Things you must provide (see installer\server\README.md):
    * Python 3.11 or newer, installed "for all users" with "Add to PATH".
    * MariaDB (or MySQL 8) installed as a Windows service, and its root password.
    * WinSW-x64.exe saved in installer\server\bin\ (the service wrapper).
    * Internet access the first time (to download the Python packages).

.PARAMETER ServerAddress
  The campus IP address or DNS name lab PCs and staff use to reach this
  server (e.g. 192.168.1.10). Asked for on the first run if not given.

.PARAMETER RemoteUrl
  Optional remote (Tailscale) address, e.g. https://compulab.tailnet-name.ts.net.
  Normally set by configure-remote-access.ps1 instead.
#>
[CmdletBinding()]
param(
    [string]$ServerAddress = '',
    [int]$Port = 0,
    [string]$RemoteUrl = '',
    [string]$DbName = 'compulab_db',
    [string]$DbUser = 'compulab',
    [string]$DbHost = '127.0.0.1',
    [string]$DbPort = '3306',
    [string]$BackupRoot = '',
    # Who may open the web port. Default: private (RFC 1918) campus
    # addresses and Tailscale's 100.64.0.0/10. Never the whole internet.
    [string[]]$AllowFrom = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10'),
    [switch]$SkipDatabaseSetup,
    [switch]$SkipServices,
    [switch]$SkipFirewall,
    [switch]$SkipBackupTask
)

. "$PSScriptRoot\common.ps1"
Assert-Admin
Set-Location $script:AppDir
if (-not $BackupRoot) { $BackupRoot = Join-Path $script:AppDir 'backups' }
$firstRun = -not (Test-Path $script:EnvFile)

# ---------------------------------------------------------------- 1. prerequisites
Write-Step 'Checking Windows and the CompuLab files'
$os = [Environment]::OSVersion.Version
if ($os.Major -lt 10) { throw "Windows 10, Windows 11 or Windows Server 2016+ is required (this is Windows $os)." }
if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows is required.' }
if ($PSVersionTable.PSVersion -lt [version]'5.1') { throw "Windows PowerShell 5.1 is required (this is $($PSVersionTable.PSVersion))." }
$caption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
Write-Ok "$caption ($os), PowerShell $($PSVersionTable.PSVersion)"
$required = @('manage.py', 'compulab\settings.py', 'requirements-production.txt', 'installer\server\requirements-server.txt',
              'static\vendor\chartjs\chart.umd.min.js', 'static\vendor\fullcalendar\index.global.min.js',
              'static\vendor\sweetalert2\sweetalert2.all.min.js', 'lab_pc_agent\agent.py')
$missing = @($required | Where-Object { -not (Test-Path (Join-Path $script:AppDir $_)) })
if ($missing.Count) { throw "These CompuLab files are missing (incomplete copy?): $($missing -join ', ')" }
Write-Ok 'Application files present (including the offline copies of the page scripts)'

Write-Step 'Checking Python'
$python = $null
foreach ($candidate in @('py -3.13', 'py -3.12', 'py -3.11', 'python')) {
    $parts = $candidate.Split(' ')
    try {
        $version = & $parts[0] @($parts[1..($parts.Count)] | Where-Object { $_ }) -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>$null
        if ($LASTEXITCODE -eq 0 -and [version]$version -ge [version]'3.11') { $python = $parts; break }
    } catch { }
}
if (-not $python) { throw 'Python 3.11 or newer was not found. Install it from python.org ("Install for all users", "Add python.exe to PATH") and run this again.' }
Write-Ok "Python $version"

Write-Step 'Checking the database server'
$mysql = Find-MySqlTool 'mysql.exe'
if (-not $mysql) { $mysql = Find-MySqlTool 'mariadb.exe' }
if (-not $mysql -and -not $SkipDatabaseSetup) {
    throw 'The MariaDB/MySQL client (mysql.exe) was not found. Install MariaDB 10.11 or 11.4 LTS (as a Windows service) and run this again, or use -SkipDatabaseSetup if the database already exists.'
}
if ($mysql) { Write-Ok "Database client: $mysql" }
$dbService = Get-DbServiceName
if ($dbService) {
    $svc = Get-Service $dbService
    if ($svc.Status -ne 'Running') { Start-Service $dbService; Write-Ok "Started the $dbService service" } else { Write-Ok "Database service: $dbService (running)" }
    Set-Service $dbService -StartupType Automatic
} elseif ($DbHost -in @('127.0.0.1', 'localhost')) {
    Write-Note 'No MariaDB/MySQL Windows service was found. The database must start automatically at boot, or CompuLab will not start after a restart.'
}

if (-not $SkipServices) {
    Write-Step 'Checking the service wrapper (WinSW)'
    $winsw = Get-WinSWExe
    if (-not $winsw) {
        throw ('WinSW-x64.exe was not found in installer\server\bin\. It is needed so CompuLab starts automatically after a restart. ' +
               'Download it from github.com/winsw/winsw/releases (file WinSW-x64.exe), save it in installer\server\bin\, and run this again. ' +
               '(To install without services, add -SkipServices and start CompuLab by hand with run-foreground.ps1.)')
    }
    Write-Ok "WinSW: $(Test-WinSWExe $winsw)"
}

# ---------------------------------------------------------------- 2. venv + packages
Write-Step 'Installing the Python environment'
if (-not (Test-Path $script:VenvPython)) {
    & $python[0] @($python[1..($python.Count)] | Where-Object { $_ }) -m venv (Join-Path $script:AppDir 'venv')
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the Python environment (venv).' }
}
& $script:VenvPython -m pip install --upgrade pip --disable-pip-version-check | Out-Null
& $script:VenvPython -m pip install --disable-pip-version-check -r (Join-Path $PSScriptRoot 'requirements-server.txt')
if ($LASTEXITCODE -ne 0) {
    throw 'Installing packages failed. This step needs internet access the first time (or a local wheel folder: see README.md).'
}
Write-Ok 'Packages installed'

# ---------------------------------------------------------------- 3. .env
Write-Step 'Configuring settings (.env)'
$addresses = @(Get-LanAddresses)
if ($Port -le 0) { $Port = if ($firstRun) { 8000 } else { Get-SitePort } }
if ($firstRun -and -not $ServerAddress) {
    Write-Host '    This computer''s network addresses:'
    $addresses | ForEach-Object { Write-Host "      $_" }
    $default = if ($addresses.Count) { $addresses[0] } else { '127.0.0.1' }
    Write-Note 'Lab PCs and staff will use this address. It must not change: reserve it in the router (DHCP reservation).'
    $answer = Read-Host "    Campus address of this server [$default]"
    $ServerAddress = if ($answer.Trim()) { $answer.Trim() } else { $default }
}
if ($ServerAddress -and $ServerAddress -match '^\d+\.\d+\.\d+\.\d+$' -and $ServerAddress -notin $addresses -and $ServerAddress -ne '127.0.0.1') {
    Write-Note "$ServerAddress is not one of this computer's current addresses ($($addresses -join ', ')). Continuing, but lab PCs will not reach the server until it has that address."
}
if ($firstRun) {
    $hosts = @('127.0.0.1', 'localhost', $env:COMPUTERNAME.ToLower(), $ServerAddress) + $addresses | Select-Object -Unique
    $origins = $hosts | ForEach-Object { "http://$($_):$Port" }
    $dbPassword = New-RandomSecret 32
    $settings = [ordered]@{
        'DJANGO_DEBUG' = 'False'
        'DJANGO_SECRET_KEY' = (New-RandomSecret 60)
        'DJANGO_ALLOWED_HOSTS' = ($hosts -join ',')
        'DJANGO_CSRF_TRUSTED_ORIGINS' = ($origins -join ',')
        'DJANGO_SECURE_SSL' = 'False'
        'SITE_URL' = "http://$($ServerAddress):$Port"
        'COMPULAB_PORT' = "$Port"
        'COMPULAB_REMOTE_URL' = $RemoteUrl.TrimEnd('/')
        'DB_NAME' = $DbName
        'DB_USER' = $DbUser
        'DB_PASSWORD' = $dbPassword
        'DB_HOST' = $DbHost
        'DB_PORT' = $DbPort
        'PC_AGENT_SHARED_SECRET' = (New-RandomSecret 40)
        # The CompuLab Worker service runs the background work; the website must not.
        'COMPULAB_BACKGROUND_TASKS' = 'False'
        'DJANGO_SERVE_MEDIA' = 'True'
        # Email is optional; leave blank until configure-email.ps1 is run
        # (emails are then printed to the log instead of sent).
        'EMAIL_HOST_USER' = ''
        'EMAIL_HOST_PASSWORD' = ''
        # Cloud sync is optional and needs a receiver (cloud_sync\PROTOCOL.md).
        'CLOUD_SERVER_URL' = ''
        'CLOUD_SYNC_API_KEY' = ''
    }
    foreach ($key in $settings.Keys) { Set-DotEnvValue $key $settings[$key] }
    Protect-EnvFile
    Write-Ok ".env created (campus address: http://$($ServerAddress):$Port)"
} else {
    Write-Ok '.env already exists - kept as is'
    $existing = Read-DotEnv
    if ($existing['COMPULAB_BACKGROUND_TASKS'] -ne 'False' -and -not $SkipServices) {
        Set-DotEnvValue 'COMPULAB_BACKGROUND_TASKS' 'False'
        Write-Note 'Set COMPULAB_BACKGROUND_TASKS=False (the CompuLab Worker service does the background work now).'
    }
    if (-not $existing.ContainsKey('COMPULAB_PORT')) { Set-DotEnvValue 'COMPULAB_PORT' "$Port" }
    if ($ServerAddress) {
        & "$PSScriptRoot\set-server-address.ps1" -Primary $ServerAddress -Port $Port -NoRestart
    }
    if ($RemoteUrl) { Set-DotEnvValue 'COMPULAB_REMOTE_URL' $RemoteUrl.TrimEnd('/') }
}
$envValues = Read-DotEnv
$siteUrl = $envValues['SITE_URL']

# ---------------------------------------------------------------- 4. database
if (-not $SkipDatabaseSetup) {
    Write-Step 'Preparing the database'
    $rootPassword = Read-Host -AsSecureString 'MariaDB/MySQL root password (used once, not saved)'
    $plainRoot = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($rootPassword))
    $rootCnf = New-MySqlDefaultsFile 'root' $plainRoot $envValues['DB_HOST'] $envValues['DB_PORT']
    try {
        $serverVersion = Get-DbServerVersion $mysql $rootCnf
        if (-not $serverVersion) { throw 'Could not sign in to the database server as root (wrong password, or the service is not running).' }
        Write-Ok "Database server: $(Assert-SupportedDbVersion $serverVersion)"
        $db = $envValues['DB_NAME']; $user = $envValues['DB_USER']; $pw = $envValues['DB_PASSWORD'].Replace("'", "''")
        $sql = @"
CREATE DATABASE IF NOT EXISTS ``$db`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$user'@'localhost' IDENTIFIED BY '$pw';
CREATE USER IF NOT EXISTS '$user'@'127.0.0.1' IDENTIFIED BY '$pw';
GRANT ALL PRIVILEGES ON ``$db``.* TO '$user'@'localhost';
GRANT ALL PRIVILEGES ON ``$db``.* TO '$user'@'127.0.0.1';
FLUSH PRIVILEGES;
"@
        $sql | & $mysql "--defaults-extra-file=$rootCnf"
        if ($LASTEXITCODE -ne 0) { throw 'Creating the database or its user failed.' }
        Write-Ok "Database '$db' and user '$user' are ready"
    } finally {
        Remove-Item $rootCnf -Force -ErrorAction SilentlyContinue
        $plainRoot = $null
    }
} elseif ($mysql) {
    # Existing database: still refuse a server version this Django can't use.
    $appCnf = New-MySqlDefaultsFile $envValues['DB_USER'] $envValues['DB_PASSWORD'] $envValues['DB_HOST'] $envValues['DB_PORT']
    try {
        $serverVersion = Get-DbServerVersion $mysql $appCnf
        if ($serverVersion) { Write-Ok "Database server: $(Assert-SupportedDbVersion $serverVersion)" }
        else { Write-Note 'Could not check the database server version with the credentials in .env.' }
    } finally { Remove-Item $appCnf -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- 5. migrate
if (-not $firstRun) {
    Write-Step 'Backing up before upgrading'
    & "$PSScriptRoot\backup.ps1" -BackupRoot $BackupRoot
}
Stop-CompuLabServices
Write-Step 'Updating the database structure'
Invoke-Manage @('migrate', '--plan')
Invoke-Manage @('migrate', '--noinput')
Invoke-Manage @('collectstatic', '--noinput')
Invoke-Manage @('check')
Write-Ok 'Database and static files are up to date'

# ---------------------------------------------------------------- 6. first admin
Push-Location $script:AppDir
$hasSuperuser = & $script:VenvPython manage.py shell -c "from django.contrib.auth import get_user_model as g; print(g().objects.filter(is_superuser=True).exists())"
Pop-Location
if ($hasSuperuser -notmatch 'True') {
    Write-Step 'Create the first Administrator account'
    Write-Note 'Use a Gmail address you can reach. The password is typed by you and never shown or logged.'
    Push-Location $script:AppDir
    & $script:VenvPython manage.py createsuperuser
    Pop-Location
}

# ---------------------------------------------------------------- 7. services
if (-not $SkipServices) {
    Write-Step 'Installing the Windows services'
    New-Item -ItemType Directory -Force -Path $script:ServiceDir | Out-Null
    $logDir = Join-Path $script:AppDir 'logs'
    $waitress = Join-Path $script:AppDir 'venv\Scripts\waitress-serve.exe'
    if (-not (Test-Path $waitress)) { throw 'waitress-serve.exe is missing from venv\Scripts (package install incomplete).' }
    $definitions = @(
        # 0.0.0.0: reachable on the campus LAN and, if configured, the
        # Tailscale address; the firewall rule below limits who may connect.
        @{ Id = $script:WebService; Name = 'CompuLab Web'; Exe = $waitress;
           Args = "--listen=0.0.0.0:$Port --threads=8 compulab.wsgi:application";
           Desc = 'CompuLab website (waitress). Serves the campus network on port ' + $Port + '.';
           Env = @{ 'COMPULAB_BACKGROUND_TASKS' = 'False' } },
        @{ Id = $script:WorkerService; Name = 'CompuLab Worker'; Exe = $script:VenvPython;
           Args = 'manage.py run_worker';
           Desc = 'CompuLab background work: PC status, email outbox, cloud sync, reminders, durable jobs.';
           Env = @{ 'COMPULAB_BACKGROUND_TASKS' = 'False'; 'DJANGO_LOG_FILE_NAME' = 'worker.log' } }
    )
    foreach ($d in $definitions) {
        $exe = Join-Path $script:ServiceDir "$($d.Id).exe"
        $xml = Join-Path $script:ServiceDir "$($d.Id).xml"
        $existing = Get-Service -Name $d.Id -ErrorAction SilentlyContinue
        if ($existing) { & $exe stop 2>$null | Out-Null; & $exe uninstall | Out-Null }
        Copy-Item $winsw $exe -Force
        $envXml = ($d.Env.GetEnumerator() | ForEach-Object { "  <env name=`"$($_.Key)`" value=`"$($_.Value)`"/>" }) -join "`n"
        # Start after the database service so a reboot brings everything up in order.
        $dependXml = if ($dbService) { "  <depend>$dbService</depend>" } else { '' }
        $content = @"
<service>
  <id>$($d.Id)</id>
  <name>$($d.Name)</name>
  <description>$($d.Desc)</description>
  <executable>$($d.Exe)</executable>
  <arguments>$($d.Args)</arguments>
  <workingdirectory>$($script:AppDir)</workingdirectory>
$envXml
  <startmode>Automatic</startmode>
  <delayedAutoStart>true</delayedAutoStart>
$dependXml
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="restart" delay="60 sec"/>
  <resetfailure>1 hour</resetfailure>
  <logpath>$logDir</logpath>
  <log mode="roll-by-size"><sizeThreshold>5120</sizeThreshold><keepFiles>5</keepFiles></log>
</service>
"@
        [IO.File]::WriteAllText($xml, $content, (New-Object Text.UTF8Encoding $false))
        & $exe install
        if ($LASTEXITCODE -ne 0) { throw "Installing the $($d.Name) service failed." }
        # Windows' own recovery settings as a second safety net.
        & sc.exe failure $d.Id reset= 3600 actions= restart/10000/restart/30000/restart/60000 | Out-Null
        Write-Ok "$($d.Name) service installed (starts automatically at boot)"
    }
    Start-CompuLabServices
}

# ---------------------------------------------------------------- 8. firewall
if (-not $SkipFirewall) {
    Write-Step 'Opening the firewall for the campus network'
    Get-NetFirewallRule -DisplayName 'CompuLab Web' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName 'CompuLab Web' -Direction Inbound -Protocol TCP -LocalPort $Port `
        -RemoteAddress $AllowFrom -Action Allow -Profile Private, Domain | Out-Null
    Write-Ok "Port $Port allowed from $($AllowFrom -join ', ') on Private/Domain networks"
    Write-Note 'The database port (3306) is NOT opened: only CompuLab on this computer uses it. Never forward any port on the router.'
    $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq 'Public' -and $_.InterfaceAlias -notlike 'Tailscale*' }
    foreach ($p in $profiles) { Write-Note "Network '$($p.Name)' ($($p.InterfaceAlias)) is set to Public: set it to Private in Windows Settings > Network, or lab PCs cannot connect." }
}

# ---------------------------------------------------------------- 9. backups
if (-not $SkipBackupTask) {
    Write-Step 'Scheduling the nightly backup'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\backup.ps1`" -BackupRoot `"$BackupRoot`""
    $trigger = New-ScheduledTaskTrigger -Daily -At '1:30AM'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable
    Register-ScheduledTask -TaskName 'CompuLab nightly backup' -Action $action -Trigger $trigger -Principal $principal -Settings $taskSettings -Force | Out-Null
    Write-Ok "Backups go to $BackupRoot every night at 1:30 AM, or at the next start-up if the server was off (keep them on a second disk or USB drive: change -BackupRoot)"
}

# ---------------------------------------------------------------- 10. health
$healthy = $false
if (-not $SkipServices -and (Get-Service -Name $script:WebService -ErrorAction SilentlyContinue)) {
    Write-Step 'Checking that CompuLab answers'
    $healthy = Wait-Healthy "http://127.0.0.1:$Port/healthz" 90
    if ($healthy) { Write-Ok 'CompuLab is running' }
    else { Write-Note 'No answer yet. Check logs\ and Services > CompuLab Web, or run installer\server\server-status.ps1.' }
}

$remote = (Read-DotEnv)['COMPULAB_REMOTE_URL']
Write-Host "`nCompuLab is installed." -ForegroundColor Green
Write-Host "  Campus address (lab PCs, staff): $siteUrl"
Write-Host "  Server status page (Admins):     $siteUrl/system/status/"
if ($remote) { Write-Host "  Remote address (Tailscale):      $remote" }
Write-Host '  Next steps:'
Write-Host '   - Reserve this server''s IP address in the router (DHCP reservation) so it never changes.'
Write-Host '   - Lab PCs: installer\agent\README.md (in CompuLab: PC status > Agent config gives each PC its settings file).'
Write-Host '   - Optional email:          installer\server\configure-email.ps1'
Write-Host '   - Optional remote access:  installer\server\configure-remote-access.ps1 (see installer\REMOTE_ACCESS.md)'
Write-Host '   - Check everything:        installer\server\server-status.ps1'
Write-Host '  Values only you can provide (not set by this script): email account + app password, Tailscale sign-in,'
Write-Host '  and a cloud sync receiver address + key (only if your college runs one).'
