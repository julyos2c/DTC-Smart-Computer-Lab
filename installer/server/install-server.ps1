<#
.SYNOPSIS
  Installs, updates or repairs the CompuLab server on this Windows computer.

.DESCRIPTION
  Easiest: double-click "Install CompuLab Server.cmd" in the CompuLab folder
  (it asks for administrator rights), or run CompuLab-Server-Setup.exe.
  By hand, as Administrator, from the CompuLab folder:

      powershell -ExecutionPolicy Bypass -File installer\server\install-server.ps1

  Safe to run again at any time ("repair"): existing settings (.env, with
  its secrets and database password), the database and uploaded files are
  kept; only what is missing is added, and new database migrations are
  applied after a backup.

  What it does:
    1. Checks Windows, PowerShell, the CompuLab files, a 64-bit Python
       3.11-3.13 (3.13 recommended) and the database server (MariaDB 10.5+ /
       MySQL 8.0.11+; MariaDB 11.4 or 10.11 LTS recommended) and that the web
       port is free. Stops with a clear message if something is missing;
       changes nothing until then. It never installs, upgrades or replaces
       Python or the database server.
    2. Creates the Python environment (venv) and installs the packages
       (from the bundled offline folder when present, else from the internet).
    3. Writes .env with random secrets and this server's campus address
       (first run only).
    4. Creates the database and its user (idempotent).
    5. Backs up (when updating), applies migrations, collects static files.
    6. Checks for a working Administrator account (active, role Admin) and
       creates the first one if there is none; the installation stops if it
       could not be created (never a second one on Repair/Update).
    7. Installs two Windows services that start at boot, after the database
       service, and restart themselves if they stop:
         CompuLab Web     - the website (waitress)
         CompuLab Worker  - background work: lab PC checks, email, cloud sync, jobs
    8. Opens the web port in Windows Firewall for private (campus / VPN)
       addresses only (never the database port).
    9. Schedules a nightly backup to -BackupRoot. The folder is recorded in
       .env (COMPULAB_BACKUP_ROOT); Repair, Update, "Back Up CompuLab Now"
       and restore keep using it until -BackupRoot is given again.

  Database: a MariaDB/MySQL server must already listen on -DbPort (3306
  unless chosen otherwise) of this computer. Port in use by XAMPP or by a
  program that is not MariaDB/MySQL: the installer stops and changes
  nothing (it never touches another database installation).
   10. Checks that the site answers, then prints the addresses to use.
  Everything shown is also written to logs\install-<time>.log.

  Unattended install (no questions): -NonInteractive with -ServerAddress,
  the MariaDB root password in the environment variable
  COMPULAB_DB_ROOT_PASSWORD, and - on a new installation - the first
  Administrator in DJANGO_SUPERUSER_EMAIL (@gmail.com) /
  DJANGO_SUPERUSER_PASSWORD (required: without them it stops). Settings may also
  come from -ConfigFile (see installer\server\server-install.sample.json);
  command-line values win over the file.

  Administrator rights are needed for the services, the firewall rule and
  the backup task. With -SkipServices -SkipFirewall -SkipBackupTask it runs
  as a normal user (application setup only, e.g. a test machine).

.PARAMETER ServerAddress
  The campus IP address or DNS name lab PCs and staff use to reach this
  server (e.g. 192.168.1.10). Asked for on the first run if not given.

.PARAMETER RemoteUrl
  Optional remote (Tailscale) address. Normally set by configure-remote-access.ps1.
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = '',
    [string]$ServerAddress = '',
    [int]$Port = 0,
    [string]$RemoteUrl = '',
    [string]$DbName = '',
    [string]$DbUser = '',
    [string]$DbHost = '',
    [string]$DbPort = '',
    # 'auto' finds the MariaDB/MySQL service; 'none' when the database is not
    # a Windows service on this computer.
    [string]$DbServiceName = '',
    [string]$BackupRoot = '',
    [string[]]$AllowFrom = @(),
    [switch]$NonInteractive,
    # Keep the window open at the end (used by CompuLab-Server-Setup.exe).
    [switch]$PauseAtEnd,
    [switch]$SkipDatabaseSetup,
    [switch]$SkipServices,
    [switch]$SkipFirewall,
    [switch]$SkipBackupTask
)

. "$PSScriptRoot\common.ps1"
$logPath = Start-InstallLog 'install'
$exitCode = 0
try {
    if (-not ($SkipServices -and $SkipFirewall -and $SkipBackupTask)) { Assert-Admin }
    Set-Location $script:AppDir
    $firstRun = -not (Test-Path $script:EnvFile)
    $existingEnv = Read-DotEnv

    # ------------------------------------------------------------ 0. settings
    # Backups keep going where they went before (COMPULAB_BACKUP_ROOT in .env,
    # or the existing nightly task); C:\CompuLab\backups only on a new install.
    $configuredBackup = Get-ConfiguredBackupRoot
    $defaults = @{
        ServerAddress = ''; Port = 8000; RemoteUrl = ''; DbName = 'compulab_db'; DbUser = 'compulab'
        DbHost = '127.0.0.1'; DbPort = '3306'; DbServiceName = 'auto'; BackupRoot = $configuredBackup.Path
        AllowFrom = $script:DefaultAllowFrom; AdminEmail = ''
    }
    if (-not $firstRun) {
        # Repair / update: the installed values are the defaults.
        $defaults.Port = Get-SitePort
        foreach ($pair in @(@('DbName', 'DB_NAME'), @('DbUser', 'DB_USER'), @('DbHost', 'DB_HOST'), @('DbPort', 'DB_PORT'))) {
            if ($existingEnv[$pair[1]]) { $defaults[$pair[0]] = $existingEnv[$pair[1]] }
        }
    }
    $fromFile = if ($ConfigFile) { Read-InstallConfig $ConfigFile } else { @{} }
    $explicit = @{}
    foreach ($k in $script:SettingKeys) {
        if ($PSBoundParameters.ContainsKey($k)) { $explicit[$k] = $PSBoundParameters[$k] }
    }
    $S = Merge-InstallSettings $defaults $fromFile $explicit
    $S.AllowFrom = @($S.AllowFrom)

    # ------------------------------------------------------------ 1. prerequisites
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

    Write-Step 'Checking the settings'
    $addresses = @(Get-LanAddresses)
    if (-not $S.ServerAddress -and -not $firstRun -and $existingEnv['SITE_URL'] -match '^https?://([^/:]+)') { $S.ServerAddress = $Matches[1] }
    if (-not $S.ServerAddress) {
        $default = if ($addresses.Count) { $addresses[0] } else { '127.0.0.1' }
        if ($NonInteractive) {
            $S.ServerAddress = $default
            Write-Note "No -ServerAddress given: using $default."
        } else {
            Write-Host '    This computer''s network addresses:'
            $addresses | ForEach-Object { Write-Host "      $_" }
            Write-Note 'Lab PCs and staff will use this address. It must not change: reserve it in the router (DHCP reservation).'
            $answer = Read-Host "    Campus address of this server [$default]"
            $S.ServerAddress = if ($answer.Trim()) { $answer.Trim() } else { $default }
        }
    }
    $problems = Test-InstallSettings $S
    if (-not $firstRun) {
        # The database name and user of an existing installation hold its data:
        # a repair never switches to another (empty) database.
        foreach ($pair in @(@('DbName', 'DB_NAME'), @('DbUser', 'DB_USER'))) {
            if ($existingEnv[$pair[1]] -and "$($S[$pair[0]])" -ne $existingEnv[$pair[1]]) {
                $problems += "$($pair[0]) cannot be changed on an existing installation (it is '$($existingEnv[$pair[1]])' in .env). To move the data, back up and restore instead."
            }
        }
    }
    if ($problems.Count) { throw ("The settings are not valid:`n      - " + ($problems -join "`n      - ")) }
    if ($S.ServerAddress -match '^\d+\.\d+\.\d+\.\d+$' -and $S.ServerAddress -notin $addresses -and $S.ServerAddress -ne '127.0.0.1') {
        Write-Note "$($S.ServerAddress) is not one of this computer's current addresses ($($addresses -join ', ')). Continuing, but lab PCs will not reach the server until it has that address."
    }
    $backupProblem = Test-BackupRoot "$($S.BackupRoot)"
    if ($backupProblem) { throw "$backupProblem Choose another folder with -BackupRoot (for example a second disk: -BackupRoot E:\CompuLabBackups)." }
    if ($S.BackupRoot -ne $configuredBackup.Path -and $configuredBackup.Source -ne 'default') {
        Write-Note "Backup folder changed from $($configuredBackup.Path) to $($S.BackupRoot)."
    }
    Write-Ok "Campus address http://$($S.ServerAddress):$($S.Port), database $($S.DbName) on $($S.DbHost):$($S.DbPort), backups in $($S.BackupRoot)"

    Write-Step 'Checking Python'
    $python = Find-Python
    if (-not $python) {
        $found = if ($script:PythonRejected.Count) { " Found instead: $($script:PythonRejected -join '; ')." } else { ' No Python was found.' }
        throw ('A 64-bit Python 3.13 (or 3.12 / 3.11) is required.' + $found +
               ' Install "Python 3.13 - Windows installer (64-bit)" from python.org: choose "Customize installation", tick "Install Python 3.13 for all users"' +
               ' and "Add Python to environment variables", then run this setup again. (Python 3.14 is not supported yet; it can stay installed next to 3.13.)')
    }
    Write-Ok "Python $($python.Version) 64-bit ($($python.BasePrefix))"
    if (-not (Test-PythonForAllUsers $python.BasePrefix)) {
        Write-Note "This Python is installed for one Windows account only ($($python.BasePrefix)). The CompuLab services use it, so they stop working if that account or its profile is removed."
        Write-Note 'Recommended: install Python 3.13 64-bit "for all users" (python.org installer > Customize installation) and run this setup again.'
    }

    Write-Step 'Checking the database server'
    $mysql = Find-MySqlTool 'mysql.exe'
    if (-not $mysql) { $mysql = Find-MySqlTool 'mariadb.exe' }
    # This installer never installs, upgrades or replaces MariaDB/MySQL: it
    # only uses the database server that is already installed.
    if (-not $mysql -and -not $SkipDatabaseSetup) {
        throw ('No MariaDB or MySQL database server was found (mysql.exe / mariadb.exe). This setup does not install one. ' +
               'Install MariaDB 11.4 LTS (or 10.11 LTS) 64-bit from mariadb.org (MSI package, keep "Install as service" ticked, choose a root password) ' +
               '- or MySQL 8.0.11 or newer - then run this setup again. XAMPP''s MariaDB 10.4 is too old. ' +
               '(-SkipDatabaseSetup if the CompuLab database already exists on another computer.)')
    }
    if ($mysql) { Write-Ok "Database client: $mysql" }
    $dbLocal = $S.DbHost -in @('127.0.0.1', 'localhost')
    $listener = if ($dbLocal) { Get-ListenerInfo ([int]$S.DbPort) } else { $null }
    $dbService = $null
    if ($S.DbServiceName -ne 'none') {
        # The service that owns the database port is the one CompuLab uses.
        $owner = if ($listener) { $listener.ServiceName } else { '' }
        $dbService = if ($S.DbServiceName -eq 'auto') { Get-DbServiceName $owner } else { $S.DbServiceName }
    }
    if ($dbService) {
        $svc = Get-Service $dbService -ErrorAction SilentlyContinue
        if (-not $svc) { throw "The database service '$dbService' does not exist (Services app: check its name, then use -DbServiceName <name>)." }
        if ($svc.Status -ne 'Running') {
            if (-not (Test-IsAdmin)) { throw "The database service $dbService is stopped and starting it needs administrator rights." }
            Write-Note "The database service $dbService is stopped: starting it (its settings and data are not changed)."
            Start-Service $dbService; Write-Ok "Started the $dbService service"
        } else { Write-Ok "Database service: $dbService (running)" }
        if ((Test-IsAdmin) -and $svc.StartType -ne 'Automatic') {
            # CompuLab's services depend on it, so it has to start at boot too.
            Set-Service $dbService -StartupType Automatic
            Write-Note "Changed the start type of $dbService from $($svc.StartType) to Automatic (CompuLab needs it at boot). Nothing else about it was changed."
        }
    } elseif ($dbLocal -and $S.DbServiceName -eq 'auto') {
        Write-Note 'No MariaDB/MySQL Windows service was found. The database must start automatically at boot, or CompuLab will not start after a restart.'
    }
    if ($dbLocal) {
        # Port $S.DbPort must belong to a MariaDB/MySQL server: never XAMPP or
        # another program, which CompuLab must not touch.
        if (-not $listener) { $listener = Wait-DbListener ([int]$S.DbPort) $(if ($dbService) { 20 } else { 2 }) }
        $dbProblem = Test-DbListener $listener $S.DbHost ([int]$S.DbPort)
        if ($dbProblem) { throw $dbProblem }
        if ($listener.ServiceName -and $dbService -and $listener.ServiceName -ne $dbService) {
            throw ("Port $($S.DbPort) belongs to the service '$($listener.ServiceName)', not to '$dbService'. " +
                   "Run the installer with -DbServiceName $($listener.ServiceName), or give the port of '$dbService' with -DbPort.")
        }
        $who = if ($listener.ServiceName) { "the $($listener.ServiceName) service" } elseif ($listener.ProcessPath) { $listener.ProcessPath } else { "process $($listener.ProcessId)" }
        Write-Ok "Port $($S.DbPort) is served by $who"
    }

    $winsw = $null
    if (-not $SkipServices) {
        Write-Step 'Checking the service wrapper (WinSW)'
        $winsw = Get-WinSWExe
        if (-not $winsw) {
            throw ('WinSW-x64.exe was not found in installer\server\bin\. It is needed so CompuLab starts automatically after a restart. ' +
                   'CompuLab-Server-Setup.exe includes it; for a plain folder copy, download WinSW-x64.exe v2.12.0 from github.com/winsw/winsw/releases ' +
                   'into installer\server\bin\ and run this again. (Or install without services: -SkipServices, then run-foreground.ps1.)')
        }
        Write-Ok "WinSW: $(Test-WinSWExe $winsw)"
    }

    $webInstalled = [bool](Get-Service -Name $script:WebService -ErrorAction SilentlyContinue)
    if (-not $webInstalled) {
        $owner = Get-PortOwner ([int]$S.Port)
        if ($owner) { throw "Port $($S.Port) is already used by '$owner'. Stop that program or choose another port with -Port." }
        Write-Ok "Port $($S.Port) is free"
    }

    # ------------------------------------------------------------ 2. venv + packages
    Write-Step 'Installing the Python environment'
    if (-not (Test-Path $script:VenvPython)) {
        Invoke-Logged $python.Command[0] (@($python.Command | Select-Object -Skip 1) + @('-m', 'venv', (Join-Path $script:AppDir 'venv')))
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $script:VenvPython)) { throw 'Could not create the Python environment (venv).' }
    }
    $source = Install-PythonPackages (Join-Path $PSScriptRoot 'requirements-server.txt')
    Write-Ok "Packages installed ($source)"

    # ------------------------------------------------------------ 3. .env
    Write-Step 'Configuring settings (.env)'
    $firstRun = Initialize-DotEnv $S $addresses -WorkerService:(-not $SkipServices)
    if ($firstRun) { Write-Ok ".env created with new random secrets (campus address: http://$($S.ServerAddress):$($S.Port))" }
    else {
        Write-Ok '.env already exists: kept (secrets and database password unchanged)'
        if ($PSBoundParameters.ContainsKey('ServerAddress') -or $fromFile.ContainsKey('ServerAddress') -or $PSBoundParameters.ContainsKey('Port')) {
            & "$PSScriptRoot\set-server-address.ps1" -Primary $S.ServerAddress -Port $S.Port -NoRestart
        }
        if ($S.RemoteUrl) { Set-DotEnvValue 'COMPULAB_REMOTE_URL' "$($S.RemoteUrl)".TrimEnd('/') }
        # A database moved to another port/host (checked above: a MariaDB/MySQL
        # server answers there) is only changed when asked for explicitly.
        foreach ($pair in @(@('DbPort', 'DB_PORT'), @('DbHost', 'DB_HOST'))) {
            if (($PSBoundParameters.ContainsKey($pair[0]) -or $fromFile.ContainsKey($pair[0])) -and "$($S[$pair[0]])" -ne $existingEnv[$pair[1]]) {
                Set-DotEnvValue $pair[1] "$($S[$pair[0]])"
                Write-Note "$($pair[1]) changed from '$($existingEnv[$pair[1]])' to '$($S[$pair[0]])'."
            }
        }
    }
    # Where Repair, Update, "Back Up CompuLab Now" and restore put backups.
    Set-DotEnvValue 'COMPULAB_BACKUP_ROOT' "$($S.BackupRoot)"
    $envValues = Read-DotEnv
    $siteUrl = $envValues['SITE_URL']

    # ------------------------------------------------------------ 4. database
    if (-not $SkipDatabaseSetup) {
        Write-Step 'Preparing the database'
        $plainRoot = $env:COMPULAB_DB_ROOT_PASSWORD
        if (-not $plainRoot) {
            if ($NonInteractive) { throw 'Set the environment variable COMPULAB_DB_ROOT_PASSWORD (MariaDB root password) for an unattended install, or use -SkipDatabaseSetup.' }
            $plainRoot = Read-SecretText 'MariaDB/MySQL root password (used once, not saved)'
        }
        $rootCnf = New-MySqlDefaultsFile 'root' $plainRoot $envValues['DB_HOST'] $envValues['DB_PORT']
        try {
            $serverVersion = Get-DbServerVersion $mysql $rootCnf
            if (-not $serverVersion) { throw 'Could not sign in to the database server as root (wrong password, or the database service is not running).' }
            Write-Ok "Database server: $(Assert-SupportedDbVersion $serverVersion)"
            Get-DbSetupSql $envValues['DB_NAME'] $envValues['DB_USER'] $envValues['DB_PASSWORD'] | & $mysql "--defaults-extra-file=$rootCnf"
            if ($LASTEXITCODE -ne 0) { throw 'Creating the database or its user failed (see the message above).' }
            Write-Ok "Database '$($envValues['DB_NAME'])' and user '$($envValues['DB_USER'])' are ready"
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

    # ------------------------------------------------------------ 5. migrate
    if (-not $firstRun) {
        Write-Step 'Backing up before changing anything'
        & "$PSScriptRoot\backup.ps1" -BackupRoot $S.BackupRoot
    }
    Stop-CompuLabServices
    Write-Step 'Updating the database structure'
    Invoke-Manage @('migrate', '--plan')
    Invoke-Manage @('migrate', '--noinput')
    Invoke-Manage @('collectstatic', '--noinput')
    Invoke-Manage @('check')
    Write-Ok 'Database and static files are up to date'

    # ------------------------------------------------------------ 6. first admin
    # The installation is not complete without an Administrator who can sign
    # in: manage.py ensure_admin checks for one (active superuser, role
    # Admin), creates it if there is none (never a second one), and the
    # result is verified before the installer continues.
    Write-Step 'Checking the Administrator account'
    $admin = Invoke-EnsureAdmin @('--check')
    if ($admin.ExitCode -eq 0) { Write-Ok $admin.Message }
    elseif ($admin.ExitCode -ne 3) { throw "Could not check the Administrator account: $($admin.Message)" }
    else {
        Write-Note $admin.Message
        Write-Step 'Create the first Administrator account'
        $email = if ($env:DJANGO_SUPERUSER_EMAIL) { $env:DJANGO_SUPERUSER_EMAIL } else { "$($S.AdminEmail)" }
        $adminPassword = $env:DJANGO_SUPERUSER_PASSWORD
        if ($NonInteractive -and (-not $email -or -not $adminPassword)) {
            throw ('There is no Administrator account yet. For an unattended install set the environment variables DJANGO_SUPERUSER_EMAIL ' +
                   '(a @gmail.com address) and DJANGO_SUPERUSER_PASSWORD, or run the installer again without /VERYSILENT and type them.')
        }
        if (-not $NonInteractive) {
            Write-Note 'This is the CompuLab sign-in of the Administrator (not a Windows account). CompuLab accepts only @gmail.com addresses.'
            Write-Note 'The password is at least 8 characters, not only digits, not a common password; it is never shown or logged.'
        }
        $askEmail = -not $email; $askPassword = -not $adminPassword
        $last = $null
        for ($attempt = 1; $attempt -le $(if ($NonInteractive) { 1 } else { 4 }); $attempt++) {
            if (-not $NonInteractive) {
                if ($askEmail) { $email = (Read-Host '    Administrator email (@gmail.com)').Trim() }
                $emailProblem = Test-AdminEmail $email
                if ($emailProblem) { Write-Note $emailProblem; $askEmail = $true; continue }
                if ($askPassword) {
                    $first = Read-SecretText '    Password'
                    $again = Read-SecretText '    Password (again)'
                    if ($first -ne $again) { Write-Note 'The two passwords are different. Type them again.'; $first = $null; $again = $null; continue }
                    $adminPassword = $first; $first = $null; $again = $null
                }
            }
            $last = Invoke-EnsureAdmin @('--email', $email) $adminPassword
            if ($last.ExitCode -eq 0) { break }
            Write-Note $last.Message
            if ($last.ExitCode -ne 2) { break }   # not a problem with what was typed
            $askPassword = $last.Message -match 'password'
            $askEmail = -not $askPassword
        }
        $adminPassword = $null
        $admin = Invoke-EnsureAdmin @('--check')
        if ($admin.ExitCode -ne 0) {
            $why = if ($last) { $last.Message } else { $admin.Message }
            throw ("The first Administrator account was not created: $why Nothing is lost: run the installer again " +
                   '(Start > CompuLab > Repair CompuLab Server) and it asks again.')
        }
        Write-Ok $admin.Message
    }

    # ------------------------------------------------------------ 7. services
    if (-not $SkipServices) {
        Write-Step 'Installing the Windows services'
        New-Item -ItemType Directory -Force -Path $script:ServiceDir | Out-Null
        $logDir = Join-Path $script:AppDir 'logs'
        if (-not (Test-Path (Join-Path $script:AppDir 'venv\Scripts\waitress-serve.exe'))) { throw 'waitress-serve.exe is missing from venv\Scripts (package install incomplete).' }
        foreach ($d in Get-ServiceDefinitions ([int]$S.Port)) {
            $exe = Join-Path $script:ServiceDir "$($d.Id).exe"
            $xml = Join-Path $script:ServiceDir "$($d.Id).xml"
            if (Get-Service -Name $d.Id -ErrorAction SilentlyContinue) { Invoke-Quiet $exe @('stop') | Out-Null; Invoke-Quiet $exe @('uninstall') | Out-Null }
            Copy-Item $winsw $exe -Force
            [IO.File]::WriteAllText($xml, (New-WinSWXml $d $dbService $logDir), (New-Object Text.UTF8Encoding $false))
            & $exe install
            if ($LASTEXITCODE -ne 0) { throw "Installing the $($d.Name) service failed." }
            # Windows' own recovery settings as a second safety net.
            Invoke-Quiet 'sc.exe' (Get-ServiceRecoveryArgs $d.Id) | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Note "Could not set Windows' restart-on-failure for $($d.Id) (sc.exe exit code $LASTEXITCODE); WinSW still restarts it." }
            Write-Ok "$($d.Name) service installed (starts automatically at boot)"
        }
        Start-CompuLabServices
    }

    # ------------------------------------------------------------ 8. firewall
    if (-not $SkipFirewall) {
        Write-Step 'Opening the firewall for the campus network'
        Get-NetFirewallRule -DisplayName 'CompuLab Web' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        $rule = Get-WebFirewallRuleSpec ([int]$S.Port) $S.AllowFrom
        New-NetFirewallRule @rule | Out-Null
        Write-Ok "Port $($S.Port) allowed from $($S.AllowFrom -join ', ') on Private/Domain networks"
        Write-Note 'The database port (3306) is NOT opened: only CompuLab on this computer uses it. Never forward any port on the router.'
        $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq 'Public' -and $_.InterfaceAlias -notlike 'Tailscale*' }
        foreach ($p in $profiles) { Write-Note "Network '$($p.Name)' ($($p.InterfaceAlias)) is set to Public: set it to Private in Windows Settings > Network, or lab PCs cannot connect." }
    }

    # ------------------------------------------------------------ 9. backups
    if (-not $SkipBackupTask) {
        Write-Step 'Scheduling the nightly backup'
        $task = New-BackupTaskDefinition (Join-Path $PSScriptRoot 'backup.ps1') $S.BackupRoot
        Register-ScheduledTask -TaskName $script:BackupTaskName @task -Force | Out-Null
        Write-Ok "Backups go to $($S.BackupRoot) every night at 1:30 AM, or at the next start-up if the server was off (keep them on a second disk or USB drive: -BackupRoot)"
        Write-Note 'Each nightly run writes logs\backup-<time>.log. Run the task once now to test it: Task Scheduler > "CompuLab nightly backup" > Run.'
    }

    # ------------------------------------------------------------ 10. health
    if (-not $SkipServices -and (Get-Service -Name $script:WebService -ErrorAction SilentlyContinue)) {
        Write-Step 'Checking that CompuLab answers'
        if (Wait-Healthy "http://127.0.0.1:$($S.Port)/healthz" 90) { Write-Ok 'CompuLab is running' }
        else { Write-Note 'No answer yet. Check logs\ and Services > CompuLab Web, or run installer\server\server-status.ps1.' }
    }

    $remote = (Read-DotEnv)['COMPULAB_REMOTE_URL']
    Write-Host "`nCompuLab is installed." -ForegroundColor Green
    Write-Host "  Campus address (lab PCs, staff): $siteUrl"
    Write-Host "  Server status page (Admins):     $siteUrl/system/status/"
    if ($remote) { Write-Host "  Remote address (Tailscale):      $remote" }
    if ($SkipServices) { Write-Host '  Services were not installed (-SkipServices): start CompuLab with installer\server\run-foreground.ps1.' }
    Write-Host '  Next steps:'
    Write-Host '   - Reserve this server''s IP address in the router (DHCP reservation) so it never changes.'
    Write-Host '   - Lab PCs: CompuLab > PC power status > Agent config gives each PC its settings file; then run CompuLab-Agent-Setup.exe on the PC.'
    Write-Host "   - Backups:                 $($S.BackupRoot) (nightly at 1:30 AM and 'Back Up CompuLab Now'; kept by Repair/Update)"
    Write-Host '   - Optional email:          installer\server\configure-email.ps1'
    Write-Host '   - Optional remote access:  installer\server\configure-remote-access.ps1 (see installer\REMOTE_ACCESS.md)'
    Write-Host '   - Check everything:        installer\server\server-status.ps1'
    if ($logPath) { Write-Host "  Install log: $logPath" }
} catch {
    $exitCode = 1
    Write-Host "`nInstallation stopped: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Nothing after this step was changed. Fix the problem above and run the installer again (it continues safely).' -ForegroundColor Red
    $stopped = @($script:WebService, $script:WorkerService | Where-Object { $s = Get-Service $_ -ErrorAction SilentlyContinue; $s -and $s.Status -ne 'Running' })
    if ($stopped.Count) {
        Write-Host "  The CompuLab services are stopped ($($stopped -join ', ')), so the website is offline until the installer completes." -ForegroundColor Red
    }
    if ($logPath) { Write-Host "  Full log: $logPath" -ForegroundColor Red }
} finally {
    Stop-InstallLog
}
if ($PauseAtEnd -and -not $NonInteractive) { Read-Host "`nPress Enter to close this window" | Out-Null }
exit $exitCode
