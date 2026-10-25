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

  Database and Python (-DbMode):
    bundled   CompuLab-Server-Setup.exe ships its own Python (runtime\python)
              and MariaDB 11.4 (runtime\mariadb). The installer creates
              CompuLab's own database server: data in data\mariadb, the
              Windows service CompuLabMariaDB, 127.0.0.1 only (never the
              LAN), port 3308 or the next free one (-DbPort sets the first
              port tried). No Python, database server, root password or
              internet is needed. The default for a new installation made
              with the setup.
    external  an existing MariaDB/MySQL server that already listens on
              -DbPort (3306 unless chosen otherwise) of this computer; asks
              for its root password. A plain folder copy (no runtime\) always
              uses this, as do installations made before (they keep their
              database). Port in use by XAMPP, another program's database or
              a program that is not MariaDB/MySQL: the installer stops and
              changes nothing.
  Other databases on this computer (MySQL, XAMPP, other programs' MariaDB)
  are never stopped, changed, reused or initialized. A Repair keeps the
  mode recorded in .env (COMPULAB_DB_MODE); -DbMode bundled moves an
  installation whose database holds no CompuLab data yet to its own one.
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
    # '' / 'auto': bundled for a new installation made with the setup, else
    # what .env records; 'bundled' or 'external' to choose (see above).
    [ValidateSet('', 'auto', 'bundled', 'external')]
    [string]$DbMode = '',
    # With a -DbMode change: confirms that the old database (kept, never
    # changed) may be left behind, e.g. because its backup will be restored.
    [switch]$LeaveOldDatabase,
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

    # Which database (see -DbMode). Installations made before the bundled
    # database existed have no COMPULAB_DB_MODE: they keep their server.
    $recordedMode = "$($existingEnv['COMPULAB_DB_MODE'])".Trim().ToLower()
    if ($recordedMode -notin @('bundled', 'external')) { $recordedMode = $(if ($firstRun) { '' } else { 'external' }) }
    $dbMode = if ($DbMode -in @('bundled', 'external')) { $DbMode }
              elseif ($recordedMode) { $recordedMode }
              elseif (Test-BundledDbAvailable) { 'bundled' } else { 'external' }
    $bundled = $dbMode -eq 'bundled'
    $switchingMode = [bool]($recordedMode -and $dbMode -ne $recordedMode)
    $dbPortGiven = $PSBoundParameters.ContainsKey('DbPort') -or $fromFile.ContainsKey('DbPort')
    if ($bundled) {
        if (-not (Test-BundledDbAvailable)) {
            throw ('This copy of CompuLab has no bundled database (runtime\mariadb): install with CompuLab-Server-Setup.exe, ' +
                   'or use an existing MariaDB/MySQL server with -DbMode external.')
        }
        if ($SkipDatabaseSetup) { throw '-SkipDatabaseSetup is only for an external database; CompuLab''s own database is always set up by the installer.' }
        if (($PSBoundParameters.ContainsKey('DbHost') -or $fromFile.ContainsKey('DbHost')) -and $S.DbHost -notin @('127.0.0.1', 'localhost')) {
            throw "CompuLab's own database runs on this computer only: -DbHost $($S.DbHost) cannot be used with it (that is -DbMode external)."
        }
        $S.DbHost = '127.0.0.1'
        $S.DbServiceName = $script:BundledDbService
        # The first port tried: the one given, else the one it already has
        # (my.ini, or .env when my.ini cannot be read yet), else 3308.
        if (-not $dbPortGiven) {
            $known = Get-BundledDbPort
            if (-not $known -and $recordedMode -eq 'bundled' -and "$($existingEnv['DB_PORT'])" -match '^\d+$') { $known = [int]$existingEnv['DB_PORT'] }
            $S.DbPort = "$(if ($known) { $known } else { $script:BundledDbPreferredPort })"
        }
    }

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
    if (-not $firstRun) {
        # Repair / update: the database settings must come from the existing
        # .env, checked before anything is asked, installed or written (a
        # developer copy's .env has none of them).
        $givenDb = @()
        foreach ($k in 'DbHost', 'DbPort') { if ($bundled -or $PSBoundParameters.ContainsKey($k) -or $fromFile.ContainsKey($k)) { $givenDb += $k } }
        $dbProblems = @(Test-ExistingDbSettings $existingEnv $givenDb)
        if ($dbProblems.Count) { throw ("The settings are not valid:`n      - " + ($dbProblems -join "`n      - ")) }
    }
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

    $python = $null
    if (Test-BundledPython) {
        Write-Step 'Checking the bundled Python'
        $pyProblems = @(Test-RuntimeFiles (Split-Path $script:BundledPython) $script:BundledPythonRequiredFiles)
        if ($pyProblems.Count) {
            throw ("The bundled Python (runtime\python) is incomplete or damaged: $(($pyProblems | Select-Object -First 5) -join '; '). " +
                   'Download CompuLab-Server-Setup.exe again, check its SHA-256, and run it again (Repair).')
        }
        $probe = @(Invoke-Captured $script:BundledPython @('-c', 'import sys, django, MySQLdb, PIL, reportlab, openpyxl, waitress, whitenoise, dotenv; print(sys.version.split()[0], django.get_version())'))
        if ($LASTEXITCODE -ne 0) { throw "The bundled Python cannot load CompuLab's packages: $((@($probe) | Select-Object -Last 2) -join ' | ')" }
        $pyInfo = "$(@($probe)[-1])".Split(' ')
        Write-Ok "Python $($pyInfo[0]) with Django $($pyInfo[1]), bundled in runtime\python (no Python installation needed; files checked against the build)"
    } else {
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
    }

    Write-Step 'Checking the database server'
    if ($bundled) {
        $dbFileProblems = @(Test-RuntimeFiles $script:BundledDbDir $script:BundledDbRequiredFiles)
        if ($dbFileProblems.Count) {
            throw ("The bundled database (runtime\mariadb) is incomplete or damaged: $(($dbFileProblems | Select-Object -First 5) -join '; '). " +
                   'Nothing was changed. Download CompuLab-Server-Setup.exe again, check its SHA-256, and run it again (Repair).')
        }
        $mysql = Join-Path $script:BundledDbBin 'mariadb.exe'
        $dbService = if ($SkipServices) { $null } else { $script:BundledDbService }
        # Its port: the one it already uses / was given if that is free or
        # already CompuLab's own database, else the next free one. A port in
        # use by anything else is skipped and never touched.
        $wanted = [int]$S.DbPort
        $onWanted = Get-ListenerInfo $wanted
        $chosen = if ($onWanted -and (Test-ListenerIsBundledDb $onWanted)) { $wanted } else { Select-DbPort $wanted }
        for ($p = $wanted; $p -lt $chosen; $p++) {
            $l = Get-ListenerInfo $p
            Write-Note "Port $p is in use$(if ($l) { " by $(Get-ListenerDescription $l)" }): skipped. It was not stopped or changed."
        }
        if ($chosen -ne $wanted -and (Get-BundledDbPort)) { Write-Note "CompuLab's database moves from port $wanted to port $chosen (its data stays as it is)." }
        $S.DbPort = "$chosen"
        Write-Ok "CompuLab's own database: bundled MariaDB, port $chosen on 127.0.0.1 only, data in $($script:BundledDbData)$(if (Test-Path -LiteralPath $script:BundledDbMarker) { ' (existing, kept)' })"
        if ($switchingMode) {
            # Moving an installation from an external server to its own
            # database: never leave CompuLab data behind without being told.
            $oldClient = Find-DbClient 'client' $existingEnv['DB_PORT'] $existingEnv['DB_HOST']
            $hasData = if ($oldClient) { Test-DbHasCompuLabData $oldClient $existingEnv } else { $null }
            if ($hasData -eq $true -and -not $LeaveOldDatabase) {
                throw ("The current database ($($existingEnv['DB_NAME']) on $($existingEnv['DB_HOST']):$($existingEnv['DB_PORT'])) already holds CompuLab data. " +
                       'Switching to CompuLab''s own database would start with an empty one. Nothing was changed. To move the data: ' +
                       '1) back it up (installer\server\backup.ps1), 2) run this again with -DbMode bundled -LeaveOldDatabase, ' +
                       '3) restore that backup with installer\server\restore.ps1 -BackupFolder <folder>. The old database is never changed or deleted.')
            }
            if ($null -eq $hasData) {
                Write-Note "The current database ($($existingEnv['DB_HOST']):$($existingEnv['DB_PORT'])) could not be checked for CompuLab data (CompuLab could not sign in to it). It is not touched; if it holds CompuLab data, restore a backup into the new database with restore.ps1."
            }
        }
    } else {
        if ($switchingMode -and (Test-Path -LiteralPath $script:BundledDbMarker) -and -not $LeaveOldDatabase) {
            throw ("CompuLab's own database ($($script:BundledDbData)) holds this installation's data. Switching to an external server would start with an empty database. " +
                   'Nothing was changed. Back it up first (backup.ps1), run this again with -DbMode external -LeaveOldDatabase, then restore the backup (restore.ps1).')
        }
        # The client of the server on the database port (MariaDB 11 may only have
        # mariadb.exe; another product's client can fail against it).
        $mysql = Find-DbClient 'client' $S.DbPort $S.DbHost
        # An external server is only used, never installed, upgraded or replaced.
        if (-not $mysql -and -not $SkipDatabaseSetup) {
            throw ('No MariaDB or MySQL database server was found (mysql.exe / mariadb.exe). This copy has no bundled database: ' +
                   'install with CompuLab-Server-Setup.exe (it brings its own), or install MariaDB 11.4 LTS (or 10.11 LTS) 64-bit from mariadb.org ' +
                   '(MSI package, keep "Install as service" ticked, choose a root password) - or MySQL 8.0.11 or newer - then run this again. ' +
                   'XAMPP''s MariaDB 10.4 is too old. (-SkipDatabaseSetup if the CompuLab database already exists on another computer.)')
        }
        $dbLocal = $S.DbHost -in @('127.0.0.1', 'localhost')
        $listener = if ($dbLocal) { Get-ListenerInfo ([int]$S.DbPort) } else { $null }
        $allowedService = if ($S.DbServiceName -notin @('auto', 'none')) { $S.DbServiceName } else { '' }
        if ($listener) {
            # Who owns the port is checked before any database service is started
            # or changed: XAMPP's or another program's database is refused untouched.
            $dbProblem = Test-DbListener $listener $S.DbHost ([int]$S.DbPort) $allowedService
            if ($dbProblem) { throw $dbProblem }
        }
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
            $dbProblem = Test-DbListener $listener $S.DbHost ([int]$S.DbPort) $allowedService
            if ($dbProblem) { throw $dbProblem }
            if ($listener.ServiceName -and $dbService -and $listener.ServiceName -ne $dbService) {
                throw ("Port $($S.DbPort) belongs to the service '$($listener.ServiceName)', not to '$dbService'. " +
                       "Run the installer with -DbServiceName $($listener.ServiceName), or give the port of '$dbService' with -DbPort.")
            }
            $who = if ($listener.ServiceName) { "the $($listener.ServiceName) service" } elseif ($listener.ProcessPath) { $listener.ProcessPath } else { "process $($listener.ProcessId)" }
            Write-Ok "Port $($S.DbPort) is served by $who"
            # Now that the server is up: its own client.
            $own = Find-DbClient 'client' $S.DbPort $S.DbHost
            if ($own) { $mysql = $own }
        }
    }
    if ($mysql) { Write-Ok "Database client: $mysql" }

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

    # A CompuLab service of the same name that belongs to another folder is
    # never replaced or removed: stop here, before any change.
    if (-not $SkipServices) {
        foreach ($name in $script:WebService, $script:WorkerService, $script:BundledDbService) {
            $foreign = Get-ForeignServicePath $name
            if ($foreign) { throw "A Windows service named $name already exists for another CompuLab folder ($foreign). It was not changed. Uninstall that CompuLab first, or install this one with -SkipServices." }
        }
    }
    $webInstalled = [bool](Get-OwnService $script:WebService)
    if (-not $webInstalled) {
        $owner = Get-PortOwner ([int]$S.Port)
        if ($owner) { throw "Port $($S.Port) is already used by '$owner'. Stop that program or choose another port with -Port." }
        Write-Ok "Port $($S.Port) is free"
    }

    # ------------------------------------------------------------ 2. venv + packages
    if ($python) {
        # Plain folder copy: a venv of the installed Python. (The bundled
        # Python already has every package: nothing to install.)
        Write-Step 'Installing the Python environment'
        $venvDir = Join-Path $script:AppDir 'venv'
        if (Test-Path $venvDir) {
            $venvProblem = Test-VenvMatchesPython $venvDir $python
            if ($venvProblem) {
                Write-Note "The existing Python environment (venv) is not reused: $venvProblem."
                Stop-CompuLabServices   # they run from it
                $oldVenv = Move-VenvAside $venvDir
                Write-Note "Moved it to $oldVenv (it holds no CompuLab data; delete it once CompuLab works). A new one is made with Python $($python.Version)."
            } else { Write-Ok "Existing Python environment (Python $($python.Version)) reused" }
        }
        if (-not (Test-Path $script:VenvPython)) {
            Invoke-Logged $python.Command[0] (@($python.Command | Select-Object -Skip 1) + @('-m', 'venv', (Join-Path $script:AppDir 'venv')))
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $script:VenvPython)) { throw 'Could not create the Python environment (venv).' }
        }
        $source = Install-PythonPackages (Join-Path $PSScriptRoot 'requirements-server.txt')
        Write-Ok "Packages installed ($source)"
    }

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
        if ($bundled) {
            # CompuLab's own database: its address is decided above (127.0.0.1,
            # its own free port); credentials are never changed here.
            $now = Read-DotEnv
            foreach ($pair in @(@('DB_HOST', '127.0.0.1'), @('DB_PORT', "$($S.DbPort)"))) {
                if ($now[$pair[0]] -ne $pair[1]) {
                    Set-DotEnvValue $pair[0] $pair[1]
                    Write-Note "$($pair[0]) changed from '$($now[$pair[0]])' to '$($pair[1])' (CompuLab's own database)."
                }
            }
        }
    }
    Set-DotEnvValue 'COMPULAB_DB_MODE' $dbMode
    # Where Repair, Update, "Back Up CompuLab Now" and restore put backups.
    Set-DotEnvValue 'COMPULAB_BACKUP_ROOT' "$($S.BackupRoot)"
    $envValues = Read-DotEnv
    $siteUrl = $envValues['SITE_URL']
    $missingDb = @($script:DbEnvKeys | Where-Object { -not $envValues[$_] })
    if ($missingDb.Count) { throw ".env has no $($missingDb -join ', ') after configuring it; the database was not touched." }

    # ------------------------------------------------------------ 4. database
    if ($bundled) {
        Write-Step "Setting up CompuLab's own database"
        $db = Initialize-BundledDb ([int]$envValues['DB_PORT']) -AsService:(-not $SkipServices)
        if ($SkipServices) {
            Write-Note 'Without Windows services (-SkipServices) the database runs as a background process until this computer restarts; run-foreground.ps1 starts it again.'
        }
        $signIn = Get-DbSignIn $mysql $script:DbAdminCnf
        if (-not $signIn.Version) {
            throw "CompuLab's database started but refused its administrator: $(ConvertTo-DbErrorText $signIn.Lines '127.0.0.1' $envValues['DB_PORT'] (Read-DbAdminCnf).Password)"
        }
        Write-Ok "Database server: $(Assert-SupportedDbVersion $signIn.Version), listening on 127.0.0.1:$($db.Port) only"
        # The application's own database and user (idempotent; also puts the
        # password from .env back if it no longer matches). The user may use
        # this one database only.
        $r = Invoke-WithStdin $mysql @("--defaults-extra-file=$($script:DbAdminCnf)", '--batch') (Get-DbSetupSql $envValues['DB_NAME'] $envValues['DB_USER'] $envValues['DB_PASSWORD']) @($envValues['DB_PASSWORD'])
        if ($r.ExitCode -ne 0) { throw "Creating the database or its user failed: $((@($r.Lines) | Select-Object -Last 3) -join ' | ')" }
        Write-Ok "Database '$($envValues['DB_NAME'])' and user '$($envValues['DB_USER'])' are ready"
        $r = Invoke-WithStdin $mysql @("--defaults-extra-file=$($script:DbAdminCnf)", '--batch') (Get-BundledDbHardeningSql -DropTestDatabase:([bool]$db.Created))
        if ($r.ExitCode -ne 0) { throw "Removing the rights every account has on MariaDB's test databases failed: $((@($r.Lines) | Select-Object -Last 3) -join ' | ')" }
        Write-Ok "No account has rights on MariaDB's test databases$(if ($db.Created) { ' (the empty test database was removed)' })"
        # Only a database that started and answered is started at every boot.
        if (-not $SkipServices) { Set-BundledDbAutoStart }
        # After an update with newer MariaDB files: its system tables follow
        # (nothing to do otherwise).
        $up = @(Invoke-Captured (Join-Path $script:BundledDbBin 'mariadb-upgrade.exe') @("--defaults-extra-file=$($script:DbAdminCnf)", '--silent'))
        if ($LASTEXITCODE -ne 0) { throw "Updating the database system tables (mariadb-upgrade) failed: $((@($up) | Select-Object -Last 3) -join ' | ')" }
    } elseif (-not $SkipDatabaseSetup) {
        Write-Step 'Preparing the database'
        $fromVariable = [bool]$env:COMPULAB_DB_ROOT_PASSWORD
        if (-not $fromVariable -and $NonInteractive) { throw 'Set the environment variable COMPULAB_DB_ROOT_PASSWORD (MariaDB root password) for an unattended install, or use -SkipDatabaseSetup.' }
        $rootCnf = $null; $plainRoot = $null
        try {
            for ($attempt = 1; ; $attempt++) {
                if ($fromVariable) { $plainRoot = $env:COMPULAB_DB_ROOT_PASSWORD }
                else {
                    if ($attempt -eq 1) { Write-Note 'Click into this window before typing: each character shows as * (the password is not saved or logged).' }
                    $plainRoot = Read-SecretText 'MariaDB/MySQL root password (used once, not saved)'
                }
                $rootCnf = New-MySqlDefaultsFile 'root' $plainRoot $envValues['DB_HOST'] $envValues['DB_PORT']
                $signIn = Get-DbSignIn $mysql $rootCnf
                if ($signIn.Version) { break }
                Remove-Item $rootCnf -Force -ErrorAction SilentlyContinue; $rootCnf = $null
                $why = ConvertTo-DbErrorText $signIn.Lines $envValues['DB_HOST'] $envValues['DB_PORT'] $plainRoot
                # Only a refused password is worth typing again; anything else
                # (server stopped, wrong port, ...) has to be fixed first.
                if ($fromVariable -or $attempt -ge 3 -or $why -notmatch 'ERROR 1045') { throw "Could not sign in to the database server as root. $why" }
                Write-Note $why
                Write-Note "Try again (attempt $($attempt + 1) of 3)."
            }
            Write-Ok "Database server: $(Assert-SupportedDbVersion $signIn.Version)"
            Get-DbSetupSql $envValues['DB_NAME'] $envValues['DB_USER'] $envValues['DB_PASSWORD'] | & $mysql "--defaults-extra-file=$rootCnf"
            if ($LASTEXITCODE -ne 0) { throw 'Creating the database or its user failed (see the message above).' }
            Write-Ok "Database '$($envValues['DB_NAME'])' and user '$($envValues['DB_USER'])' are ready"
        } finally {
            if ($rootCnf) { Remove-Item $rootCnf -Force -ErrorAction SilentlyContinue }
            $plainRoot = $null
        }
    } elseif ($mysql) {
        # Existing database: still refuse a server version this Django can't use.
        $appCnf = New-MySqlDefaultsFile $envValues['DB_USER'] $envValues['DB_PASSWORD'] $envValues['DB_HOST'] $envValues['DB_PORT']
        try {
            $signIn = Get-DbSignIn $mysql $appCnf
            if ($signIn.Version) { Write-Ok "Database server: $(Assert-SupportedDbVersion $signIn.Version)" }
            else {
                $why = ConvertTo-DbErrorText $signIn.Lines $envValues['DB_HOST'] $envValues['DB_PORT'] $envValues['DB_PASSWORD'] $envValues['DB_USER']
                Write-Note "Could not check the database server version with the credentials in .env. $why"
            }
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
        $null = @(Invoke-Captured (Get-AppPython) @('-c', 'import waitress'))
        if ($LASTEXITCODE -ne 0) { throw "The waitress package is missing from $(Get-AppPython) (package install incomplete)." }
        # SYSTEM runs CompuLab's Python from this folder: only Administrators
        # and SYSTEM may change it (on a C:\ folder, Windows otherwise lets
        # every signed-in user modify it).
        & icacls @(Get-AppFolderAclArgs) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not restrict the permissions of $($script:AppDir) (icacls exit code $LASTEXITCODE)." }
        Write-Ok "Program folder: users may read it, only Administrators and SYSTEM may change it"
        foreach ($d in Get-ServiceDefinitions ([int]$S.Port)) {
            $exe = Join-Path $script:ServiceDir "$($d.Id).exe"
            $xml = Join-Path $script:ServiceDir "$($d.Id).xml"
            if (Get-OwnService $d.Id) { Invoke-Quiet $exe @('stop') | Out-Null; Invoke-Quiet $exe @('uninstall') | Out-Null }
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
        Write-Note "The database port ($($S.DbPort)) is NOT opened$(if ($bundled) { ' (CompuLab''s database listens on 127.0.0.1 only)' }): only CompuLab on this computer uses it. Never forward any port on the router."
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
    if (-not $SkipServices -and (Get-OwnService $script:WebService)) {
        Write-Step 'Checking that CompuLab answers'
        if (Wait-Healthy "http://127.0.0.1:$($S.Port)/healthz" 90) { Write-Ok 'CompuLab is running' }
        else { Write-Note 'No answer yet. Check logs\ and Services > CompuLab Web, or run installer\server\server-status.ps1.' }
    }

    $remote = (Read-DotEnv)['COMPULAB_REMOTE_URL']
    Write-Host "`nCompuLab is installed." -ForegroundColor Green
    Write-Host "  Campus address (lab PCs, staff): $siteUrl"
    Write-Host "  Server status page (Admins):     $siteUrl/system/status/"
    if ($remote) { Write-Host "  Remote address (Tailscale):      $remote" }
    if ($bundled) { Write-Host "  Database:                        CompuLab's own MariaDB, 127.0.0.1:$($envValues['DB_PORT']) (service $($script:BundledDbService)), data in $($script:BundledDbData)" }
    else { Write-Host "  Database:                        $($envValues['DB_NAME']) on $($envValues['DB_HOST']):$($envValues['DB_PORT'])$(if ($dbService) { " (service $dbService)" })" }
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
    $stopped = @($script:WebService, $script:WorkerService | Where-Object { $s = Get-OwnService $_; $s -and $s.Status -ne 'Running' })
    if ($stopped.Count) {
        Write-Host "  The CompuLab services are stopped ($($stopped -join ', ')), so the website is offline until the installer completes." -ForegroundColor Red
    }
    if ($logPath) { Write-Host "  Full log: $logPath" -ForegroundColor Red }
} finally {
    Stop-InstallLog
}
if ($PauseAtEnd -and -not $NonInteractive) { Read-Host "`nPress Enter to close this window" | Out-Null }
exit $exitCode
