<#
.SYNOPSIS
  End-to-end test of the server installer, without administrator rights and
  without touching this computer's own database or services.

      powershell -ExecutionPolicy Bypass -File installer\tests\test-server-install.ps1

  Needs: a build (installer\build\build-installers.ps1, for the staged
  payload), Inno Setup 6, and MySQL 8.x or MariaDB 10.5+ server programs
  installed (only their files are used: a throwaway database server is
  started in a temporary folder on a free port and removed afterwards).

  It compiles a test build of CompuLab-Server-Setup.exe (per-user; it skips
  the Windows services, firewall rule and backup task, which need
  administrator rights) and checks:
    1. silent install: settings, Python environment, database, migrations,
       first Administrator, install log without passwords;
    2. the installed site answers (/healthz, login page, /healthz/ready);
    3. updating with a newer setup version: secrets kept, a backup is made
       first, nothing duplicated, the new version registered;
    4. restore.ps1 brings back the backed-up data; the nightly backup
       command (backup.ps1 -Log) logs and reports success and failure;
    5. invalid settings and a busy port stop the installer before any change;
    6. uninstall removes the program files and keeps the data.
#>
[CmdletBinding()]
param([string]$IsccPath = '', [switch]$KeepFiles)

# Database and setup programs log normal progress on stderr, which Windows
# PowerShell 5.1 would turn into errors under 'Stop'; every check below
# throws explicitly instead.
$ErrorActionPreference = 'Continue'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Payload = Join-Path $Repo 'installer\build\work\server-payload'
$Tmp = Join-Path $env:TEMP ("compulab-server-install-test-" + (Get-Date -Format 'HHmmss'))
$App = Join-Path $Tmp 'CompuLab'
$script:passed = 0; $script:failed = @()
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
    catch { $script:failed += $Name; Write-Host "  [FAIL] $Name`n         $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-FreePort { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p }
function Read-Env([string]$Path) {
    $v = @{}; foreach ($line in Get-Content $Path) { if ($line -match '^([A-Z_]+)=(.*)$') { $v[$Matches[1]] = $Matches[2] } }; return $v
}

# ------------------------------------------------------------ safety + prerequisites
if (Get-Service -Name 'CompuLabWeb', 'CompuLabWorker' -ErrorAction SilentlyContinue) {
    throw 'CompuLab services are installed on this computer: run this test on a development PC only.'
}
if (-not (Test-Path (Join-Path $Payload 'manage.py'))) { throw "No staged payload in ${Payload}: run installer\build\build-installers.ps1 first." }
$iscc = @($IsccPath, (Join-Path $Repo 'installer\build\tools\InnoSetup6\ISCC.exe'), "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
          "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 not found (installer\build\build-installers.ps1 -InstallInnoSetup, or pass -IsccPath).' }
$mysqld = @(Get-ChildItem "$env:ProgramFiles\MySQL\MySQL Server 8*\bin\mysqld.exe", "$env:ProgramFiles\MariaDB 1*\bin\mysqld.exe", "$env:ProgramFiles\MariaDB 1*\bin\mariadbd.exe" -ErrorAction SilentlyContinue) | Select-Object -First 1
if (-not $mysqld) { throw 'No MySQL 8 / MariaDB 10.5+ server program found to start a throwaway database.' }
$bin = $mysqld.DirectoryName
$mysql = @('mysql.exe', 'mariadb.exe') | ForEach-Object { Join-Path $bin $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
New-Item -ItemType Directory -Force $Tmp | Out-Null
Write-Host "Test folder: $Tmp"

$dbPort = Get-FreePort
$webPort = Get-FreePort
$rootPw = 'Root-' + [guid]::NewGuid().ToString('N')
$adminPw = 'Adm1n-' + [guid]::NewGuid().ToString('N')
$dbProc = $null; $web = $null
$rootCnf = Join-Path $Tmp 'root.cnf'
try {
    # ------------------------------------------------------------ throwaway database server
    Write-Host "`nStarting a throwaway database server ($($mysqld.Name) from $bin) on port $dbPort" -ForegroundColor Cyan
    $data = Join-Path $Tmp 'dbdata'
    if ($mysqld.Name -eq 'mysqld.exe' -and $bin -like '*MySQL*') {
        & $mysqld.FullName --initialize-insecure "--datadir=$data" --console 2>&1 | Out-Null
    } else {
        & (Join-Path $bin 'mariadb-install-db.exe') "--datadir=$data" 2>&1 | Out-Null
    }
    $dbProc = Start-Process $mysqld.FullName -ArgumentList "--datadir=`"$data`"", "--port=$dbPort", '--bind-address=127.0.0.1', '--mysqlx=OFF',
        "--log-error=`"$Tmp\db.err`"" -PassThru -WindowStyle Hidden
    [IO.File]::WriteAllText($rootCnf, "[client]`nuser=root`nhost=127.0.0.1`nport=$dbPort`n")
    $ready = $false
    foreach ($i in 1..60) { & $mysql "--defaults-extra-file=$rootCnf" -e 'SELECT 1' 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $ready = $true; break }; Start-Sleep 1 }
    if (-not $ready) { throw "The throwaway database did not start (see $Tmp\db.err)." }
    & $mysql "--defaults-extra-file=$rootCnf" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$rootPw';"
    [IO.File]::WriteAllText($rootCnf, "[client]`nuser=root`npassword=$rootPw`nhost=127.0.0.1`nport=$dbPort`n")
    Write-Host "    $(& $mysql "--defaults-extra-file=$rootCnf" -N -e 'SELECT VERSION()')"

    # ------------------------------------------------------------ test build of the setup
    $builds = @{}
    foreach ($v in '0.0.0', '0.0.1') {
        $out = Join-Path $Tmp "out-$v"
        & $iscc /Q /DTestBuild "/DPayload=$Payload" "/DAppVersion=$v-test" "/DFileVersion=$v.1" "/DOutputDir=$out" (Join-Path $Repo 'installer\build\CompuLab-Server.iss') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Compiling the test build $v failed." }
        $builds[$v] = Get-ChildItem $out -Filter '*.exe' | Select-Object -First 1
    }
    $setup = $builds['0.0.0']
    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6F0B2D52-3C61-4E1B-9A57-2B7C2B1D7E57}_is1'   # test build AppId
    $psArgs = "-SkipServices -SkipFirewall -SkipBackupTask -DbServiceName none -DbPort $dbPort"
    $env:COMPULAB_DB_ROOT_PASSWORD = $rootPw
    $env:DJANGO_SUPERUSER_EMAIL = 'installer.test.admin@gmail.com'
    $env:DJANGO_SUPERUSER_PASSWORD = $adminPw
    function Invoke-Setup([string]$Log) {
        $p = Start-Process $setup.FullName -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$App`"",
            '/SERVERADDRESS=127.0.0.1', "/PORT=$webPort", "/PSARGS=`"$psArgs`"", "/LOG=`"$Log`"" -Wait -PassThru
        return $p.ExitCode
    }
    function Get-DbCount([string]$Sql) {
        $envv = Read-Env (Join-Path $App '.env')
        $cnf = Join-Path $Tmp 'app.cnf'
        [IO.File]::WriteAllText($cnf, "[client]`nuser=$($envv.DB_USER)`npassword=$($envv.DB_PASSWORD)`nhost=127.0.0.1`nport=$dbPort`n")
        try { return [int](& $mysql "--defaults-extra-file=$cnf" -N -B $envv.DB_NAME -e $Sql) } finally { Remove-Item $cnf -Force }
    }

    Write-Host "`n1. Silent install with CompuLab-Server-Setup (test build)" -ForegroundColor Cyan
    $code = Invoke-Setup (Join-Path $Tmp 'setup-1.log')
    $setupLog = Get-Content (Join-Path $Tmp 'setup-1.log') -Raw
    Test-Case 'setup finished and install-server.ps1 succeeded' {
        Assert-True ($code -eq 0) "setup exit code $code"
        Assert-True ($setupLog -notmatch 'install-server.ps1 failed') 'install-server.ps1 reported a failure (see logs in the test folder)'
    }
    Test-Case 'program files, Python environment and settings are in place' {
        foreach ($f in 'manage.py', 'venv\Scripts\python.exe', 'venv\Scripts\waitress-serve.exe', '.env', 'installer\server\bin\WinSW-x64.exe', 'staticfiles') {
            Assert-True (Test-Path (Join-Path $App $f)) "missing $f"
        }
        $e = Read-Env (Join-Path $App '.env')
        Assert-True ($e.DJANGO_DEBUG -eq 'False') 'DEBUG is not off'
        Assert-True ($e.SITE_URL -eq "http://127.0.0.1:$webPort") "SITE_URL $($e.SITE_URL)"
        Assert-True ($e.DJANGO_SECRET_KEY.Length -ge 50 -and $e.DB_PASSWORD.Length -ge 32 -and $e.PC_AGENT_SHARED_SECRET.Length -ge 40) 'weak or missing secrets'
    }
    Test-Case 'packages came from the bundled offline folder; Python reported as 64-bit' {
        $log = Get-ChildItem (Join-Path $App 'logs') -Filter 'install-*.log' | Sort-Object Name | Select-Object -First 1
        $t = Get-Content $log.FullName -Raw
        Assert-True ($t -match 'OK: Packages installed \(offline package folder\)') 'not installed offline'
        Assert-True ($t -match 'OK: Python 3\.1[123] 64-bit') 'Python line missing'
    }
    Test-Case 'no developer tests or build tools installed; build record present' {
        $tests = @(Get-ChildItem $App -Recurse -File -Include 'tests.py', 'test_*.py' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\venv\\' })
        Assert-True ($tests.Count -eq 0) "test modules installed: $(($tests | Select-Object -First 5 | ForEach-Object { $_.FullName.Substring($App.Length + 1) }) -join ', ')"
        foreach ($d in 'installer\tests', 'installer\build', 'lab_pc_agent\tests') { Assert-True (-not (Test-Path (Join-Path $App $d))) "$d installed" }
        $b = Get-Content (Join-Path $App 'BUILDINFO.json') -Raw | ConvertFrom-Json
        Assert-True ($b.commit -match '^[0-9a-f]{40}$' -and $b.version) "BUILDINFO: $($b | ConvertTo-Json -Compress)"
    }
    Test-Case 'database created, every migration applied, one Administrator' {
        $expected = @(Get-ChildItem $App -Recurse -Filter '0*.py' | Where-Object { $_.Directory.Name -eq 'migrations' -and $_.FullName -notmatch '\\venv\\' }).Count
        $applied = Get-DbCount "SELECT COUNT(*) FROM django_migrations WHERE app IN ('accounts','labs','scheduling','issues','notifications','cloud_sync','system')"
        Assert-True ($applied -eq $expected) "applied $applied of $expected project migrations"
        Assert-True ((Get-DbCount 'SELECT COUNT(*) FROM accounts_user WHERE is_superuser = 1') -eq 1) 'superuser count'
    }
    Test-Case 'install logs contain no passwords' {
        foreach ($log in Get-ChildItem (Join-Path $App 'logs') -Filter 'install-*.log') {
            $t = Get-Content $log.FullName -Raw
            Assert-True ($t -notmatch [regex]::Escape($rootPw) -and $t -notmatch [regex]::Escape($adminPw)) "password in $($log.Name)"
        }
    }

    Write-Host "`n2. The installed site answers" -ForegroundColor Cyan
    $web = Start-Process (Join-Path $App 'venv\Scripts\waitress-serve.exe') -ArgumentList "--listen=127.0.0.1:$webPort", 'compulab.wsgi:application' `
        -WorkingDirectory $App -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Tmp 'web.err')
    Test-Case '/healthz, login page and /healthz/ready (database OK)' {
        $ok = $false
        foreach ($i in 1..60) { try { $ok = (Invoke-WebRequest "http://127.0.0.1:$webPort/healthz" -UseBasicParsing -TimeoutSec 3).Content.Trim() -eq 'ok' } catch { }; if ($ok) { break }; Start-Sleep 1 }
        Assert-True $ok '/healthz did not answer'
        Assert-True ((Invoke-WebRequest "http://127.0.0.1:$webPort/accounts/login/" -UseBasicParsing).StatusCode -eq 200) 'login page'
        $r = Invoke-RestMethod "http://127.0.0.1:$webPort/healthz/ready"
        Assert-True ($r.database.ok -eq $true) 'database not OK'
        Assert-True ($r.headline -like 'Local system operational*' -or $r.headline -like '*worker*') "headline: $($r.headline)"
    }
    Stop-Process -Id $web.Id -Force; $web = $null

    Write-Host "`n3. Updating with a newer setup (0.0.0 -> 0.0.1)" -ForegroundColor Cyan
    $before = Read-Env (Join-Path $App '.env')
    Add-Content (Join-Path $App 'compulab\STALE_FILE_FROM_OLD_VERSION.py') '# should be removed by an update'
    $setup = $builds['0.0.1']
    $code = Invoke-Setup (Join-Path $Tmp 'setup-2.log')
    Test-Case 'update succeeded, kept every secret and registered the new version' {
        Assert-True ($code -eq 0 -and (Get-Content (Join-Path $Tmp 'setup-2.log') -Raw) -notmatch 'install-server.ps1 failed') 'update failed'
        $after = Read-Env (Join-Path $App '.env')
        foreach ($k in 'DJANGO_SECRET_KEY', 'DB_PASSWORD', 'PC_AGENT_SHARED_SECRET', 'SITE_URL') { Assert-True ($before[$k] -eq $after[$k]) "$k changed" }
        Assert-True ((Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue).DisplayVersion -eq '0.0.1-test') 'Apps list still shows the old version'
    }
    Test-Case 'a backup was taken before updating' {
        $b = Get-ChildItem (Join-Path $App 'backups') -Directory -Filter 'compulab-*' | Select-Object -First 1
        Assert-True $b 'no backup folder'
        $sql = Join-Path $b.FullName 'database.sql'
        Assert-True ((Test-Path $sql) -and (Get-Item $sql).Length -gt 10000) 'database.sql missing or empty'
        Assert-True (Test-Path (Join-Path $b.FullName 'env.txt')) 'settings not backed up'
    }
    Test-Case 'old program files are cleaned up, data is not duplicated' {
        Assert-True (-not (Test-Path (Join-Path $App 'compulab\STALE_FILE_FROM_OLD_VERSION.py'))) 'stale file left behind'
        Assert-True ((Get-DbCount 'SELECT COUNT(*) FROM accounts_user WHERE is_superuser = 1') -eq 1) 'second Administrator created'
    }

    Write-Host "`n4. Restore" -ForegroundColor Cyan
    Test-Case 'restore.ps1 brings back the backed-up data' {
        $backup = Get-ChildItem (Join-Path $App 'backups') -Directory -Filter 'compulab-*' | Sort-Object Name | Select-Object -First 1
        & (Join-Path $App 'venv\Scripts\python.exe') (Join-Path $App 'manage.py') shell -c "import datetime; from labs.models import Lab; Lab.objects.create(name='Added after backup', opening_time=datetime.time(7), closing_time=datetime.time(17))" 2>$null
        Assert-True ((Get-DbCount "SELECT COUNT(*) FROM labs_lab WHERE name = 'Added after backup'") -eq 1) 'marker not created'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $App 'installer\server\restore.ps1') -BackupFolder $backup.FullName -Force *> (Join-Path $Tmp 'restore.log')
        Assert-True ($LASTEXITCODE -eq 0) "restore exit code $LASTEXITCODE (see restore.log)"
        Assert-True ((Get-DbCount "SELECT COUNT(*) FROM labs_lab WHERE name = 'Added after backup'") -eq 0) 'data after the backup is still there'
        Assert-True (Test-Path (Join-Path $App 'backups\before-restore')) 'no safety backup before restoring'
    }
    Test-Case 'nightly backup command (backup.ps1 -Log, as the task runs it): logs, exit code 0, no password in the log' {
        $nightly = Join-Path $Tmp 'nightly'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $App 'installer\server\backup.ps1') -BackupRoot $nightly -Log *> (Join-Path $Tmp 'nightly.out')
        Assert-True ($LASTEXITCODE -eq 0) "exit code $LASTEXITCODE"
        Assert-True (Test-Path (Join-Path (Get-ChildItem $nightly -Directory | Select-Object -First 1).FullName 'database.sql')) 'no backup made'
        $log = Get-ChildItem (Join-Path $App 'logs') -Filter 'backup-*.log' | Sort-Object Name | Select-Object -Last 1
        Assert-True $log 'no logs\backup-*.log'
        $t = Get-Content $log.FullName -Raw
        Assert-True ($t -match 'Done\. Backups kept') 'log does not show the result'
        Assert-True ($t -notmatch [regex]::Escape((Read-Env (Join-Path $App '.env')).DB_PASSWORD)) 'database password in the backup log'
    }
    Test-Case 'nightly backup failure: exit code 1 (Task Scheduler shows it) and the reason in the log' {
        $notADir = Join-Path $Tmp 'not-a-folder'; Set-Content $notADir 'x'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $App 'installer\server\backup.ps1') -BackupRoot (Join-Path $notADir 'sub') -Log *> (Join-Path $Tmp 'nightly-fail.out')
        Assert-True ($LASTEXITCODE -eq 1) "exit code $LASTEXITCODE"
        $log = Get-ChildItem (Join-Path $App 'logs') -Filter 'backup-*.log' | Sort-Object Name | Select-Object -Last 1
        Assert-True ((Get-Content $log.FullName -Raw) -match 'Backup FAILED') 'failure not in the log'
    }

    Write-Host "`n5. The installer stops before changing anything" -ForegroundColor Cyan
    $installer = Join-Path $App 'installer\server\install-server.ps1'
    $envHash = (Get-FileHash (Join-Path $App '.env')).Hash
    Test-Case 'invalid settings: clear message, exit code 1, .env unchanged' {
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $installer -NonInteractive -SkipServices -SkipFirewall -SkipBackupTask -DbServiceName none -Port 70000 -DbName "bad'name" 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 1) "exit code $LASTEXITCODE"
        Assert-True ($o -match 'not valid' -and $o -match 'Port must be' -and $o -match 'DbName') 'message does not explain the problems'
        Assert-True ((Get-FileHash (Join-Path $App '.env')).Hash -eq $envHash) '.env changed'
    }
    Test-Case 'busy web port: names the program using it, exit code 1' {
        $busy = Get-FreePort
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $busy); $listener.Start()
        try { $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $installer -NonInteractive -SkipServices -SkipFirewall -SkipBackupTask -DbServiceName none -DbPort $dbPort -Port $busy 2>&1 | Out-String }
        finally { $listener.Stop() }
        Assert-True ($LASTEXITCODE -eq 1 -and $o -match "Port $busy is already used") "exit $LASTEXITCODE; $($o.Trim() | Select-Object -Last 1)"
        Assert-True ((Get-FileHash (Join-Path $App '.env')).Hash -eq $envHash) '.env changed'
    }
    Test-Case 'services/firewall without administrator rights: refused with a clear message' {
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $installer -NonInteractive 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 1 -and $o -match 'Administrator') 'not refused'
    }

    Write-Host "`n6. Uninstall" -ForegroundColor Cyan
    Test-Case 'uninstall removes the program files and keeps the data' {
        $unins = Get-ChildItem $App -Filter 'unins*.exe' | Select-Object -First 1
        Assert-True $unins 'no uninstaller registered'
        Start-Process $unins.FullName -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
        foreach ($i in 1..30) { if (-not (Test-Path (Join-Path $App 'manage.py'))) { break }; Start-Sleep 1 }   # the uninstaller finishes from a temp copy
        Assert-True (-not (Test-Path (Join-Path $App 'manage.py'))) 'program files still there'
        foreach ($keep in '.env', 'backups', 'logs') { Assert-True (Test-Path (Join-Path $App $keep)) "$keep was deleted" }
        Assert-True ((Get-DbCount 'SELECT COUNT(*) FROM accounts_user') -ge 1) 'database data lost'
    }
} finally {
    if ($web) { Stop-Process -Id $web.Id -Force -ErrorAction SilentlyContinue }
    if ($dbProc) {
        & (Join-Path $bin 'mysqladmin.exe') "--defaults-extra-file=$rootCnf" shutdown 2>$null | Out-Null
        Start-Sleep 3
        if (-not $dbProc.HasExited) { Stop-Process -Id $dbProc.Id -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item Env:\COMPULAB_DB_ROOT_PASSWORD, Env:\DJANGO_SUPERUSER_EMAIL, Env:\DJANGO_SUPERUSER_PASSWORD -ErrorAction SilentlyContinue
    if (-not $KeepFiles -and -not $script:failed.Count) { Start-Sleep 2; Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host "`n$($script:passed) passed, $($script:failed.Count) failed" -ForegroundColor $(if ($script:failed.Count) { 'Red' } else { 'Green' })
if ($KeepFiles -or $script:failed.Count) { Write-Host "Test files: $Tmp" }
exit [int]($script:failed.Count -gt 0)
