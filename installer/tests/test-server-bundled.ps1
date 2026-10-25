<#
.SYNOPSIS
  End-to-end test of the server setup with its BUNDLED runtime (own Python,
  own MariaDB), without administrator rights and without any preinstalled
  Python, database server, root password or internet.

      powershell -ExecutionPolicy Bypass -File installer\tests\test-server-bundled.ps1 -Payload <staged>\server-payload

  The payload must contain runtime\ (stage-test-payload.ps1 -WithRuntime, or
  a build's work\server-payload). A test build of CompuLab-Server-Setup.exe
  is compiled (per-user; no Windows services, firewall rule or backup task:
  CompuLab's database then runs as a background process of the test, in the
  test folder, removed afterwards). Checked:
    1. fresh install: no prerequisites, port conflicts skipped (the programs
       on them never touched), an interrupted earlier attempt recovered;
    2. the dedicated database: 127.0.0.1 only, no passwords on command lines
       or in logs, restricted application user, root local only, protected
       .env / db-admin.cnf, its own dump tool;
    3. the site answers, migrations applied, first Administrator created;
    4. repair: no data loss, no second initialization, no second Admin;
    5. backup and restore against the dedicated instance;
    6. update with a newer setup: CompuLab stopped first, data kept;
    7. failures: damaged / incomplete runtime refused before any change;
       database start failure reported with its log; lost administrator
       sign-in reset offline without data loss;
    8. uninstall keeps the data; reinstall brings it back;
    9. the database servers of other programs on this PC are unchanged.
#>
[CmdletBinding()]
param([string]$IsccPath = '', [switch]$KeepFiles, [string]$Payload = '',
      # Ask for port 3306 and occupy 3308 too: on a PC where MySQL listens on
      # 3306 and another program's database on 3307 (read-only, never
      # touched), the setup must skip 3306, 3307 and 3308.
      [switch]$RealPorts,
      # Run although CompuLab services are installed on this PC (e.g. a test
      # installation in C:\CompuLab). The test never starts, stops or changes
      # any Windows service; its database is its own process on another port.
      [switch]$EvenIfInstalled)

$ErrorActionPreference = 'Continue'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Payload) { $Payload = Join-Path $Repo 'installer\build\work\server-payload' }
$Tmp = Join-Path $env:TEMP ("compulab-bundled-test-" + (Get-Date -Format 'HHmmss'))
$App = Join-Path $Tmp 'CompuLab'
$script:passed = 0; $script:failed = @()
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
    catch { $script:failed += $Name; Write-Host "  [FAIL] $Name`n         $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Read-Env([string]$Path) {
    $v = @{}; foreach ($line in Get-Content $Path) { if ($line -match '^([A-Z_]+)=(.*)$') { $v[$Matches[1]] = $Matches[2] } }; return $v
}
function Get-FreeTcpPort { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p }
function Test-PortFree([int]$p) {
    try { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $p); $l.Start(); $l.Stop(); return $true } catch { return $false }
}
function Get-OtherDbState {
    # Read-only snapshot of every other database server on this PC.
    $svc = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -match '(?i)(mysqld|mariadbd)' -and $_.Name -ne 'CompuLabMariaDB' } |
        ForEach-Object { "$($_.Name)=$($_.State)/$($_.ProcessId)" })
    $listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 3306, 3307 } | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)/$($_.OwningProcess)" })
    return (@($svc | Sort-Object) + @($listen | Sort-Object)) -join '; '
}
function Get-OurDbProcess {
    $prefix = (Join-Path $App 'runtime\mariadb\bin\')
    return @(Get-CimInstance Win32_Process -Filter "Name = 'mariadbd.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}
function Invoke-Db([string]$Cnf, [string]$Sql, [string]$Database = '') {
    $client = Join-Path $App 'runtime\mariadb\bin\mariadb.exe'
    $a = @("--defaults-extra-file=$Cnf", '-N', '-B', '-e', $Sql)
    if ($Database) { $a += $Database }
    return @(& $client @a 2>&1 | ForEach-Object { "$_" })
}
function Get-AppCnf {
    $e = Read-Env (Join-Path $App '.env')
    $cnf = Join-Path $Tmp 'app.cnf'
    [IO.File]::WriteAllText($cnf, "[client]`nuser=$($e.DB_USER)`npassword=$($e.DB_PASSWORD)`nhost=127.0.0.1`nport=$($e.DB_PORT)`n")
    return $cnf
}
function Invoke-Installer([string[]]$Extra = @()) {
    $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $App 'installer\server\install-server.ps1'),
               '-NonInteractive', '-SkipServices', '-SkipFirewall', '-SkipBackupTask') + $Extra
    $o = & powershell @args2 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $o }
}

# ------------------------------------------------------------ safety + prerequisites
$installed = @(Get-Service -Name 'CompuLabWeb', 'CompuLabWorker', 'CompuLabMariaDB' -ErrorAction SilentlyContinue)
if ($installed.Count -and -not $EvenIfInstalled) {
    throw 'CompuLab services are installed on this computer: run this test on a development PC only (or with -EvenIfInstalled).'
}
$installedBefore = ($installed | ForEach-Object { "$($_.Name)=$($_.StartType)" }) -join ', '
foreach ($f in 'manage.py', 'runtime\mariadb\bin\mariadbd.exe', 'runtime\python\python.exe') {
    if (-not (Test-Path (Join-Path $Payload $f))) { throw "The payload $Payload has no $f (stage-test-payload.ps1 -WithRuntime)." }
}
$iscc = @($IsccPath, (Join-Path $Repo 'installer\build\tools\InnoSetup6\ISCC.exe'), "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
          "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 not found.' }
Remove-Item Env:\COMPULAB_DB_ROOT_PASSWORD -ErrorAction SilentlyContinue   # must not be needed
New-Item -ItemType Directory -Force $Tmp | Out-Null
Write-Host "Test folder: $Tmp"
$otherBefore = Get-OtherDbState
Write-Host "Other database servers on this PC (must stay unchanged): $(if ($otherBefore) { $otherBefore } else { 'none' })"

if ($RealPorts) {
    # The real servers on 3306/3307 stay as they are; the test only takes 3308
    # (free) itself. Expected: the first free port from 3309 on.
    if (-not (Get-NetTCPConnection -LocalPort 3306 -State Listen -ErrorAction SilentlyContinue) -or
        -not (Get-NetTCPConnection -LocalPort 3307 -State Listen -ErrorAction SilentlyContinue)) { throw '-RealPorts needs servers already listening on 3306 and 3307.' }
    if (-not (Test-PortFree 3308)) { throw '-RealPorts needs port 3308 free (the test occupies it).' }
    $p0 = 3306
    $busy = @(3308) | ForEach-Object { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $_); $l.Start(); $l }
    $expectedPort = 3309; while (-not (Test-PortFree $expectedPort)) { $expectedPort++ }
    $skippedPorts = 3306..($expectedPort - 1)
} else {
    # Three free ports in a row: the first two are taken by the test (like
    # MySQL and another program's database on 3306/3307), the third is expected.
    do { $p0 = Get-Random -Minimum 41000 -Maximum 48000 } until ((Test-PortFree $p0) -and (Test-PortFree ($p0 + 1)) -and (Test-PortFree ($p0 + 2)))
    $busy = @($p0, ($p0 + 1)) | ForEach-Object { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $_); $l.Start(); $l }
    $expectedPort = $p0 + 2
    $skippedPorts = @($p0, ($p0 + 1))
}
$webPort = Get-FreeTcpPort
$adminPw = 'Adm1n-' + [guid]::NewGuid().ToString('N')
$env:DJANGO_SUPERUSER_EMAIL = 'bundled.test.admin@gmail.com'
$env:DJANGO_SUPERUSER_PASSWORD = $adminPw
$web = $null
try {
    $builds = @{}
    foreach ($v in '0.0.0', '0.0.1') {
        $out = Join-Path $Tmp "out-$v"
        & $iscc /Q /DTestBuild "/DPayload=$Payload" "/DAppVersion=$v-test" "/DFileVersion=$v.1" "/DOutputDir=$out" (Join-Path $Repo 'installer\build\CompuLab-Server.iss') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Compiling the test build $v failed." }
        $builds[$v] = Get-ChildItem $out -Filter '*.exe' | Select-Object -First 1
    }
    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6F0B2D52-3C61-4E1B-9A57-2B7C2B1D7E57}_is1'
    function Invoke-Setup($Setup, [string]$Log, [string]$MorePs = '') {
        # WaitForExit, not Start-Process -Wait: -Wait also waits for every
        # descendant, and without services CompuLab's database is meant to
        # keep running after the setup ends.
        $p = Start-Process $Setup.FullName -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$App`"",
            '/SERVERADDRESS=127.0.0.1', "/PORT=$webPort", "/DBPORT=$p0", "/PSARGS=`"-SkipServices -SkipFirewall -SkipBackupTask $MorePs`"", "/LOG=`"$Log`"" -PassThru
        $p.WaitForExit()
        return $p.ExitCode
    }
    function Invoke-Uninstaller {
        $unins = Get-ChildItem $App -Filter 'unins*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($unins) { $u = Start-Process $unins.FullName -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -PassThru; $u.WaitForExit() }
    }

    Write-Host "`n1. Fresh install: no Python, no database server, no root password, no internet" -ForegroundColor Cyan
    # An earlier attempt that stopped while creating the database folder.
    New-Item -ItemType Directory -Force (Join-Path $App 'data\mariadb') | Out-Null
    Set-Content (Join-Path $App 'data\mariadb\left-by-interrupted-install.txt') 'x'
    $code = Invoke-Setup $builds['0.0.0'] (Join-Path $Tmp 'setup-1.log')
    $log1 = Get-ChildItem (Join-Path $App 'logs') -Filter 'install-*.log' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    $t1 = if ($log1) { Get-Content $log1.FullName -Raw } else { '' }
    Test-Case 'setup succeeded with the bundled Python and CompuLab''s own database' {
        Assert-True ($code -eq 0 -and (Get-Content (Join-Path $Tmp 'setup-1.log') -Raw) -notmatch 'install-server.ps1 failed') "setup exit $code (logs in $App\logs)"
        Assert-True ($t1 -match 'bundled in runtime\\python') 'bundled Python not used'
        Assert-True ($t1 -match "CompuLab's own database: bundled MariaDB") 'own database not set up'
        Assert-True ($t1 -notmatch 'root password') 'asked for a root password'
        Assert-True (-not (Test-Path (Join-Path $App 'venv'))) 'a venv was created'
        Assert-True ((Read-Env (Join-Path $App '.env')).COMPULAB_DB_MODE -eq 'bundled') 'COMPULAB_DB_MODE not recorded'
    }
    Test-Case "busy ports ($($skippedPorts -join ', ')) were skipped and the programs using them left alone; the next free port ($expectedPort) is used" {
        $e = Read-Env (Join-Path $App '.env')
        Assert-True ($e.DB_PORT -eq "$expectedPort") "DB_PORT $($e.DB_PORT), expected $expectedPort"
        foreach ($p in $skippedPorts) { Assert-True ($t1 -match "Port $p is in use") "skipped port $p not reported" }
        if ($RealPorts) {
            Assert-True ($t1 -match "Port 3306 is in use by the service 'MySQL") 'MySQL on 3306 not named'
            Assert-True ($t1 -match "Port 3307 is in use by the service '") 'the database on 3307 not named'
        }
        foreach ($l in $busy) { Assert-True $l.Server.IsBound "the program on $($l.LocalEndpoint.Port) was disturbed" }
    }
    Test-Case 'an interrupted earlier attempt is moved aside (kept), not reused or deleted' {
        $aside = @(Get-ChildItem (Join-Path $App 'data') -Directory -Filter 'mariadb.incomplete-*')
        Assert-True ($aside.Count -eq 1 -and (Test-Path (Join-Path $aside[0].FullName 'left-by-interrupted-install.txt'))) 'not kept aside'
        Assert-True (Test-Path (Join-Path $App 'data\mariadb\mysql')) 'new database folder missing'
    }

    Write-Host "`n2. The dedicated database" -ForegroundColor Cyan
    $dbPort = [int](Read-Env (Join-Path $App '.env')).DB_PORT
    $adminCnf = Join-Path $App 'data\db-admin.cnf'
    Test-Case 'it listens on 127.0.0.1 only and runs from CompuLab''s runtime folder' {
        $addr = @(Get-NetTCPConnection -LocalPort $dbPort -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $_.LocalAddress } | Select-Object -Unique)
        Assert-True ($addr.Count -ge 1 -and @($addr | Where-Object { $_ -ne '127.0.0.1' }).Count -eq 0) "listens on: $($addr -join ', ')"
        $procs = @(Get-OurDbProcess)   # @(): one process would otherwise not be a list
        Assert-True ($procs.Count -eq 1) "$($procs.Count) CompuLab database processes, expected 1"
    }
    Test-Case 'no password on any command line, in any install log or in the my.ini' {
        $e = Read-Env (Join-Path $App '.env')
        $root = [string](@(Get-Content $adminCnf) -match '^password=')[0] -replace '^password=', ''
        Assert-True ($root.Length -ge 32 -and $e.DB_PASSWORD.Length -ge 32) 'weak or missing generated passwords'
        $lines = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object { "$($_.CommandLine)" })
        foreach ($s in $root, $e.DB_PASSWORD, $adminPw) { Assert-True (-not ($lines | Where-Object { $_.Contains($s) })) 'a password is on a command line' }
        foreach ($log in Get-ChildItem (Join-Path $App 'logs') -File) {
            $t = "$(Get-Content $log.FullName -Raw)"   # an empty log reads as $null
            foreach ($s in $root, $e.DB_PASSWORD, $adminPw) { Assert-True (-not $t.Contains($s)) "password in $($log.Name)" }
        }
        Assert-True (-not (Get-Content (Join-Path $App 'data\mariadb\my.ini') -Raw).Contains($root)) 'root password in my.ini'
    }
    Test-Case '.env and db-admin.cnf are readable only by Administrators, SYSTEM and the installing account' {
        foreach ($f in (Join-Path $App '.env'), $adminCnf) {
            $acl = Get-Acl $f
            Assert-True $acl.AreAccessRulesProtected "$f inherits permissions"
            $who = @($acl.Access | ForEach-Object { $_.IdentityReference.Value })
            Assert-True (-not ($who -match 'Users$|Everyone|Authenticated')) "$f readable by: $($who -join ', ')"
        }
    }
    Test-Case 'the application user may use compulab_db only; root signs in locally only; no anonymous accounts' {
        $appCnf = Get-AppCnf
        try { $grants = Invoke-Db $appCnf 'SHOW GRANTS FOR CURRENT_USER()' } finally { Remove-Item $appCnf -Force }
        $global = @($grants | Where-Object { $_ -match 'ON \*\.\*' -and $_ -notmatch 'GRANT USAGE ON \*\.\*' })
        Assert-True ($grants -match 'ON `compulab_db`\.\*' -and $global.Count -eq 0) "grants: $($grants -join ' | ')"
        $users = Invoke-Db $adminCnf "SELECT CONCAT(User, '@', Host) FROM mysql.user"
        Assert-True (-not ($users | Where-Object { $_ -match '^@' })) "anonymous account: $($users -join ', ')"
        Assert-True (-not ($users | Where-Object { $_ -match '^root@' -and $_ -notmatch '^root@(localhost|127\.0\.0\.1|::1)$' })) "root from elsewhere: $($users -join ', ')"
        # MariaDB's default: every account (PUBLIC) may use `test` and test_... databases.
        $public = @(Invoke-Db $adminCnf "SELECT Db FROM mysql.db WHERE User = 'PUBLIC'")
        Assert-True ($public.Count -eq 0) "PUBLIC still has rights on: $($public -join ', ')"
        Assert-True (-not (@(Invoke-Db $adminCnf 'SHOW DATABASES') -contains 'test')) 'the test database is still there'
        $appCnf = Get-AppCnf
        try { $seen = @(Invoke-Db $appCnf 'SHOW DATABASES') } finally { Remove-Item $appCnf -Force }
        Assert-True (-not ($seen | Where-Object { $_ -notin @('compulab_db', 'information_schema') })) "the application user sees: $($seen -join ', ')"
    }
    Test-Case 'database server is MariaDB 11.4 from the bundle, UTF-8' {
        $v = Invoke-Db $adminCnf 'SELECT VERSION(), @@character_set_server, @@bind_address'
        Assert-True ("$v" -match '11\.4\.\d+-MariaDB' -and "$v" -match 'utf8mb4' -and "$v" -match '127\.0\.0\.1') "server: $v"
    }

    Write-Host "`n3. CompuLab on its own database" -ForegroundColor Cyan
    Test-Case 'every migration applied, one Administrator who can sign in' {
        $appCnf = Get-AppCnf
        try {
            $applied = [int]("$(Invoke-Db $appCnf "SELECT COUNT(*) FROM django_migrations WHERE app IN ('accounts','labs','scheduling','issues','notifications','cloud_sync','cloud_receiver','system')" 'compulab_db')".Trim())
            $admins = [int]("$(Invoke-Db $appCnf 'SELECT COUNT(*) FROM accounts_user WHERE is_superuser = 1' 'compulab_db')".Trim())
        } finally { Remove-Item $appCnf -Force }
        $expected = @(Get-ChildItem $App -Recurse -Filter '0*.py' | Where-Object { $_.Directory.Name -eq 'migrations' -and $_.FullName -notmatch '\\runtime\\' }).Count
        Assert-True ($applied -eq $expected) "applied $applied of $expected"
        Assert-True ($admins -eq 1) "$admins Administrators"
        $o = & (Join-Path $App 'runtime\python\python.exe') (Join-Path $App 'manage.py') ensure_admin --check 2>$null | Out-String
        Assert-True ($LASTEXITCODE -eq 0 -and $o -match 'ADMIN_OK') $o
    }
    $web = Start-Process (Join-Path $App 'runtime\python\python.exe') -ArgumentList '-m', 'waitress', "--listen=127.0.0.1:$webPort", 'compulab.wsgi:application' `
        -WorkingDirectory $App -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Tmp 'web.err')
    Test-Case 'the site answers (bundled Python + waitress): /healthz, login page, /healthz/ready with the database OK' {
        $ok = $false
        foreach ($i in 1..60) { try { $ok = (Invoke-WebRequest "http://127.0.0.1:$webPort/healthz" -UseBasicParsing -TimeoutSec 3).Content.Trim() -eq 'ok' } catch { }; if ($ok) { break }; Start-Sleep 1 }
        Assert-True $ok '/healthz did not answer'
        Assert-True ((Invoke-WebRequest "http://127.0.0.1:$webPort/accounts/login/" -UseBasicParsing).StatusCode -eq 200) 'login page'
        Assert-True ((Invoke-RestMethod "http://127.0.0.1:$webPort/healthz/ready").database.ok -eq $true) 'database not OK'
    }
    Stop-Process -Id $web.Id -Force; $web = $null

    Write-Host "`n4. Repair keeps everything" -ForegroundColor Cyan
    & (Join-Path $App 'runtime\python\python.exe') (Join-Path $App 'manage.py') shell -c "import datetime; from labs.models import Lab; Lab.objects.create(name='Marker before repair', opening_time=datetime.time(7), closing_time=datetime.time(17))" 2>$null
    $markerTime = (Get-Item (Join-Path $App 'data\mariadb\compulab-provisioned.txt')).LastWriteTime
    $envBefore = Read-Env (Join-Path $App '.env')
    $r = Invoke-Installer
    Test-Case 'repair: exit 0, data kept, not initialized again, no second Administrator, settings kept' {
        Assert-True ($r.Code -eq 0) "exit $($r.Code): $(($r.Out -split "`n" | Select-Object -Last 4) -join ' ')"
        $appCnf = Get-AppCnf
        try {
            Assert-True ("$(Invoke-Db $appCnf "SELECT COUNT(*) FROM labs_lab WHERE name='Marker before repair'" 'compulab_db')".Trim() -eq '1') 'data lost'
            Assert-True ("$(Invoke-Db $appCnf 'SELECT COUNT(*) FROM accounts_user WHERE is_superuser = 1' 'compulab_db')".Trim() -eq '1') 'second Administrator'
        } finally { Remove-Item $appCnf -Force }
        Assert-True ((Get-Item (Join-Path $App 'data\mariadb\compulab-provisioned.txt')).LastWriteTime -eq $markerTime) 'database set up again'
        $after = Read-Env (Join-Path $App '.env')
        foreach ($k in 'DJANGO_SECRET_KEY', 'DB_PASSWORD', 'DB_PORT', 'PC_AGENT_SHARED_SECRET') { Assert-True ($envBefore[$k] -eq $after[$k]) "$k changed" }
        $procs = @(Get-OurDbProcess)
        Assert-True ($procs.Count -eq 1) "$($procs.Count) database processes after repair, expected 1"
    }

    Write-Host "`n5. Backup and restore with the dedicated instance" -ForegroundColor Cyan
    $backups = (Read-Env (Join-Path $App '.env')).COMPULAB_BACKUP_ROOT
    Test-Case 'backup.ps1 dumps CompuLab''s own database with its own MariaDB dump tool' {
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $App 'installer\server\backup.ps1') -Log 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
        $b = Get-ChildItem $backups -Directory -Filter 'compulab-*' | Sort-Object Name | Select-Object -Last 1
        $head = (Get-Content (Join-Path $b.FullName 'database.sql') -TotalCount 5) -join ' '
        # e.g. "-- MariaDB dump 10.19-11.4.13-MariaDB, for Win64 (AMD64)" (MySQL's would say "MySQL dump")
        Assert-True ($head -match 'MariaDB dump [\d.]+-11\.4\.\d+-MariaDB') "not dumped by the bundled MariaDB tool: $head"
        Assert-True ((Get-Content (Join-Path $b.FullName 'database.sql') -Raw) -match 'Marker before repair') 'data missing from the dump'
    }
    Test-Case 'restore.ps1 brings back the backed-up data into the dedicated instance' {
        $b = Get-ChildItem $backups -Directory -Filter 'compulab-*' | Sort-Object Name | Select-Object -Last 1
        & (Join-Path $App 'runtime\python\python.exe') (Join-Path $App 'manage.py') shell -c "import datetime; from labs.models import Lab; Lab.objects.create(name='Added after backup', opening_time=datetime.time(7), closing_time=datetime.time(17))" 2>$null
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $App 'installer\server\restore.ps1') -BackupFolder $b.FullName -Force *> (Join-Path $Tmp 'restore.log')
        Assert-True ($LASTEXITCODE -eq 0) "restore exit $LASTEXITCODE"
        $appCnf = Get-AppCnf
        try {
            Assert-True ("$(Invoke-Db $appCnf "SELECT COUNT(*) FROM labs_lab WHERE name='Added after backup'" 'compulab_db')".Trim() -eq '0') 'not restored'
            Assert-True ("$(Invoke-Db $appCnf "SELECT COUNT(*) FROM labs_lab WHERE name='Marker before repair'" 'compulab_db')".Trim() -eq '1') 'backed-up data missing'
        } finally { Remove-Item $appCnf -Force }
    }

    Write-Host "`n6. Update with a newer setup (0.0.0 -> 0.0.1)" -ForegroundColor Cyan
    $before = Read-Env (Join-Path $App '.env')
    $pidBefore = @(Get-OurDbProcess | ForEach-Object { $_.ProcessId })
    $code = Invoke-Setup $builds['0.0.1'] (Join-Path $Tmp 'setup-2.log')
    Test-Case 'update: CompuLab''s database stopped before the files were replaced, data and secrets kept, new version registered' {
        Assert-True ($code -eq 0 -and (Get-Content (Join-Path $Tmp 'setup-2.log') -Raw) -notmatch 'install-server.ps1 failed') "update exit $code"
        $after = Read-Env (Join-Path $App '.env')
        foreach ($k in 'DJANGO_SECRET_KEY', 'DB_PASSWORD', 'DB_PORT', 'PC_AGENT_SHARED_SECRET') { Assert-True ($before[$k] -eq $after[$k]) "$k changed" }
        Assert-True ((Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue).DisplayVersion -eq '0.0.1-test') 'version not registered'
        $now = @(Get-OurDbProcess | ForEach-Object { $_.ProcessId })
        Assert-True ($now.Count -eq 1 -and $now[0] -notin $pidBefore) 'the database was not restarted by the update'
        $appCnf = Get-AppCnf
        try { Assert-True ("$(Invoke-Db $appCnf "SELECT COUNT(*) FROM labs_lab WHERE name='Marker before repair'" 'compulab_db')".Trim() -eq '1') 'data lost' } finally { Remove-Item $appCnf -Force }
        Assert-True (@(Get-ChildItem $backups -Directory -Filter 'compulab-*').Count -ge 2) 'no backup before the update'
    }

    Write-Host "`n7. Failures are refused or reported, never destructive" -ForegroundColor Cyan
    $envHash = (Get-FileHash (Join-Path $App '.env')).Hash
    Test-Case 'damaged runtime file: refused before any change (SHA-256 differs from the build)' {
        $f = Join-Path $App 'runtime\mariadb\bin\perror.exe'
        $orig = [IO.File]::ReadAllBytes($f)
        $pid1 = @(Get-OurDbProcess | ForEach-Object { $_.ProcessId })
        try {
            [IO.File]::WriteAllBytes($f, $orig + [byte[]]@(0))
            $r = Invoke-Installer
            Assert-True ($r.Code -eq 1 -and $r.Out -match 'damaged bin\\perror\.exe' -and $r.Out -match 'Nothing was changed') "exit $($r.Code)"
            Assert-True ((Get-FileHash (Join-Path $App '.env')).Hash -eq $envHash) '.env changed'
            Assert-True ("$(@(Get-OurDbProcess | ForEach-Object { $_.ProcessId }))" -eq "$pid1") 'the database was touched'
        } finally { [IO.File]::WriteAllBytes($f, $orig) }
    }
    Test-Case 'incomplete runtime (a required file missing): refused before any change' {
        $f = Join-Path $App 'runtime\mariadb\COPYING'
        Rename-Item $f 'COPYING.hidden'
        try {
            $r = Invoke-Installer
            Assert-True ($r.Code -eq 1 -and $r.Out -match 'missing COPYING') "exit $($r.Code)"
        } finally { Rename-Item (Join-Path $App 'runtime\mariadb\COPYING.hidden') 'COPYING' }
    }
    Test-Case 'database start failure: exit 1 with the database''s own log, data unchanged; fixed, the next run succeeds' {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $App 'installer\server\stop-compulab.ps1') | Out-Null
        Assert-True (@(Get-OurDbProcess).Count -eq 0) 'stop-compulab.ps1 did not stop the database'
        $ib = Join-Path $App 'data\mariadb\ibdata1'
        Set-ItemProperty $ib -Name IsReadOnly -Value $true
        try {
            $r = Invoke-Installer
            Assert-True ($r.Code -eq 1 -and $r.Out -match "CompuLab's database did not start" -and $r.Out -match 'Its log says') "exit $($r.Code): $(($r.Out -split "`n" | Select-Object -Last 3) -join ' ')"
        } finally { Set-ItemProperty $ib -Name IsReadOnly -Value $false }
        $r = Invoke-Installer
        Assert-True ($r.Code -eq 0) "after the fix: exit $($r.Code)"
        $appCnf = Get-AppCnf
        try { Assert-True ("$(Invoke-Db $appCnf "SELECT COUNT(*) FROM labs_lab WHERE name='Marker before repair'" 'compulab_db')".Trim() -eq '1') 'data lost' } finally { Remove-Item $appCnf -Force }
    }
    Test-Case 'lost administrator sign-in (db-admin.cnf deleted): reset offline, data unchanged' {
        Remove-Item $adminCnf -Force
        $r = Invoke-Installer
        Assert-True ($r.Code -eq 0 -and (Test-Path $adminCnf)) "exit $($r.Code)"
        Assert-True ("$(Invoke-Db $adminCnf 'SELECT 1')".Trim() -eq '1') 'new administrator sign-in does not work'
        $appCnf = Get-AppCnf
        try { Assert-True ("$(Invoke-Db $appCnf "SELECT COUNT(*) FROM labs_lab WHERE name='Marker before repair'" 'compulab_db')".Trim() -eq '1') 'data lost' } finally { Remove-Item $appCnf -Force }
    }
    Test-Case 'database files an earlier installer left unreadable (my.ini without any permission): repaired first, data unchanged' {
        # The state a real install was left in: icacls /inheritance:r ... /T
        # took every permission from the files, and the root password was
        # never confirmed (no marker).
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $App 'installer\server\stop-compulab.ps1') | Out-Null
        $data = Join-Path $App 'data\mariadb'
        & icacls $data /inheritance:r /grant:r "*$(([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value):(OI)(CI)F" /T /Q | Out-Null
        Remove-Item (Join-Path $data 'compulab-provisioned.txt') -Force
        $unreadable = try { $null = [IO.File]::ReadAllText((Join-Path $data 'my.ini')); $false } catch { $true }
        Assert-True $unreadable 'could not reproduce the unreadable my.ini'
        $r = Invoke-Installer
        Assert-True ($r.Code -eq 0 -and $r.Out -match 'Permissions of the files in .* repaired') "exit $($r.Code): $(($r.Out -split "`n" | Select-Object -Last 3) -join ' ')"
        Assert-True ((Read-Env (Join-Path $App '.env')).DB_PORT -eq "$expectedPort") 'the database port changed'
        $appCnf = Get-AppCnf
        try { Assert-True ("$(Invoke-Db $appCnf "SELECT COUNT(*) FROM labs_lab WHERE name='Marker before repair'" 'compulab_db')".Trim() -eq '1') 'data lost' } finally { Remove-Item $appCnf -Force }
    }
    Test-Case 'invalid settings: clear message, exit 1, .env unchanged' {
        $h = (Get-FileHash (Join-Path $App '.env')).Hash
        $r = Invoke-Installer @('-Port', '70000')
        Assert-True ($r.Code -eq 1 -and $r.Out -match 'Port must be') "exit $($r.Code)"
        Assert-True ((Get-FileHash (Join-Path $App '.env')).Hash -eq $h) '.env changed'
    }
    Test-Case 'a setup whose CompuLab step failed exits with code 10, never 0 (silent installs see the failure)' {
        $h = (Get-FileHash (Join-Path $App '.env')).Hash
        $code = Invoke-Setup $builds['0.0.1'] (Join-Path $Tmp 'setup-fail.log') '-Port 70000'
        Assert-True ($code -eq 10) "setup exit code $code"
        Assert-True ((Get-Content (Join-Path $Tmp 'setup-fail.log') -Raw) -match 'install-server.ps1 failed') 'failure not in the setup log'
        Assert-True ((Get-FileHash (Join-Path $App '.env')).Hash -eq $h) '.env changed'
    }

    Write-Host "`n8. Uninstall keeps the data; reinstall brings it back" -ForegroundColor Cyan
    Test-Case 'uninstall: database stopped, program files removed, data\ and .env kept' {
        Invoke-Uninstaller
        foreach ($i in 1..30) { if (-not (Test-Path (Join-Path $App 'manage.py'))) { break }; Start-Sleep 1 }
        Assert-True (-not (Test-Path (Join-Path $App 'manage.py'))) 'program files still there'
        Assert-True (-not (Test-Path (Join-Path $App 'runtime\mariadb\bin\mariadbd.exe'))) 'runtime not removed (database still running?)'
        Assert-True (@(Get-OurDbProcess).Count -eq 0) 'database still running'
        foreach ($keep in '.env', 'data\mariadb\ibdata1', 'data\db-admin.cnf') { Assert-True (Test-Path (Join-Path $App $keep)) "$keep was deleted" }
    }
    $code = Invoke-Setup $builds['0.0.1'] (Join-Path $Tmp 'setup-3.log')
    Test-Case 'reinstall over the kept data: everything back, nothing initialized again' {
        Assert-True ($code -eq 0) "setup exit $code"
        $appCnf = Get-AppCnf
        try { Assert-True ("$(Invoke-Db $appCnf "SELECT COUNT(*) FROM labs_lab WHERE name='Marker before repair'" 'compulab_db')".Trim() -eq '1') 'data not back' } finally { Remove-Item $appCnf -Force }
    }

    Write-Host "`n9. Other database servers on this PC" -ForegroundColor Cyan
    Test-Case 'unchanged (same services, states, processes and ports as before the test)' {
        $now = Get-OtherDbState
        Assert-True ($now -eq $otherBefore) "before: $otherBefore`n         after:  $now"
        $installedNow = (@(Get-Service -Name 'CompuLabWeb', 'CompuLabWorker', 'CompuLabMariaDB' -ErrorAction SilentlyContinue) | ForEach-Object { "$($_.Name)=$($_.StartType)" }) -join ', '
        Assert-True ($installedNow -eq $installedBefore) "installed CompuLab services changed: before '$installedBefore', after '$installedNow'"
    }
} finally {
    if ($web) { Stop-Process -Id $web.Id -Force -ErrorAction SilentlyContinue }
    foreach ($l in $busy) { $l.Stop() }
    $stop = Join-Path $App 'installer\server\stop-compulab.ps1'
    if (Test-Path $stop) { & powershell -NoProfile -ExecutionPolicy Bypass -File $stop -Quiet | Out-Null }
    foreach ($p in Get-OurDbProcess) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }   # only the test's own database
    $unins = Get-ChildItem $App -Filter 'unins*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($unins) { $u = Start-Process $unins.FullName -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -PassThru; $u.WaitForExit() }
    Remove-Item Env:\DJANGO_SUPERUSER_EMAIL, Env:\DJANGO_SUPERUSER_PASSWORD -ErrorAction SilentlyContinue
    if (-not $KeepFiles -and -not $script:failed.Count) { Start-Sleep 3; Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host "`n$($script:passed) passed, $($script:failed.Count) failed" -ForegroundColor $(if ($script:failed.Count) { 'Red' } else { 'Green' })
if ($KeepFiles -or $script:failed.Count) { Write-Host "Test files: $Tmp" }
exit [int]($script:failed.Count -gt 0)
