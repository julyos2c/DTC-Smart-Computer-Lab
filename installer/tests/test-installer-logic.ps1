<#
.SYNOPSIS
  Unit tests for the installer logic (no administrator rights, no network,
  nothing outside a temporary folder is changed).

      powershell -ExecutionPolicy Bypass -File installer\tests\test-installer-logic.ps1

  Exit code 0 = all passed. Covers settings validation, .env creation and
  repair (secrets kept), database SQL, Python / database version checks, the
  database service choice, agent configuration validation, and file-format
  rules for the scripts (ASCII-only .ps1, CRLF .cmd, every script parses).

  It also checks the configuration that needs administrator rights to
  install - the WinSW service definitions, Windows service recovery, the
  firewall rules (New-NetFirewallRule -WhatIf), the nightly backup task and
  the agent start-up task (New-ScheduledTask objects, never registered) -
  WITHOUT installing any of it. That proves what the installers ask Windows
  for; whether Windows then runs it correctly on a real machine is in
  docs\RELEASE_READINESS.md (administrator checks).
#>
$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Tmp = Join-Path $env:TEMP ("compulab-installer-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $Tmp | Out-Null
$script:passed = 0; $script:failed = @()

function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
    catch { $script:failed += $Name; Write-Host "  [FAIL] $Name`n         $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Equal($Expected, $Actual, [string]$Message = '') {
    if ("$Expected" -ne "$Actual") { throw "expected '$Expected', got '$Actual'. $Message" }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Readable([string]$Path) { try { $null = [IO.File]::ReadAllBytes($Path); return $true } catch { return $false } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    try { & $Body } catch { if ($Pattern -and $_.Exception.Message -notmatch $Pattern) { throw "threw '$($_.Exception.Message)', expected /$Pattern/" }; return }
    throw 'expected an error, none was thrown'
}

Write-Host "`nServer installer logic" -ForegroundColor Cyan
. (Join-Path $Repo 'installer\server\common.ps1')
$script:EnvFile = Join-Path $Tmp '.env'   # every .env test writes here, never the real one
$valid = @{ ServerAddress = '192.168.1.10'; Port = 8000; RemoteUrl = ''; DbName = 'compulab_db'; DbUser = 'compulab'
            DbHost = '127.0.0.1'; DbPort = '3306'; AllowFrom = $script:DefaultAllowFrom; AdminEmail = '' }

Test-Case 'valid settings have no problems' { Assert-Equal 0 (Test-InstallSettings $valid).Count }
Test-Case 'bad port, address with http://, and address with port are rejected' {
    foreach ($change in @(@{ Port = 0 }, @{ Port = 70000 }, @{ Port = 'abc' }, @{ ServerAddress = 'http://192.168.1.10' }, @{ ServerAddress = '192.168.1.10:8000' })) {
        $s = $valid.Clone(); foreach ($k in $change.Keys) { $s[$k] = $change[$k] }
        Assert-True ((Test-InstallSettings $s).Count -ge 1) "accepted $($change | ConvertTo-Json -Compress)"
    }
}
Test-Case 'database/user names that could break SQL are rejected' {
    foreach ($bad in @("x'; DROP DATABASE mysql; --", 'name with space', 'a`b', '')) {
        $s = $valid.Clone(); $s.DbName = $bad
        Assert-True ((Test-InstallSettings $s).Count -ge 1) "accepted DbName '$bad'"
        $s = $valid.Clone(); $s.DbUser = $bad
        Assert-True ((Test-InstallSettings $s).Count -ge 1) "accepted DbUser '$bad'"
    }
}
Test-Case 'firewall scope: "Any" and malformed ranges are rejected, CIDRs accepted' {
    $s = $valid.Clone(); $s.AllowFrom = @('Any'); Assert-True ((Test-InstallSettings $s).Count -ge 1) 'Any accepted'
    $s.AllowFrom = @('192.168.0.0/33'); Assert-True ((Test-InstallSettings $s).Count -ge 1) '/33 accepted'
    $s.AllowFrom = @('10.0.0.0/8', 'LocalSubnet', '192.168.1.5'); Assert-Equal 0 (Test-InstallSettings $s).Count
}
Test-Case 'remote URL and admin email formats' {
    $s = $valid.Clone(); $s.RemoteUrl = 'https://compulab.tail1234.ts.net'; Assert-Equal 0 (Test-InstallSettings $s).Count
    $s.RemoteUrl = 'ftp://x'; Assert-True ((Test-InstallSettings $s).Count -ge 1) 'ftp accepted'
    $s = $valid.Clone(); $s.AdminEmail = 'admin@school.edu'; Assert-True ((Test-InstallSettings $s).Count -ge 1) 'non-gmail accepted'
}
Test-Case 'command line beats config file beats defaults; empty values do not override' {
    $m = Merge-InstallSettings @{ Port = 8000; DbName = 'compulab_db'; ServerAddress = '' } @{ Port = 9000; ServerAddress = '10.0.0.5' } @{ Port = 8080; DbName = '' }
    Assert-Equal 8080 $m.Port; Assert-Equal '10.0.0.5' $m.ServerAddress; Assert-Equal 'compulab_db' $m.DbName
}
Test-Case 'the sample server config file is valid' {
    $f = Read-InstallConfig (Join-Path $Repo 'installer\server\server-install.sample.json')
    $m = Merge-InstallSettings $valid $f @{}
    Assert-Equal 0 (Test-InstallSettings $m).Count
}
Test-Case 'config file: unknown keys and invalid JSON are errors' {
    $bad = Join-Path $Tmp 'bad.json'
    '{"ServerAdress": "1.2.3.4"}' | Set-Content $bad
    Assert-Throws { Read-InstallConfig $bad } 'Unknown setting'
    '{not json' | Set-Content $bad
    Assert-Throws { Read-InstallConfig $bad } 'not valid JSON'
}
Test-Case 'first-run .env has every setting, safe defaults and fresh secrets' {
    $a = New-DotEnvSettings $valid @('192.168.1.10', '10.0.0.2') 'LABSERVER'
    $b = New-DotEnvSettings $valid @() 'LABSERVER'
    foreach ($k in 'DJANGO_SECRET_KEY', 'DB_PASSWORD', 'PC_AGENT_SHARED_SECRET', 'SITE_URL', 'DJANGO_ALLOWED_HOSTS', 'COMPULAB_BACKGROUND_TASKS') { Assert-True $a.Contains($k) "missing $k" }
    Assert-Equal 'False' $a['DJANGO_DEBUG']
    Assert-Equal 'http://192.168.1.10:8000' $a['SITE_URL']
    Assert-True ($a['DJANGO_SECRET_KEY'].Length -ge 50) 'secret key too short'
    Assert-True ($a['DJANGO_SECRET_KEY'] -ne $b['DJANGO_SECRET_KEY']) 'secrets are not random'
    Assert-True ($a['DJANGO_ALLOWED_HOSTS'] -match '(^|,)labserver(,|$)') 'computer name not allowed'
    Assert-True ($a['DJANGO_CSRF_TRUSTED_ORIGINS'] -match 'http://10\.0\.0\.2:8000') 'LAN address origin missing'
}
Test-Case 'repair keeps .env secrets and only adds missing keys' {
    Remove-Item $script:EnvFile -ErrorAction SilentlyContinue
    Assert-True (Initialize-DotEnv $valid @('192.168.1.10') -WorkerService) 'first run not detected'
    $first = Read-DotEnv
    Set-DotEnvValue 'COMPULAB_BACKGROUND_TASKS' 'True'
    $lines = Get-Content $script:EnvFile | Where-Object { $_ -notmatch '^COMPULAB_REMOTE_URL=' }
    [IO.File]::WriteAllLines($script:EnvFile, [string[]]$lines)   # an older .env without that key
    $other = $valid.Clone(); $other.Port = 9999; $other.DbName = 'other_db'
    Assert-True (-not (Initialize-DotEnv $other @() -WorkerService)) 'second run treated as first'
    $second = Read-DotEnv
    foreach ($k in 'DJANGO_SECRET_KEY', 'DB_PASSWORD', 'PC_AGENT_SHARED_SECRET', 'SITE_URL', 'DB_NAME') { Assert-Equal $first[$k] $second[$k] "$k changed on repair" }
    Assert-True $second.ContainsKey('COMPULAB_REMOTE_URL') 'missing key not added'
    Assert-Equal 'False' $second['COMPULAB_BACKGROUND_TASKS'] 'worker setting not enforced'
}
Test-Case '.env is written as UTF-8 without BOM and keeps other lines' {
    [IO.File]::WriteAllLines($script:EnvFile, [string[]]@('# comment', 'A=1', 'B=2'))
    Set-DotEnvValue 'A' 'changed'; Set-DotEnvValue 'C' '3'
    $bytes = [IO.File]::ReadAllBytes($script:EnvFile)
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'BOM written'
    Assert-Equal "# comment|A=changed|B=2|C=3" ((Get-Content $script:EnvFile) -join '|')
}
Test-Case '.env access is limited to Administrators, SYSTEM and the installing account' {
    Protect-EnvFile
    $acl = Get-Acl $script:EnvFile
    Assert-True $acl.AreAccessRulesProtected 'inherited permissions not removed'
    $who = @($acl.Access | ForEach-Object { $_.IdentityReference.Value })
    Assert-True (-not ($who -match 'Users$|Everyone')) "readable by: $($who -join ', ')"
}
Test-Case 'database SQL is idempotent, escapes the password and refuses bad names' {
    $sql = Get-DbSetupSql 'compulab_db' 'compulab' "pa'ss\word"
    Assert-True ($sql -match 'CREATE DATABASE IF NOT EXISTS `compulab_db`') 'no IF NOT EXISTS'
    Assert-True ($sql -match "IDENTIFIED BY 'pa''ss\\\\word'") 'password not escaped'
    Assert-True ($sql -match 'ALTER USER') 'password not re-synced on repair'
    Assert-Throws { Get-DbSetupSql 'x;drop' 'compulab' 'p' } 'Invalid'
}
Test-Case 'database version gate (Django 5.2)' {
    Assert-Throws { Assert-SupportedDbVersion '10.4.32-MariaDB' } 'too old'
    Assert-Equal 'MariaDB 10.5.0' (Assert-SupportedDbVersion '10.5.0-MariaDB')
    Assert-Equal 'MariaDB 11.4.13' (Assert-SupportedDbVersion '11.4.13-MariaDB-log')
    Assert-Throws { Assert-SupportedDbVersion '8.0.10' } 'too old'
    Assert-Equal 'MySQL 8.4.3' (Assert-SupportedDbVersion '8.4.3')
    Assert-Throws { Assert-SupportedDbVersion 'garbage' } 'Could not read'
}
Test-Case 'existing .env without database settings (developer copy): refused, credentials never invented' {
    $full = @{ DB_NAME = 'compulab_db'; DB_USER = 'compulab'; DB_PASSWORD = 'x' * 32; DB_HOST = '127.0.0.1'; DB_PORT = '3306' }
    Assert-Equal 0 @(Test-ExistingDbSettings $full).Count 'a complete installer .env refused'
    # The development .env that broke a real run: no DB_ keys at all.
    $dev = @{ DJANGO_DEBUG = 'True'; PC_AGENT_SHARED_SECRET = 'x'; COMPULAB_PORT = '8000' }
    $p = @(Test-ExistingDbSettings $dev @('DbHost', 'DbPort'))
    Assert-Equal 1 $p.Count
    foreach ($k in $script:DbEnvKeys) { Assert-True ($p[0] -match $k) "$k not named: $($p[0])" }
    Assert-True ($p[0] -match 'development copy' -and $p[0] -match 'does not invent') "unclear: $($p[0])"
    foreach ($k in 'DB_NAME', 'DB_USER', 'DB_PASSWORD') {
        $e = $full.Clone(); $e[$k] = ''
        Assert-Equal 1 @(Test-ExistingDbSettings $e @('DbHost', 'DbPort')).Count "empty $k accepted"
    }
}
Test-Case 'existing .env without DB_HOST/DB_PORT: only filled in when given explicitly' {
    $e = @{ DB_NAME = 'compulab_db'; DB_USER = 'compulab'; DB_PASSWORD = 'x' * 32 }
    $p = @(Test-ExistingDbSettings $e)
    Assert-Equal 1 $p.Count
    Assert-True ($p[0] -match 'DB_HOST / DB_PORT' -and $p[0] -match '-DbHost 127\.0\.0\.1 -DbPort 3306') "unclear: $($p[0])"
    Assert-True ((@(Test-ExistingDbSettings $e @('DbHost'))[0]) -match 'no DB_PORT\.') 'DB_PORT not still required'
    Assert-Equal 0 @(Test-ExistingDbSettings $e @('DbHost', 'DbPort')).Count 'explicit host and port refused'
}
Test-Case 'first install writes the chosen database host and port (127.0.0.1:3306 only as the default)' {
    Remove-Item $script:EnvFile -ErrorAction SilentlyContinue
    $s = $valid.Clone(); $s.DbHost = 'db.school.lan'; $s.DbPort = '3307'
    Assert-True (Initialize-DotEnv $s @('192.168.1.10')) 'first run not detected'
    $e = Read-DotEnv
    Assert-Equal 'db.school.lan' $e.DB_HOST; Assert-Equal '3307' $e.DB_PORT
    Assert-Equal 0 @($script:DbEnvKeys | Where-Object { -not $e[$_] }).Count 'a DB_ key missing in a new .env'
    Remove-Item $script:EnvFile
}
Test-Case 'the database sign-in file refuses an empty host or port (regression: "Empty value for port")' {
    Assert-Throws { New-MySqlDefaultsFile 'root' 'pw' '127.0.0.1' '' } 'port is empty'
    Assert-Throws { New-MySqlDefaultsFile 'root' 'pw' '' '3306' } 'host is empty'
    Assert-Throws { New-MySqlDefaultsFile 'root' 'pw' '127.0.0.1' 'abc' } 'not a number'
    $cnf = New-MySqlDefaultsFile 'root' 'pw' '127.0.0.1' '3306'
    try { Assert-True ((Get-Content $cnf -Raw) -match 'port=3306') 'port not written' } finally { Remove-Item $cnf -Force }
}
Test-Case 'sign-in errors: mysql''s own message with its meaning, never just "wrong password", password and file path hidden' {
    $cases = @(
        @('ERROR 1045 (28000): Access denied for user ''root''@''localhost'' (using password: NO)', 'No password was given'),
        @('ERROR 1045 (28000): Access denied for user ''root''@''localhost'' (using password: YES)', 'was not accepted'),
        @('ERROR 2003 (HY000): Can''t connect to MySQL server on ''127.0.0.1:3306'' (10061)', 'No database server answered on 127\.0\.0\.1:3306'),
        @('mysql: [ERROR] C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe: Empty value for ''port'' specified.', 'port is empty'),
        @('ERROR 2005 (HY000): Unknown MySQL server host ''nohost'' (11001)', 'was not found'),
        @('ERROR 1130 (HY000): Host ''10.0.0.9'' is not allowed to connect to this MySQL server', 'may not sign in'),
        @('ERROR 2059 (HY000): Authentication plugin ''caching_sha2_password'' cannot be loaded', 'sign-in method'),
        @('ERROR 9999 (HY000): something new', 'refused the sign-in')
    )
    foreach ($c in $cases) {
        $t = ConvertTo-DbErrorText @('mysql: [Warning] Using a password on the command line interface can be insecure.', $c[0]) '127.0.0.1' '3306'
        Assert-True ($t -match $c[1]) "'$($c[0])' explained as: $t"
        Assert-True ($t -match 'Database server said: ' -and $t -notmatch 'Warning') "raw message missing or warning kept: $t"
    }
    $t = ConvertTo-DbErrorText @('ERROR 1045: denied for S3cret-Pass-123 reading C:\Users\x\AppData\Local\Temp\compulab-db-abc.cnf') 'h' '1' 'S3cret-Pass-123'
    Assert-True ($t -notmatch 'S3cret' -and $t -notmatch 'compulab-db-abc' -and $t -match '<options file>') "not cleaned: $t"
    Assert-True ((ConvertTo-DbErrorText @() 'h' '1') -match 'no message') 'empty output'
}
Test-Case 'sign-in against a port with no database server: the real mysql.exe error is explained (nothing is changed)' {
    $client = Find-MySqlTool 'mysql.exe'
    if (-not $client) { Write-Host '         (no mysql.exe on this PC: not exercised)' -ForegroundColor DarkYellow; return }
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $free = $l.LocalEndpoint.Port; $l.Stop()
    $cnf = New-MySqlDefaultsFile 'root' 'not-a-real-password' '127.0.0.1' "$free"
    try { $r = Get-DbSignIn $client $cnf } finally { Remove-Item $cnf -Force }
    Assert-True ($null -eq $r.Version) 'signed in to nothing'
    $t = ConvertTo-DbErrorText $r.Lines '127.0.0.1' "$free" 'not-a-real-password'
    Assert-True ($t -match "No database server answered on 127\.0\.0\.1:$free" -and $t -match '2003') $t
    Assert-True ($t -notmatch 'not-a-real-password') 'password shown'
}
Test-Case 'Python environment: reused only when made from the same Python (regression: 3.11 venv reused)' {
    $py = @{ Version = '3.13'; BasePrefix = 'C:\Program Files\Python313' }
    $v = Join-Path $Tmp 'venv-check'
    New-Item -ItemType Directory -Force (Join-Path $v 'Scripts') | Out-Null
    Assert-True ((Test-VenvMatchesPython $v $py) -match 'python\.exe is missing') 'empty venv reused'
    Set-Content (Join-Path $v 'Scripts\python.exe') 'x'
    Assert-True ((Test-VenvMatchesPython $v $py) -match 'pyvenv\.cfg') 'venv without pyvenv.cfg reused'
    $cfg = Join-Path $v 'pyvenv.cfg'
    # The real pyvenv.cfg of the development venv that was reused.
    Set-Content $cfg @('home = C:\Users\x\AppData\Roaming\uv\python\cpython-3.11.16-windows-x86_64-none', 'include-system-site-packages = false', 'version = 3.11.16')
    Assert-Equal '3.11' (Read-VenvConfig $v).Version
    Assert-True ((Test-VenvMatchesPython $v $py) -match 'Python 3\.11.*Python 3\.13') '3.11 venv reused for 3.13'
    Set-Content $cfg @('home = C:\Users\x\AppData\Local\Programs\Python\Python313', 'version = 3.13.5')
    Assert-True ((Test-VenvMatchesPython $v $py) -match 'made from the Python in') 'per-user venv kept after an all-users Python was chosen'
    Set-Content $cfg @('home = c:\program files\python313\', 'version_info = 3.13.5.final.0')
    Assert-True ($null -eq (Test-VenvMatchesPython $v $py)) 'matching venv not reused'
    $moved = Move-VenvAside $v
    Assert-True ((-not (Test-Path $v)) -and (Test-Path (Join-Path $moved 'pyvenv.cfg')) -and $moved -like "$v.old-*") "not moved aside: $moved"
}
Test-Case 'install-server.ps1: database settings checked before anything is asked, installed or written; real sign-in errors' {
    $t = Get-Content (Join-Path $Repo 'installer\server\install-server.ps1') -Raw
    $order = 'Test-ExistingDbSettings', 'Campus address of this server', 'Test-VenvMatchesPython', 'Install-PythonPackages', 'Initialize-DotEnv', 'Get-DbSignIn'
    $at = @($order | ForEach-Object { $t.IndexOf($_) })
    for ($i = 0; $i -lt $order.Count; $i++) { Assert-True ($at[$i] -ge 0) "$($order[$i]) not used" }
    for ($i = 1; $i -lt $order.Count; $i++) { Assert-True ($at[$i - 1] -lt $at[$i]) "$($order[$i - 1]) must come before $($order[$i])" }
    Assert-True ($t -match 'ConvertTo-DbErrorText') 'sign-in errors not explained'
    foreach ($f in Get-ChildItem (Join-Path $Repo 'installer\server') -Filter *.ps1) {
        Assert-True ((Get-Content $f.FullName -Raw) -notmatch 'wrong password, or the database service') "$($f.Name) still guesses 'wrong password'"
    }
}
Test-Case 'WinSW service definition: boot start, crash restart, database dependency, XML-safe' {
    $defs = Get-ServiceDefinitions 8000
    Assert-Equal 2 $defs.Count
    $defs[0].Exe = 'C:\Tools & Co\waitress-serve.exe'
    [xml]$x = New-WinSWXml $defs[0] 'MariaDB' 'C:\CompuLab\logs'
    Assert-Equal 'CompuLabWeb' $x.service.id
    Assert-Equal 'Automatic' $x.service.startmode
    Assert-Equal 'MariaDB' $x.service.depend
    Assert-Equal 'C:\Tools & Co\waitress-serve.exe' $x.service.executable
    Assert-Equal 3 @($x.service.onfailure).Count
    Assert-True ($x.service.arguments -match '0\.0\.0\.0:8000') 'listen address'
    [xml]$w = New-WinSWXml $defs[1] '' 'C:\CompuLab\logs'
    Assert-True (-not $w.service.depend) 'empty dependency written'
    Assert-Equal 'manage.py run_worker' $w.service.arguments
    Assert-True (@($w.service.env | Where-Object { $_.name -eq 'COMPULAB_BACKGROUND_TASKS' -and $_.value -eq 'False' }).Count -eq 1) 'worker env'
}
Test-Case 'web port comes from COMPULAB_PORT, then SITE_URL, else 8000' {
    [IO.File]::WriteAllLines($script:EnvFile, [string[]]@('SITE_URL=http://10.0.0.5:8123'))
    Assert-Equal 8123 (Get-SitePort)
    Set-DotEnvValue 'COMPULAB_PORT' '9001'; Assert-Equal 9001 (Get-SitePort)
    Remove-Item $script:EnvFile; Assert-Equal 8000 (Get-SitePort)
}
Test-Case 'Python 3.14 is not picked (packages are built for 3.11-3.13)' {
    $py = Find-Python
    if ($py) { Assert-True ([version]$py.Version -lt [version]'3.14') "picked $($py.Version)" }
}
Test-Case 'Python detection really finds an installed 3.11-3.13 (regression: quotes dropped by PowerShell 5.1)' {
    $installed = Invoke-Quiet 'py' @('-0')
    if ("$installed" -match '-V:3\.1[123]\b') {
        $py = Find-Python
        Assert-True $py "py -0 lists a supported Python but Find-Python found none: $installed"
        Assert-True ($py.Version -match '^3\.1[123]$') "version '$($py.Version)'"
    } else { Write-Host '         (no Python 3.11-3.13 on this PC: detection not exercised)' -ForegroundColor DarkYellow }
}
Test-Case 'database tools are found in a real MariaDB/MySQL install before XAMPP (regression)' {
    $installed = @(Get-ChildItem -Path "$env:ProgramFiles\MariaDB*\bin\mysql.exe", "$env:ProgramFiles\MySQL\MySQL Server*\bin\mysql.exe" -ErrorAction SilentlyContinue)
    if ($installed.Count) {
        $found = Find-MySqlTool 'mysql.exe'
        Assert-True ($found -and $found -notlike '*\xampp\*') "found '$found' although $($installed[0].FullName) exists"
    } else { Write-Host '         (no MariaDB/MySQL server installed: lookup order not exercised)' -ForegroundColor DarkYellow }
}
Test-Case 'Invoke-Quiet returns output and survives programs that write to stderr' {
    $ErrorActionPreference = 'Stop'
    $out = Invoke-Quiet 'cmd.exe' @('/c', 'echo to-stdout & echo to-stderr 1>&2 & exit /b 3')
    Assert-True ("$out" -match 'to-stdout') "output: $out"
    Assert-True ($LASTEXITCODE -eq 3) "exit code $LASTEXITCODE"
}
Test-Case 'Python check: 64-bit 3.11-3.13 accepted; 3.14, 3.10 and 32-bit refused with the reason' {
    Assert-Equal '3.13' (ConvertFrom-PythonProbe '3.13|64|C:\Program Files\Python313').Version
    Assert-True ($null -eq (ConvertFrom-PythonProbe 'Python was not found; run without arguments to install')) 'garbage parsed'
    Assert-True ($null -eq (Test-PythonSupported (ConvertFrom-PythonProbe '3.13|64|C:\Program Files\Python313'))) '3.13 64-bit refused'
    Assert-True ($null -eq (Test-PythonSupported (ConvertFrom-PythonProbe '3.11|64|C:\Python311'))) '3.11 64-bit refused'
    Assert-True ((Test-PythonSupported (ConvertFrom-PythonProbe '3.14|64|C:\Python314')) -match 'not supported') '3.14 accepted'
    Assert-True ((Test-PythonSupported (ConvertFrom-PythonProbe '3.10|64|C:\Python310')) -match 'not supported') '3.10 accepted'
    Assert-True ((Test-PythonSupported (ConvertFrom-PythonProbe '3.13|32|C:\Python313-32')) -match '32-bit') '32-bit accepted'
}
Test-Case 'Python installed for one Windows account only is noticed (the services would depend on that profile)' {
    Assert-True (Test-PythonForAllUsers 'C:\Program Files\Python313') 'all-users install not recognised'
    Assert-True (-not (Test-PythonForAllUsers "$env:SystemDrive\Users\someone\AppData\Local\Programs\Python\Python313")) 'per-user install not noticed'
}
Test-Case 'the real Python probe runs on this PC (no quotes for PowerShell 5.1 to drop)' {
    $py = Find-Python
    if ($py) { Assert-True ($py.Version -match '^3\.1[123]$' -and $py.BasePrefix) "found $($py.Version) at '$($py.BasePrefix)'" }
    else { Write-Host "         (no 64-bit Python 3.11-3.13 here; rejected: $($script:PythonRejected -join '; '))" -ForegroundColor DarkYellow }
}
Test-Case 'database service choice: never XAMPP, a single real one, else the running one, else ask (no guessing)' {
    $xampp = [pscustomobject]@{ Name = 'mysql'; State = 'Running'; PathName = 'C:\xampp\mysql\bin\mysqld.exe --defaults-file=c:\xampp\mysql\bin\my.ini mysql' }
    $maria = [pscustomobject]@{ Name = 'MariaDB'; State = 'Stopped'; PathName = '"C:\Program Files\MariaDB 11.4\bin\mysqld.exe" "--defaults-file=C:\Program Files\MariaDB 11.4\data\my.ini" "MariaDB"' }
    $mysql84 = [pscustomobject]@{ Name = 'MySQL84'; State = 'Running'; PathName = '"C:\Program Files\MySQL\MySQL Server 8.4\bin\mysqld.exe" --defaults-file="C:\ProgramData\MySQL\MySQL Server 8.4\my.ini" MySQL84' }
    $other = [pscustomobject]@{ Name = 'Spooler'; State = 'Running'; PathName = 'C:\Windows\System32\spoolsv.exe' }
    Assert-True ($null -eq (Select-DbService @($xampp, $other))) 'XAMPP chosen'
    Assert-Equal 'MariaDB' (Select-DbService @($xampp, $maria, $other))
    Assert-Equal 'MySQL84' (Select-DbService @($maria, $mysql84))
    $maria2 = [pscustomobject]@{ Name = 'MariaDB2'; State = 'Stopped'; PathName = 'C:\Program Files\MariaDB 10.11\bin\mysqld.exe' }
    Assert-Throws { Select-DbService @($maria, $maria2) } 'DbServiceName'
    # The service that owns the database port wins, also among several (but never XAMPP).
    Assert-Equal 'MariaDB2' (Select-DbService @($maria, $maria2) 'MariaDB2')
    Assert-True ($null -eq (Select-DbService @($xampp) 'mysql')) 'XAMPP chosen because it owns the port'
}
Test-Case 'database port check: no server, XAMPP or another program on the port is refused; MariaDB/MySQL accepted' {
    Assert-True ((Test-DbListener $null '127.0.0.1' 3306) -match 'No database server is listening on port 3306') 'nothing listening'
    $xamppL = @{ ProcessId = 1; ProcessPath = 'C:\xampp\mysql\bin\mysqld.exe'; ServiceName = 'mysql' }
    $msg = Test-DbListener $xamppL '127.0.0.1' 3306
    Assert-True ($msg -match 'XAMPP' -and $msg -match 'does not use, stop or change' -and $msg -match '3307') "xampp: $msg"
    $other = @{ ProcessId = 2; ProcessPath = 'C:\Program Files\Some App\server.exe'; ServiceName = '' }
    Assert-True ((Test-DbListener $other 'localhost' 3306) -match 'not a MariaDB/MySQL server') 'other program accepted'
    foreach ($ok in 'C:\Program Files\MariaDB 11.4\bin\mysqld.exe', 'C:\Program Files\MariaDB 11.4\bin\mariadbd.exe', 'C:\Program Files\MySQL\MySQL Server 8.4\bin\mysqld.exe', '') {
        Assert-True ($null -eq (Test-DbListener @{ ProcessId = 3; ProcessPath = $ok; ServiceName = 'MariaDB' } '127.0.0.1' 3307)) "refused $ok"
    }
    Assert-True ($null -eq (Test-DbListener $null '10.0.0.5' 3306)) 'a database on another computer is not checked here'
}
Test-Case 'database port check: another program''s bundled MariaDB service is refused untouched (regression: InventoryDatabase on 3307)' {
    # As found on a real server PC: an inventory program's own MariaDB service.
    $inv = @{ ProcessId = 5312; ProcessPath = 'C:\Program Files\Inventory Management System\runtime\mariadb\bin\mariadbd.exe'; ServiceName = 'InventoryDatabase' }
    $msg = Test-DbListener $inv '127.0.0.1' 3307
    Assert-True ($msg -match "service 'InventoryDatabase'" -and $msg -match 'does not use, stop or change' -and $msg -match '-DbPort 3308') "unclear: $msg"
    Assert-True ($msg -notmatch '-DbServiceName') 'still suggests using the other program''s service'
    Assert-True ($null -eq (Test-DbListener $inv '127.0.0.1' 3307 'InventoryDatabase')) 'refused although named explicitly with -DbServiceName'
    # A database started by hand (no service, e.g. the end-to-end test) and real MariaDB/MySQL services are accepted.
    Assert-True ($null -eq (Test-DbListener @{ ProcessId = 9; ProcessPath = 'C:\Program Files\MySQL\MySQL Server 8.4\bin\mysqld.exe'; ServiceName = '' } '127.0.0.1' 50000)) 'hand-started server refused'
    foreach ($svc in 'MariaDB', 'MySQL84', 'MySQL80', 'MariaDB_11.4') {
        Assert-True ($null -eq (Test-DbListener @{ ProcessId = 3; ProcessPath = 'C:\Program Files\MariaDB 11.4\bin\mariadbd.exe'; ServiceName = $svc } '127.0.0.1' 3308)) "refused service $svc"
    }
    $t = Get-Content (Join-Path $Repo 'installer\server\install-server.ps1') -Raw
    Assert-True ($t.IndexOf('Test-DbListener $listener') -lt $t.IndexOf('Start-Service $dbService')) 'port owner not checked before a database service is started'
    Assert-True ($t.IndexOf('Test-DbListener $listener') -lt $t.IndexOf('Set-Service $dbService')) 'port owner not checked before a database service is changed'
}
Test-Case 'database tools come from the folder of the server on the port (MariaDB 11: mariadb*.exe only)' {
    Assert-True ($null -eq (Get-DbServerBinDir $null)) 'no listener'
    Assert-True ($null -eq (Get-DbServerBinDir @{ ProcessPath = '' })) 'no path'
    Assert-True ($null -eq (Get-DbServerBinDir @{ ProcessPath = 'C:\no\such\folder\mariadbd.exe' })) 'missing folder'
    $bin = Join-Path $Tmp 'MariaDB 11.4\bin'
    New-Item -ItemType Directory -Force $bin | Out-Null
    Assert-Equal $bin (Get-DbServerBinDir @{ ProcessPath = "$bin\mariadbd.exe" }) 'program path'
    $svcLine = "`"$bin\mariadbd.exe`" `"--defaults-file=C:\ProgramData\x\my.ini`" `"MariaDB`""
    Assert-Equal $bin (Get-DbServerBinDir @{ ProcessPath = $svcLine }) 'quoted service command line'
    Assert-Equal $bin (Get-DbServerBinDir @{ ProcessPath = "$bin\mariadbd.exe --defaults-file=x MariaDB" }) 'unquoted service command line'
    foreach ($n in 'mariadb.exe', 'mariadb-dump.exe', 'mariadbd.exe') { Set-Content (Join-Path $bin $n) 'x' }
    Assert-Equal (Join-Path $bin 'mariadb.exe') (Select-DbClientInDir $bin 'client')
    Assert-Equal (Join-Path $bin 'mariadb-dump.exe') (Select-DbClientInDir $bin 'dump')
    $my = Join-Path $Tmp 'MySQL Server 8.4\bin'
    New-Item -ItemType Directory -Force $my | Out-Null
    foreach ($n in 'mysql.exe', 'mysqldump.exe') { Set-Content (Join-Path $my $n) 'x' }
    Assert-Equal (Join-Path $my 'mysql.exe') (Select-DbClientInDir $my 'client')
    Assert-Equal (Join-Path $my 'mysqldump.exe') (Select-DbClientInDir $my 'dump')
    Assert-True ($null -eq (Select-DbClientInDir (Join-Path $Tmp 'nothing-here') 'client')) 'empty folder'
    # No server on the port: the first installed client, as before.
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $free = $l.LocalEndpoint.Port; $l.Stop()
    Assert-Equal "$(Find-MySqlTool 'mysql.exe')" "$(Find-DbClient 'client' "$free" '127.0.0.1')" 'fallback changed'
    foreach ($f in 'backup.ps1', 'restore.ps1', 'install-server.ps1') {
        $s = Get-Content (Join-Path $Repo "installer\server\$f") -Raw
        Assert-True ($s -match 'Find-DbClient' -and $s -notmatch "Find-MySqlTool '(mysql|mysqldump|mariadb|mariadb-dump)\.exe'") "$f does not take the tools of the server on the port"
    }
}
Test-Case 'the database servers on this PC are identified by the service that owns the port (read-only)' {
    $l3306 = Get-ListenerInfo 3306
    if ($l3306 -and "$($l3306.ProcessPath)" -match 'MySQL Server 8') {
        # MySQL 8.4: the port belongs to a child mysqld; the service is its parent's.
        Assert-True ($l3306.ServiceName -match '^MySQL') "3306 service: '$($l3306.ServiceName)'"
        Assert-True ((Find-DbClient 'dump' '3306' '127.0.0.1') -like '*\MySQL Server 8*\bin\mysqldump.exe') 'MySQL 8.4 dump tool not taken from its own folder'
    } else { Write-Host '         (no MySQL 8 service on 3306 here: not exercised)' -ForegroundColor DarkYellow }
    $l3307 = Get-ListenerInfo 3307
    if ($l3307 -and $l3307.ServiceName -and $l3307.ServiceName -notmatch '^(MariaDB|MySQL)') {
        Assert-True ((Test-DbListener $l3307 '127.0.0.1' 3307) -match 'database of another program') "another program's database on 3307 accepted ($($l3307.ServiceName))"
    } else { Write-Host '         (no other program''s database on 3307 here: not exercised)' -ForegroundColor DarkYellow }
}
Test-Case 'repair cannot switch to another database name or user (installer check, before any change)' {
    $text = Get-Content (Join-Path $Repo 'installer\server\install-server.ps1') -Raw
    Assert-True ($text -match 'cannot be changed on an existing installation') 'guard missing'
    Assert-True ($text -match "Set-DotEnvValue \`$pair\[1\]") 'explicit DbPort/DbHost change not written to .env'
}
Test-Case 'backup folder: format rules, writable check, and the nightly task line round-trips' {
    Assert-True ($null -eq (Test-BackupRootFormat 'E:\CompuLabBackups')) 'drive path refused'
    Assert-True ($null -eq (Test-BackupRootFormat '\\nas\share\CompuLab')) 'UNC refused'
    foreach ($bad in '', 'backups', '\backups', 'E:backups', 'E:\Back|ups') { Assert-True (Test-BackupRootFormat $bad) "accepted '$bad'" }
    $writable = Join-Path $Tmp 'backup root with space'
    Assert-True ($null -eq (Test-BackupRoot $writable)) 'writable folder refused'
    Assert-True (Test-Path $writable) 'folder not created'
    Assert-Equal 0 @(Get-ChildItem $writable -Force).Count 'write test left a file behind'
    $file = Join-Path $Tmp 'not-a-folder.txt'; Set-Content $file 'x'
    Assert-True ((Test-BackupRoot (Join-Path $file 'sub')) -match 'Cannot write') 'path under a file accepted'
    $d = New-BackupTaskDefinition 'C:\CompuLab\installer\server\backup.ps1' 'E:\My Backups'
    Assert-Equal 'E:\My Backups' (Get-BackupRootFromTaskArguments $d.Action.Arguments)
    Assert-Equal 'D:\B' (Get-BackupRootFromTaskArguments '-File x.ps1 -BackupRoot D:\B -Log')
    Assert-True ($null -eq (Get-BackupRootFromTaskArguments '-File x.ps1 -Log')) 'no -BackupRoot'
}
function New-UsersReadableRoot([string]$Name) {
    # A backup root like C:\CompuLab\backups: BUILTIN\Users may read (inheritable).
    $r = Join-Path $Tmp $Name; New-Item -ItemType Directory -Path $r | Out-Null
    & icacls $r /grant '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    return $r
}
function Get-AceSids([string]$Path) { return @((Get-Acl -LiteralPath $Path).Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique) }
Test-Case 'backup folder is protected BEFORE anything is written (regression: files inherited Users read until the end)' {
    $root = New-UsersReadableRoot 'bk-order'
    $seen = @{}
    $final = Invoke-ProtectedBackup $root '20990101-010101' {
        param($t)
        $seen.Folder = Get-AceSids $t; $seen.Protected = (Get-Acl -LiteralPath $t).AreAccessRulesProtected; $seen.Name = Split-Path $t -Leaf
        [IO.File]::WriteAllText((Join-Path $t 'env.txt'), 'test-only-content')
        $seen.File = Get-AceSids (Join-Path $t 'env.txt')
    }
    $allowed = Get-BackupAllowedSids
    Assert-Equal 'partial-compulab-20990101-010101' $seen.Name 'written under the partial- name'
    Assert-True $seen.Protected 'folder inherited permissions while being written'
    Assert-True (-not @($seen.Folder | Where-Object { $allowed -notcontains $_ }).Count) "folder open to: $($seen.Folder -join ', ')"
    Assert-True (-not @($seen.File | Where-Object { $allowed -notcontains $_ }).Count) "env.txt open to: $($seen.File -join ', ') while written"
    Assert-True ($seen.File -notcontains 'S-1-5-32-545') 'BUILTIN\Users could read env.txt'
    Assert-Equal (Join-Path $root 'compulab-20990101-010101') $final 'final name'
    Assert-True (Test-BackupFolderProtected $final) 'final folder not protected'
    Assert-Equal 0 @(Get-ChildItem $root -Directory -Filter 'partial-*').Count 'partial- folder left behind'
    $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('test-only-content'))) -replace '-', ''
    Assert-Equal $sha (Get-FileHash (Join-Path $final 'env.txt') -Algorithm SHA256).Hash 'content changed'
}
Test-Case 'backup folder: same-second and simultaneous backups never share a folder (contention)' {
    $root = New-UsersReadableRoot 'bk-contention'
    New-Item -ItemType Directory (Join-Path $root 'compulab-20990101-020202') | Out-Null   # an existing backup with the same time
    $a = Invoke-ProtectedBackup $root '20990101-020202' { param($t) Set-Content (Join-Path $t 'x') 'a' }
    Assert-Equal (Join-Path $root 'compulab-20990101-020202-2') $a 'existing name not skipped'
    $common = Join-Path $Repo 'installer\server\common.ps1'
    $jobs = 1..4 | ForEach-Object { Start-Job -ScriptBlock { param($c, $r) . $c; New-ProtectedBackupFolder $r '20990101-030303' } -ArgumentList $common, $root }
    $names = @($jobs | Wait-Job -Timeout 120 | Receive-Job); $jobs | Remove-Job -Force
    Assert-Equal 4 $names.Count "4 simultaneous backups returned $($names.Count) folders"
    Assert-Equal 4 @($names | Sort-Object -Unique).Count "folders shared: $($names -join ', ')"
    foreach ($n in $names) { Assert-True (Test-BackupFolderProtected $n) "$n not protected" }
}
Test-Case 'backup folder: a backup root this account cannot write to is refused before anything is written' {
    $root = Join-Path $Tmp 'bk-denied'; New-Item -ItemType Directory -Path $root | Out-Null
    & icacls $root /deny "*$(Get-CurrentUserSid):(OI)(CI)(WD,AD)" | Out-Null
    try {
        Assert-True ((Test-BackupRoot $root) -match 'Cannot write') 'Test-BackupRoot accepted a folder it cannot write to'
        Assert-Throws { New-ProtectedBackupFolder $root '20990101-040404' } ''
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue).Count 'something was created'
    } finally { & icacls $root /remove:d "*$(Get-CurrentUserSid)" | Out-Null }
}
Test-Case 'backup space: too little free space is refused before any folder exists; need = 2x the newest backup, at least 100 MB' {
    $root = New-UsersReadableRoot 'bk-space'
    Assert-Equal (100MB) (Get-BackupSpaceNeed $root) 'empty root'
    $old = Join-Path $root 'compulab-20990101-050505'; New-Item -ItemType Directory $old | Out-Null
    $fs = [IO.File]::Create((Join-Path $old 'database.sql')); $fs.SetLength(60MB); $fs.Close()
    Assert-Equal (120MB) (Get-BackupSpaceNeed $root) 'twice the newest backup'
    Assert-True ((Get-BackupSpaceProblem $root ([long]1e18)) -match 'Nothing was written') 'impossible need accepted'
    Assert-True ($null -eq (Get-BackupSpaceProblem $root 1KB)) 'small need refused'
    Assert-True ($null -eq (Get-BackupSpaceProblem '\\nas\share\x' ([long]1e18))) 'network share must not be refused'
    $text = Get-Content (Join-Path $Repo 'installer\server\backup.ps1') -Raw
    Assert-True ($text.IndexOf('Get-BackupSpaceProblem') -gt 0 -and $text.IndexOf('Get-BackupSpaceProblem') -lt $text.IndexOf('Invoke-ProtectedBackup $BackupRoot')) 'backup.ps1 does not check the space before creating the folder'
}
Test-Case 'failed backup: kept as incomplete-compulab-... (protected), error passed on, earlier backups untouched' {
    $root = New-UsersReadableRoot 'bk-fail'
    $good = Invoke-ProtectedBackup $root '20990101-060606' { param($t) Set-Content (Join-Path $t 'database.sql') 'good backup' }
    $goodHash = (Get-FileHash (Join-Path $good 'database.sql')).Hash
    Assert-Throws { Invoke-ProtectedBackup $root '20990101-070707' { param($t) Set-Content (Join-Path $t 'database.sql') 'half a dump'; throw 'simulated dump failure' } } 'simulated dump failure'
    $inc = Join-Path $root 'incomplete-compulab-20990101-070707'
    Assert-True (Test-Path $inc) 'partial backup not kept as incomplete-'
    Assert-True (Test-BackupFolderProtected $inc) 'incomplete backup not protected'
    Assert-True (-not (Test-Path (Join-Path $root 'compulab-20990101-070707'))) 'a failed backup got a compulab- name'
    Assert-Equal "$good" "$(@(Get-ChildItem $root -Directory -Filter 'compulab-*').FullName)" 'retention would count something other than the good backup'
    Assert-Equal $goodHash (Get-FileHash (Join-Path $good 'database.sql')).Hash 'earlier backup changed'
}
Test-Case 'interrupted backup (process killed while writing): stays partial-compulab-..., protected, never a compulab- backup' {
    $root = New-UsersReadableRoot 'bk-killed'
    $common = Join-Path $Repo 'installer\server\common.ps1'
    $job = Start-Job -ScriptBlock { param($c, $r) . $c; Invoke-ProtectedBackup $r '20990101-080808' { param($t) Set-Content (Join-Path $t 'database.sql') 'half'; Start-Sleep 60 } } -ArgumentList $common, $root
    $file = Join-Path $root 'partial-compulab-20990101-080808\database.sql'
    $deadline = (Get-Date).AddSeconds(60); while (-not (Test-Path $file) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    Assert-True (Test-Path $file) 'the job never started writing'
    $job | Stop-Job; $job | Remove-Job -Force
    Assert-True (Test-BackupFolderProtected (Split-Path $file)) 'killed backup folder not protected'
    Assert-True (-not @(Get-AceSids $file | Where-Object { (Get-BackupAllowedSids) -notcontains $_ }).Count) 'killed backup file readable by others'
    Assert-Equal 0 @(Get-ChildItem $root -Directory -Filter 'compulab-*').Count 'a killed backup counts as a backup'
}
Test-Case 'configured backup folder: .env value wins, otherwise the default (never silently reset)' {
    [IO.File]::WriteAllLines($script:EnvFile, [string[]]@('SITE_URL=http://10.0.0.5:8000', 'COMPULAB_BACKUP_ROOT=E:\CompuLabBackups'))
    $c = Get-ConfiguredBackupRoot
    Assert-Equal 'E:\CompuLabBackups' $c.Path
    Assert-True ($c.Source -match '\.env') $c.Source
    [IO.File]::WriteAllLines($script:EnvFile, [string[]]@('SITE_URL=http://10.0.0.5:8000'))
    $c = Get-ConfiguredBackupRoot
    # No task named "CompuLab nightly backup" on a development PC: the default.
    if (-not (Get-ScheduledTask -TaskName $script:BackupTaskName -ErrorAction SilentlyContinue)) { Assert-Equal $script:DefaultBackupRoot $c.Path }
    Remove-Item $script:EnvFile
    $text = Get-Content (Join-Path $Repo 'installer\server\install-server.ps1') -Raw
    Assert-True ($text -match 'BackupRoot = \$configuredBackup\.Path') 'install-server.ps1 does not start from the configured folder'
    Assert-True ($text -match "Set-DotEnvValue 'COMPULAB_BACKUP_ROOT'") 'install-server.ps1 does not record the folder'
    foreach ($f in 'backup.ps1', 'update.ps1', 'restore.ps1') {
        Assert-True ((Get-Content (Join-Path $Repo "installer\server\$f") -Raw) -match 'Get-ConfiguredBackupRoot') "$f ignores the configured folder"
    }
    Assert-True ((Get-Content (Join-Path $Repo 'installer\server\Backup Now.cmd') -Raw) -match 'backup\.ps1" -Log') 'Back Up Now does not log'
}
Test-Case 'first Administrator: email rules and the ensure_admin result line' {
    Assert-True ($null -eq (Test-AdminEmail 'lab.admin.example@gmail.com')) 'gmail refused'
    Assert-True ($null -eq (Test-AdminEmail ' Lab.Admin@Gmail.com ')) 'mixed case refused'
    foreach ($bad in '', 'admin', 'admin@school.edu.ph', 'a b@gmail.com') { Assert-True (Test-AdminEmail $bad) "accepted '$bad'" }
    $r = ConvertFrom-EnsureAdminOutput @('System check...', 'RESULT: CREATED: Administrator la***@gmail.com created.') 0
    Assert-Equal 'CREATED|0' "$($r.Code)|$($r.ExitCode)"
    $r = ConvertFrom-EnsureAdminOutput @('RESULT: INVALID: The password is not accepted: This password is too common.') 2
    Assert-Equal 'INVALID|2' "$($r.Code)|$($r.ExitCode)"
    $r = ConvertFrom-EnsureAdminOutput @('Traceback (most recent call last):', 'django.db.utils.OperationalError: no such table') 1
    Assert-True ($r.Code -eq 'ERROR' -and $r.Message -match 'OperationalError') $r.Message
    $r = ConvertFrom-EnsureAdminOutput @() 0
    Assert-True ($r.ExitCode -ne 0) 'empty output treated as success'
}
Test-Case 'installer never reports success without a working Administrator (code check)' {
    $text = Get-Content (Join-Path $Repo 'installer\server\install-server.ps1') -Raw
    Assert-True ($text -notmatch 'createsuperuser') 'the unchecked createsuperuser call is back'
    Assert-True ($text -match "Invoke-EnsureAdmin @\('--check'\)") 'no final check'
    Assert-True ($text -match 'The first Administrator account was not created') 'no failure message'
}

Write-Host "`nBundled runtime (CompuLab's own Python and MariaDB)" -ForegroundColor Cyan
Test-Case 'database port: 3308 if free; busy ports skipped in order (whatever uses them is never touched); none free: clear error' {
    $taken = @{}
    $isFree = { param($p) -not $taken.ContainsKey($p) }
    Assert-Equal 3308 (Select-DbPort 3308 $isFree)
    $taken[3308] = 'MySQL84'; Assert-Equal 3309 (Select-DbPort 3308 $isFree) 'one busy port'
    $taken[3309] = 'InventoryDatabase'; $taken[3310] = 'XAMPP'
    Assert-Equal 3311 (Select-DbPort 3308 $isFree) 'several busy ports'
    Assert-Throws { Select-DbPort 3308 { param($p) $false } 5 } 'No free port .* between 3308 and 3312'
}
Test-Case 'database port on this PC (read-only): the ports of other database servers are skipped' {
    $busy = @(3306, 3307 | Where-Object { Get-NetTCPConnection -LocalPort $_ -State Listen -ErrorAction SilentlyContinue })
    $chosen = Select-DbPort 3306
    foreach ($b in $busy) { Assert-True ($chosen -ne $b) "chose $b, which is in use" }
    Assert-True ($chosen -ge 3306) "chose $chosen"
    if ($busy.Count -eq 2) { Assert-True ($chosen -ge 3308) "chose $chosen although 3306 and 3307 are in use" }
}
Test-Case "CompuLab's my.ini: 127.0.0.1 only and the port in the [mysqld] section (regression: settings appended into [client])" {
    $ini = New-BundledDbConfig 'C:\CompuLab\data\mariadb' 3309 'C:\CompuLab\runtime\mariadb'
    $section = ''; $mysqld = @{}
    foreach ($line in $ini -split "`r?`n") {
        if ($line -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
        if ($section -eq 'mysqld' -and $line -match '^([a-z_-]+)=(.*)$') { $mysqld[$Matches[1]] = $Matches[2] }
    }
    Assert-Equal '127.0.0.1' $mysqld['bind-address']
    Assert-Equal '3309' $mysqld['port']
    Assert-Equal 'C:/CompuLab/data/mariadb' $mysqld['datadir']
    Assert-Equal 'utf8mb4' $mysqld['character-set-server']
    Assert-True ($ini -notmatch '(?i)password|skip-grant') 'password or skip-grant-tables in my.ini'
    $saved = $script:BundledDbConfig
    try {
        $script:BundledDbConfig = Join-Path $Tmp 'my.ini'
        [IO.File]::WriteAllText($script:BundledDbConfig, $ini)
        Assert-Equal 3309 (Get-BundledDbPort)
        Remove-Item $script:BundledDbConfig; Assert-Equal 0 (Get-BundledDbPort)
    } finally { $script:BundledDbConfig = $saved }
}
Test-Case 'root is secured before the server ever listens (bootstrap SQL): password set, local only, no anonymous accounts' {
    $sql = Get-BundledDbRootSql "pa'ss\word"
    Assert-True ($sql.TrimStart().StartsWith('FLUSH PRIVILEGES;')) 'account tables not loaded first (bootstrap runs with --skip-grant-tables: error 1290)'
    Assert-True ($sql -match "ALTER USER 'root'@'localhost' IDENTIFIED BY 'pa''ss\\\\word'") 'password not escaped'
    Assert-True ($sql -match "DROP USER IF EXISTS ''@'localhost'" -and $sql -match "DROP USER IF EXISTS ''@'%'") 'anonymous accounts kept'
    Assert-True ($sql -notmatch "'root'@'%'" -and $sql -notmatch 'GRANT') 'root opened to the network'
    Assert-True ($sql -match "DELETE FROM mysql\.global_priv WHERE User = 'root' AND Host NOT IN \('localhost', '127\.0\.0\.1', '::1'\)") 'root@<computer name> (no password) kept'
}
Test-Case 'passwords reach programs only on stdin, UTF-8 without BOM (regression: bootstrap rejected the BOM), masked in output' {
    $secret = 'Secret-' + [guid]::NewGuid().ToString('N')
    # A console set to UTF-8 (code page 65001) made .NET write a BOM first.
    $saved = $null
    try { $saved = [Console]::InputEncoding; [Console]::InputEncoding = [Text.Encoding]::UTF8 } catch { }
    try { $r = Invoke-WithStdin "$env:SystemRoot\System32\findstr.exe" @('/R', '^') "first line $secret`nsecond line" @($secret) }
    finally { if ($saved) { try { [Console]::InputEncoding = $saved } catch { } } }
    Assert-Equal 0 $r.ExitCode
    Assert-True ($r.Lines[0].StartsWith('first line')) "first characters: $([int][char]$r.Lines[0][0]) (a BOM?)"
    Assert-True (($r.Lines -join ' ') -notmatch [regex]::Escape($secret) -and ($r.Lines -join ' ') -match '\*{8}') 'secret not masked'
    Assert-Equal 'abc ******** def' (Hide-Secret "abc $secret def" @($secret))
    Assert-Equal 'short ab' (Hide-Secret 'short ab' @('ab')) 'very short values must not be masked everywhere'
}
Test-Case 'runtime check: complete -> usable; a damaged or missing file or no manifest -> refused' {
    $rt = Join-Path $Tmp 'runtime-check'
    New-Item -ItemType Directory -Force (Join-Path $rt 'bin') | Out-Null
    Set-Content (Join-Path $rt 'bin\a.exe') 'program'; Set-Content (Join-Path $rt 'COPYING') 'GPL'
    Assert-True ((@(Test-RuntimeFiles $rt @('bin\a.exe'))) -match 'missing COMPULAB-MANIFEST') 'no manifest accepted'
    $lines = Get-ChildItem $rt -Recurse -File | ForEach-Object { "$((Get-FileHash $_.FullName).Hash.ToLower())  $($_.FullName.Substring($rt.Length + 1))" }
    [IO.File]::WriteAllLines((Join-Path $rt 'COMPULAB-MANIFEST.txt'), [string[]]$lines)
    Assert-Equal 0 @(Test-RuntimeFiles $rt @('bin\a.exe', 'COPYING')).Count 'complete runtime refused'
    Add-Content (Join-Path $rt 'bin\a.exe') 'tampered'
    Assert-True ((@(Test-RuntimeFiles $rt @())) -match 'damaged bin\\a\.exe') 'damaged file accepted'
    Remove-Item (Join-Path $rt 'COPYING')
    $p = @(Test-RuntimeFiles $rt @('COPYING'))
    Assert-True (($p -match 'missing COPYING').Count -ge 1) "missing file accepted: $($p -join '; ')"
}
Test-Case 'the bundled MariaDB has everything the installer, backup and restore use (required-file list)' {
    foreach ($f in 'bin\mariadbd.exe', 'bin\server.dll', 'bin\mariadb.exe', 'bin\mariadb-dump.exe', 'bin\mariadb-install-db.exe', 'bin\mariadb-upgrade.exe', 'bin\mariadb-admin.exe', 'COPYING') {
        Assert-True ($script:BundledDbRequiredFiles -contains $f) "$f not required"
    }
    $build = Get-Content (Join-Path $Repo 'installer\build\build-installers.ps1') -Raw
    foreach ($f in $script:BundledDbRequiredFiles | Where-Object { $_ -like 'bin\*' }) {
        Assert-True ($build -match [regex]::Escape("'$($f.Substring(4))'")) "the build does not package $f"
    }
}
Test-Case "the database service: its own virtual account (not LocalSystem), mariadbd's service form, data folder closed to users" {
    $spec = Get-BundledDbServiceSpec
    Assert-Equal 'CompuLabMariaDB' $spec.Name
    Assert-Equal 'NT SERVICE\CompuLabMariaDB' $spec.Account
    $exe = Join-Path $script:BundledDbBin 'mariadbd.exe'
    Assert-Equal "`"$exe`" `"--defaults-file=$($script:BundledDbConfig)`" CompuLabMariaDB" $spec.BinaryPathName
    $acl = Get-BundledDbAclArgs
    Assert-True ($acl[0] -contains '/inheritance:r' -and $acl[0] -contains 'NT SERVICE\CompuLabMariaDB:(OI)(CI)M') "data ACL: $($acl[0] -join ' ')"
    $grants = @($acl[0] | Where-Object { $_ -match ':\(' })   # the permission entries, not the folder path
    Assert-True (-not ($grants -match 'S-1-5-32-545|S-1-5-11|S-1-1-0|Users|Everyone')) "users can read the database files: $($grants -join ' ')"
    Assert-True ($acl[1] -contains '/reset' -and $acl[1][0] -like '*\*') 'the files inside are not set back to inheriting from the folder'
    Assert-True ($acl[2] -contains 'NT SERVICE\CompuLabMariaDB:(OI)(CI)RX') 'the service cannot read its program files'
    foreach ($a in (Get-SecretFileAclArgs 'C:\x\.env'), (Get-AppFolderAclArgs)) { Assert-True ($a -contains '/inheritance:r') "inherited permissions kept: $($a -join ' ')" }
    # Regression (real install, 23 Oct 2026): icacls /inheritance:r ... /T left every file with no permission at all.
    foreach ($a in @($acl) + @(, (Get-AppFolderAclArgs))) { Assert-True (-not ($a -contains '/inheritance:r' -and $a -contains '/T')) "/inheritance:r combined with /T: $($a -join ' ')" }
    foreach ($f in Get-ChildItem (Join-Path $Repo 'installer\server'), (Join-Path $Repo 'installer\agent'), (Join-Path $Repo 'installer\build') -Filter *.ps1) {
        $n = 0
        foreach ($line in Get-Content $f.FullName) { $n++; if ($line -match "icacls.*inheritance:r.*['""]?/T['""]?(\s|,|\))") { throw "$($f.Name):$n combines /inheritance:r with /T" } }
    }
    Assert-True (-not ((Get-SecretFileAclArgs 'C:\x\.env') -match 'S-1-5-32-545|Users|Everyone')) 'users can read .env'
    Assert-True ((Get-AppFolderAclArgs) -contains '*S-1-5-32-545:(OI)(CI)RX' -and -not ((Get-AppFolderAclArgs) -match 'S-1-5-32-545:\(OI\)\(CI\)(F|M)')) 'users may change the program folder'
}
Test-Case 'database folder permissions on real files: files stay readable, and files an earlier installer left unreadable are repaired' {
    # The installer's own icacls calls, on a temporary folder, with this
    # account in place of the database service (which does not exist here).
    $me = Get-CurrentUserSid
    $saved = @{ Data = $script:BundledDbData; Dir = $script:BundledDbDir; Config = $script:BundledDbConfig }
    $root = Join-Path $Tmp 'acl-real'
    try {
        $script:BundledDbData = Join-Path $root 'data\mariadb'; $script:BundledDbDir = Join-Path $root 'runtime\mariadb'
        $script:BundledDbConfig = Join-Path $script:BundledDbData 'my.ini'
        New-Item -ItemType Directory -Force (Join-Path $script:BundledDbData 'mysql'), (Join-Path $script:BundledDbDir 'bin') | Out-Null
        Set-Content $script:BundledDbConfig '[mysqld]'; Set-Content (Join-Path $script:BundledDbData 'mysql\db.frm') 'x'; Set-Content (Join-Path $script:BundledDbDir 'bin\mariadbd.exe') 'x'
        # First the state the old call left on a real install: files without any permission.
        & icacls $script:BundledDbData /inheritance:r /grant:r "*${me}:(OI)(CI)F" /T /Q | Out-Null
        Assert-True (-not (Test-Readable $script:BundledDbConfig)) 'could not reproduce the broken state'
        foreach ($a in Get-BundledDbAclArgs) {
            $a = @($a | ForEach-Object { $_ -replace '^NT SERVICE\\CompuLabMariaDB:', "*${me}:" })
            & icacls @a | Out-Null
            Assert-Equal 0 $LASTEXITCODE "icacls $($a -join ' ')"
        }
        foreach ($f in $script:BundledDbConfig, (Join-Path $script:BundledDbData 'mysql\db.frm')) {
            Assert-True (Test-Readable $f) "$f not readable after the installer's permissions"
            Assert-True (@((Get-Acl $f).Access | Where-Object { -not $_.IsInherited }).Count -eq 0) "$f has its own entries instead of inheriting from the folder"
        }
        Assert-True ((Get-Acl $script:BundledDbData).AreAccessRulesProtected) 'the data folder still inherits from above'
        $users = @((Get-Acl $script:BundledDbData).Access | Where-Object { $_.IdentityReference -match 'Users|Everyone|Authenticated' })
        Assert-True ($users.Count -eq 0) 'ordinary users can read the database folder'
        Set-Content (Join-Path $script:BundledDbData 'new.ibd') 'n'
        Assert-True (Test-Readable (Join-Path $script:BundledDbData 'new.ibd')) 'a file the database creates later is not readable'
    } finally {
        & icacls $root /reset /T /Q 2>$null | Out-Null
        $script:BundledDbData = $saved.Data; $script:BundledDbDir = $saved.Dir; $script:BundledDbConfig = $saved.Config
    }
}
Test-Case 'an unreadable my.ini (left by an earlier installer) does not stop the settings check and is repaired before use (regression: "Access to the path my.ini is denied")' {
    $me = Get-CurrentUserSid
    $saved = @{ Data = $script:BundledDbData; Config = $script:BundledDbConfig }
    $root = Join-Path $Tmp 'acl-unreadable'
    try {
        $script:BundledDbData = Join-Path $root 'data\mariadb'; $script:BundledDbConfig = Join-Path $script:BundledDbData 'my.ini'
        New-Item -ItemType Directory -Force (Join-Path $script:BundledDbData 'mysql') | Out-Null
        Set-Content $script:BundledDbConfig "[mysqld]`r`nport=3308"; Set-Content (Join-Path $script:BundledDbData 'mysql\db.frm') 'x'
        & icacls $script:BundledDbData /inheritance:r /grant:r "*${me}:(OI)(CI)F" /T /Q | Out-Null
        Assert-True (-not (Test-Readable $script:BundledDbConfig)) 'could not reproduce the broken state'
        Assert-Equal 0 (Get-BundledDbPort)
        Repair-BundledDbFiles 6>$null | Out-Null
        foreach ($f in $script:BundledDbConfig, (Join-Path $script:BundledDbData 'mysql\db.frm')) { Assert-True (Test-Readable $f) "$f not repaired" }
        Assert-Equal 3308 (Get-BundledDbPort)
        Assert-True (Test-Path (Join-Path $script:BundledDbData 'mysql\db.frm')) 'a database file was moved or deleted'
        Repair-BundledDbFiles 6>$null | Out-Null   # readable: nothing to do
    } finally {
        & icacls $root /reset /T /Q 2>$null | Out-Null
        $script:BundledDbData = $saved.Data; $script:BundledDbConfig = $saved.Config
    }
    $c = Get-Content (Join-Path $Repo 'installer\server\common.ps1') -Raw
    $init = $c.Substring($c.IndexOf('function Initialize-BundledDb('))
    $init = $init.Substring(0, $init.IndexOf('function Test-DbHasCompuLabData'))
    $fix = $init.IndexOf('Repair-BundledDbFiles')
    foreach ($use in 'Get-BundledDbPort', 'WriteAllText($script:BundledDbConfig', 'Initialize-BundledDbService', "'--bootstrap'") {
        Assert-True ($fix -ge 0 -and $fix -lt $init.IndexOf($use)) "my.ini is used ($use) before its permissions are repaired"
    }
    $i = Get-Content (Join-Path $Repo 'installer\server\install-server.ps1') -Raw
    Assert-True ($i -match "recordedMode -eq 'bundled' -and [^\r\n]*existingEnv\['DB_PORT'\]") 'an unreadable my.ini would move an installed database to another port'
}
Test-Case "MariaDB's test databases: rights of every account (PUBLIC) removed on each install; the empty test database dropped only when just created" {
    $keep = Get-BundledDbHardeningSql
    Assert-True ($keep -match "DELETE FROM mysql\.db WHERE User = 'PUBLIC' AND Db IN \('test', 'test\\\\_%'\);\s*FLUSH PRIVILEGES;") $keep
    Assert-True ($keep -notmatch 'DROP DATABASE') 'a repair would drop a database'
    Assert-True ((Get-BundledDbHardeningSql -DropTestDatabase) -match '^DROP DATABASE IF EXISTS `test`;') 'a new data folder keeps the test database'
    $i = Get-Content (Join-Path $Repo 'installer\server\install-server.ps1') -Raw
    $bundledStep = $i.Substring($i.IndexOf("Setting up CompuLab's own database"), $i.IndexOf("Write-Step 'Preparing the database'") - $i.IndexOf("Setting up CompuLab's own database"))
    Assert-True ($bundledStep -match 'Get-BundledDbHardeningSql -DropTestDatabase:\(\[bool\]\$db\.Created\)') 'not run for CompuLab''s own database, or drops on a repair'
    Assert-True ($bundledStep.IndexOf('Get-DbSetupSql') -lt $bundledStep.IndexOf('Get-BundledDbHardeningSql') -and $bundledStep.IndexOf('Get-BundledDbHardeningSql') -lt $bundledStep.IndexOf('Set-BundledDbAutoStart')) 'wrong order'
    Assert-True ($i.LastIndexOf('Get-BundledDbHardeningSql') -lt $i.IndexOf("Write-Step 'Preparing the database'")) 'also run against an external server'
}
Test-Case 'setup exits with code 10 (not 0) when setting up CompuLab failed (regression: a failed silent install reported 0)' {
    $iss = Get-Content (Join-Path $Repo 'installer\build\CompuLab-Server.iss') -Raw
    Assert-True ($iss -match 'install-server\.ps1 failed with exit code[^\r\n]*\r?\n\s*ServerSetupFailed := True;') 'the failure is not recorded'
    Assert-True ($iss -match 'function GetCustomSetupExitCode: Integer;\s*begin[\s\S]{0,200}if ServerSetupFailed then Result := 10 else Result := 0;') 'the setup still exits 0 after a failure'
}
Test-Case 'database service: secured before it is registered; Manual until it worked; no restart loop during the bootstrap' {
    $c = Get-Content (Join-Path $Repo 'installer\server\common.ps1') -Raw
    Assert-True ($c -match 'New-Service [^\r\n]*-StartupType Manual') 'the service is created Automatic before it ever worked'
    $init = $c.Substring($c.IndexOf('function Initialize-BundledDb('))
    $init = $init.Substring(0, $init.IndexOf('function Test-DbHasCompuLabData'))
    $repair = $init.IndexOf('Initialize-BundledDbService'); $ini = $init.IndexOf('WriteAllText($script:BundledDbConfig')
    $boot = $init.IndexOf("'--bootstrap'"); $register = $init.LastIndexOf('Initialize-BundledDbService'); $start = $init.LastIndexOf('Start-BundledDb $Port')
    Assert-True ($repair -ge 0 -and $repair -lt $ini) 'an existing service''s folder is not repaired before my.ini is written'
    Assert-True ($boot -ge 0 -and $boot -lt $register -and $register -lt $start) 'not: bootstrap -> service + permissions -> start'
    Assert-True ($init -match "StartupType Disabled[\s\S]*'--bootstrap'[\s\S]*StartupType Manual") 'Windows could restart the service during the bootstrap'
    $i = Get-Content (Join-Path $Repo 'installer\server\install-server.ps1') -Raw
    Assert-True ($i.IndexOf('Set-BundledDbAutoStart') -gt $i.IndexOf("are ready")) 'set to Automatic before the database worked'
    Assert-True ($c -match 'function Protect-BundledDbData[\s\S]{0,700}ReadAllText\(\$script:BundledDbConfig\)') 'permissions are not proven by reading my.ini'
}
Test-Case "only CompuLab's own database counts as ours; local-only listening detected" {
    Assert-True (Test-ListenerIsBundledDb @{ ServiceName = 'CompuLabMariaDB'; ProcessPath = '' }) 'own service not recognised'
    Assert-True (-not (Test-ListenerIsBundledDb @{ ServiceName = 'InventoryDatabase'; ProcessPath = 'C:\Program Files\Inventory Management System\runtime\mariadb\bin\mariadbd.exe' })) 'another program''s MariaDB taken as ours'
    Assert-True (-not (Test-ListenerIsBundledDb @{ ServiceName = 'MySQL84'; ProcessPath = 'C:\Program Files\MySQL\MySQL Server 8.4\bin\mysqld.exe' })) 'MySQL taken as ours'
    Assert-True (-not (Test-ListenerIsBundledDb $null)) 'nothing taken as ours'
    Assert-True (Test-LocalOnlyAddresses @('127.0.0.1')) '127.0.0.1 not local'
    foreach ($bad in @(@('0.0.0.0'), @('::'), @('127.0.0.1', '192.168.1.36'), @())) { Assert-True (-not (Test-LocalOnlyAddresses $bad)) "accepted $($bad -join ',')" }
}
Test-Case 'services run the bundled Python when present (python -m waitress), after CompuLab''s database' {
    $defs = Get-ServiceDefinitions 8000
    Assert-Equal (Get-AppPython) $defs[0].Exe
    Assert-True ($defs[0].Args -match '^-m waitress --listen=0\.0\.0\.0:8000') "web args: $($defs[0].Args)"
    Assert-Equal (Get-AppPython) $defs[1].Exe
    [xml]$x = New-WinSWXml $defs[0] 'CompuLabMariaDB' 'C:\CompuLab\logs'
    Assert-Equal 'CompuLabMariaDB' $x.service.depend
}
Test-Case 'install-server.ps1: own database by default for a new setup install; Repair keeps the recorded mode; checks before changes' {
    $t = Get-Content (Join-Path $Repo 'installer\server\install-server.ps1') -Raw
    Assert-True ($t -match "elseif \(Test-BundledDbAvailable\) \{ 'bundled' \}") 'bundled is not the default with a runtime'
    Assert-True ($t -match "\`$recordedMode = \`$\(if \(\`$firstRun\) \{ '' \} else \{ 'external' \}\)") 'old installations do not keep their database'
    $order = 'Test-RuntimeFiles $script:BundledDbDir', 'Select-DbPort', 'Initialize-DotEnv', 'Initialize-BundledDb', 'mariadb-upgrade'
    $at = @($order | ForEach-Object { $t.IndexOf($_) })
    for ($i = 0; $i -lt $order.Count; $i++) { Assert-True ($at[$i] -ge 0) "$($order[$i]) not used" }
    for ($i = 1; $i -lt $order.Count; $i++) { Assert-True ($at[$i - 1] -lt $at[$i]) "$($order[$i - 1]) must come before $($order[$i])" }
    Assert-True ($t -match 'LeaveOldDatabase' -and $t -match 'Test-DbHasCompuLabData') 'a switch of database could leave data behind silently'
}
Test-Case 'a CompuLab service of another folder (names are global) is never ours: not stopped, started, replaced or removed' {
    # Read-only, with this PC's real services. Here $script:AppDir is the
    # repository folder: a service installed from C:\CompuLab is foreign.
    Assert-True ($null -eq (Get-OwnService 'NoSuchService-CompuLabTest')) 'a missing service counted as ours'
    $mysql = Get-CimInstance Win32_Service | Where-Object { $_.PathName -match '(?i)mysqld' } | Select-Object -First 1
    if ($mysql) { Assert-True ($null -eq (Get-OwnService $mysql.Name)) "$($mysql.Name) counted as CompuLab's" }
    $real = Get-CimInstance Win32_Service -Filter "Name = 'CompuLabMariaDB'"
    if ($real -and "$($real.PathName)".IndexOf($script:AppDir, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        Assert-True ($null -eq (Get-OwnService 'CompuLabMariaDB')) 'another folder''s CompuLabMariaDB counted as ours'
        Assert-True ((Get-ForeignServicePath 'CompuLabMariaDB') -match 'mariadbd') 'another folder''s service not reported'
    } else { Write-Host '         (no CompuLabMariaDB of another folder on this PC: foreign case checked with MySQL only)' -ForegroundColor DarkYellow }
    $i = Get-Content (Join-Path $Repo 'installer\server\install-server.ps1') -Raw
    Assert-True ($i -match 'Get-ForeignServicePath \$name' -and $i.IndexOf('Get-ForeignServicePath') -lt $i.IndexOf('Installing the Windows services')) 'a same-named service of another folder is not refused before changes'
    foreach ($f in Get-ChildItem (Join-Path $Repo 'installer\server') -Filter *.ps1 | Where-Object { $_.Name -ne 'server-status.ps1' }) {
        $n = 0
        foreach ($line in Get-Content $f.FullName) {
            $n++
            if ($line -match '^\s*#') { continue }
            if ($line -match 'Get-Service\s+(-Name\s+)?\$(script:)?(WebService|WorkerService|BundledDbService|id|name|_)\b' -and $line -notmatch 'function Get-OwnService|return Get-Service') {
                throw "$($f.Name):$n decides about a CompuLab service by its name only (use Get-OwnService): $($line.Trim())"
            }
        }
    }
}
Test-Case 'scripts stop or end only CompuLab''s own services and processes' {
    foreach ($f in Get-ChildItem (Join-Path $Repo 'installer\server') -Filter *.ps1) {
        $n = 0
        foreach ($line in Get-Content $f.FullName) {
            $n++
            if ($line -match '^\s*#') { continue }
            if ($line -match 'Stop-Service\s') { Assert-True ($line -match 'WebService|WorkerService|BundledDbService|\$name|\$id') "$($f.Name):$n stops another service: $($line.Trim())" }
            if ($line -match 'Stop-Process\s') { Assert-True ($line -match '\$p\.ProcessId') "$($f.Name):$n ends another process: $($line.Trim())" }
            if ($line -match "sc\.exe'?\s.*delete|'delete'") { Assert-True ($line -match 'BundledDbService|\$id') "$($f.Name):$n deletes another service" }
        }
    }
    $common = Get-Content (Join-Path $Repo 'installer\server\common.ps1') -Raw
    Assert-True ($common -match "function Get-BundledDbProcess[\s\S]{0,400}StartsWith\(\`$prefix") 'database processes are not limited to CompuLab''s runtime folder'
}
Test-Case 'setup: CompuLab (with its database) stopped before files are replaced; runtime replaced on update; data never deleted' {
    $iss = Get-Content (Join-Path $Repo 'installer\build\CompuLab-Server.iss') -Raw
    Assert-True ($iss -match 'stop-compulab\.ps1') 'PrepareToInstall does not stop CompuLab''s database'
    Assert-True ($iss -match 'Name: "\{app\}\\runtime\\python"' -and $iss -match 'Name: "\{app\}\\runtime\\mariadb"') 'old runtime files would linger'
    foreach ($keep in 'data', '.env', 'media', 'backups', 'logs') {
        Assert-True ($iss -notmatch "Type: filesandordirs; Name: `"\{app\}\\$([regex]::Escape($keep))`"") "the setup deletes {app}\$keep"
    }
    Assert-True ($iss -match "\{param:DBPORT\|3308\}") 'database port default is not 3308'
}
Test-Case 'build: pinned SHA-256 for MariaDB and Python; a download with another hash is refused and not kept (invalid checksum)' {
    $buildPath = Join-Path $Repo 'installer\build\build-installers.ps1'
    $text = Get-Content $buildPath -Raw
    Assert-True ($text -match "\`$MariaDbSha256 = '[0-9a-f]{64}'" -and $text -match "\`$PythonSha256 = '[0-9a-f]{64}'") 'hashes not pinned'
    $ast = [Management.Automation.Language.Parser]::ParseFile($buildPath, [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-VerifiedDownload' }, $true)
    $Downloads = Join-Path $Tmp 'downloads'
    function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) Set-Content -Path $OutFile -Value 'payload from the network' -NoNewline }
    . ([scriptblock]::Create($fn.Extent.Text))
    $good = (New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::ASCII.GetBytes('payload from the network'))
    $goodHex = -join ($good | ForEach-Object { $_.ToString('X2') })
    Assert-Throws { Get-VerifiedDownload 'https://example.invalid/x.zip' 'x.zip' ('0' * 64) } 'unexpected SHA-256'
    Assert-True (-not (Test-Path (Join-Path $Downloads 'x.zip')) -and -not (Test-Path (Join-Path $Downloads 'x.zip.part'))) 'a bad download was kept'
    $path = Get-VerifiedDownload 'https://example.invalid/x.zip' 'x.zip' $goodHex
    Assert-True (Test-Path $path) 'a good download was not kept'
    Set-Content $path 'corrupted later' -NoNewline
    Get-VerifiedDownload 'https://example.invalid/x.zip' 'x.zip' $goodHex | Out-Null
    Assert-Equal 'payload from the network' (Get-Content $path -Raw) 'a damaged cached file was used'
}
Test-Case 'build: payload rules accept the bundled runtime and still refuse data, settings and secrets in it' {
    $buildPath = Join-Path $Repo 'installer\build\build-installers.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($buildPath, [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Find-PayloadProblems' }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $root = Join-Path $Tmp 'payload-rules'
    foreach ($d in 'runtime\mariadb\share', 'runtime\python\Lib\site-packages\pkg\__pycache__', 'runtime\python\Lib\site-packages\pkg\tests') { New-Item -ItemType Directory -Force (Join-Path $root $d) | Out-Null }
    Set-Content (Join-Path $root 'runtime\mariadb\share\mariadb_system_tables.sql') 'CREATE TABLE x (a int);'
    Set-Content (Join-Path $root 'runtime\python\Lib\site-packages\pkg\tests\test_a.py') 'pass'
    $none = Find-PayloadProblems $root @()   # returns ,$problems: not wrapped in @() (Count would be 1)
    Assert-Equal 0 $none.Count "the runtime itself was refused: $($none -join '; ')"
    New-Item -ItemType Directory -Force (Join-Path $root 'data\mariadb') | Out-Null
    Set-Content (Join-Path $root 'runtime\mariadb\db-admin.cnf') 'password=x'
    Set-Content (Join-Path $root 'runtime\mariadb\dump.sql') 'INSERT ...'
    Set-Content (Join-Path $root 'runtime\python\notes.txt') 'the secret value Secret-4711-xyz'
    $p = Find-PayloadProblems $root @('Secret-4711-xyz')
    foreach ($want in 'folder data', 'db-admin\.cnf', 'dump\.sql', 'secret from this PC') { Assert-True (($p -match $want).Count -ge 1) "not refused: $want ($($p -join '; '))" }
}

Write-Host "`nAdministrator-only configuration, checked WITHOUT installing it" -ForegroundColor Cyan
Write-Host '  (These prove the definitions are what the installer asks Windows for, not that Windows accepted them on a real install.)' -ForegroundColor DarkGray
Test-Case 'service recovery (sc.exe failure): restart after 10 s, 30 s, 60 s; count resets after 1 hour' {
    $a = Get-ServiceRecoveryArgs 'CompuLabWeb'
    Assert-Equal 'failure|CompuLabWeb|reset=|3600|actions=|restart/10000/restart/30000/restart/60000' ($a -join '|')
    Assert-True (Test-Path "$env:SystemRoot\System32\sc.exe") 'sc.exe missing'
}
Test-Case 'WinSW definition values are ones WinSW 2.x accepts (start mode, delays, log mode)' {
    foreach ($d in Get-ServiceDefinitions 8000) {
        [xml]$x = New-WinSWXml $d 'MariaDB' 'C:\CompuLab\logs'
        Assert-True ($x.service.startmode -in @('Automatic', 'Manual', 'Boot', 'System', 'Disabled')) "startmode $($x.service.startmode)"
        Assert-Equal 'true' $x.service.delayedAutoStart
        foreach ($f in @($x.service.onfailure)) { Assert-True ($f.action -eq 'restart' -and $f.delay -match '^\d+ sec$') "onfailure $($f.action) $($f.delay)" }
        Assert-True ($x.service.resetfailure -match '^\d+ (hour|min|sec)$') "resetfailure $($x.service.resetfailure)"
        Assert-Equal 'roll-by-size' $x.service.log.mode
        Assert-True ($x.service.workingdirectory -and $x.service.logpath) 'working directory / log path missing'
    }
}
Test-Case 'WinSW-x64.exe loads a generated definition ("status" of a never-installed probe service)' {
    $winswExe = @((Join-Path $Repo 'installer\server\bin\WinSW-x64.exe'), (Join-Path $Repo 'installer\build\work\server-payload\installer\server\bin\WinSW-x64.exe')) |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $winswExe) { Write-Host '         (no WinSW-x64.exe here - run a build: not exercised)' -ForegroundColor DarkYellow; return }
    $probeDir = Join-Path $Tmp 'winsw'; New-Item -ItemType Directory -Force $probeDir | Out-Null
    $def = (Get-ServiceDefinitions 8000)[0]
    $def.Id = 'CompuLabTestProbe' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Copy-Item $winswExe (Join-Path $probeDir 'probe.exe')
    [IO.File]::WriteAllText((Join-Path $probeDir 'probe.xml'), (New-WinSWXml $def 'MariaDB' $probeDir), (New-Object Text.UTF8Encoding $false))
    $out = Invoke-Quiet (Join-Path $probeDir 'probe.exe') @('status')
    Assert-True ($LASTEXITCODE -eq 0 -and "$out" -match 'NonExistent') "WinSW said '$out' (exit $LASTEXITCODE)"
    Assert-True (-not (Get-Service $def.Id -ErrorAction SilentlyContinue)) 'a service was created'
}
Test-Case 'web firewall rule: web port only, campus/VPN ranges only, Private+Domain; New-NetFirewallRule -WhatIf accepts it' {
    $spec = Get-WebFirewallRuleSpec 8000 $script:DefaultAllowFrom
    Assert-Equal 'Inbound|TCP|8000|Allow' "$($spec.Direction)|$($spec.Protocol)|$($spec.LocalPort)|$($spec.Action)"
    Assert-Equal 'Private,Domain' ($spec.Profile -join ',')
    Assert-Equal ($script:DefaultAllowFrom -join ',') ($spec.RemoteAddress -join ',')
    Assert-True ($spec.RemoteAddress -notcontains 'Any' -and $spec.LocalPort -ne 3306) 'too open'
    $before = @(Get-NetFirewallRule -DisplayName $spec.DisplayName -ErrorAction SilentlyContinue).Count
    New-NetFirewallRule @spec -WhatIf 3>$null 6>$null | Out-Null
    Assert-Equal $before @(Get-NetFirewallRule -DisplayName $spec.DisplayName -ErrorAction SilentlyContinue).Count 'WhatIf created a rule'
    # The -WhatIf check is real: an invalid value is refused (prefixes like 'Privat' would bind).
    $broken = $spec.Clone(); $broken.Profile = 'Campus'
    Assert-Throws { New-NetFirewallRule @broken -WhatIf -ErrorAction Stop 6>$null | Out-Null } ''
}
Test-Case 'nightly backup task: daily 1:30 AM as SYSTEM, catches up a missed night, 2 h limit, writes a log' {
    $script = Join-Path $Repo 'installer\server\backup.ps1'
    $d = New-BackupTaskDefinition $script 'E:\CompuLab Backups'
    $task = New-ScheduledTask @d
    $t = $task.Triggers[0]
    Assert-Equal 'MSFT_TaskDailyTrigger' $t.CimClass.CimClassName
    # StartBoundary is stored in UTC (e.g. 17:30Z in UTC+8): 1:30 AM local time.
    $at = ([datetime]$t.StartBoundary).ToLocalTime().ToString('HH:mm')
    Assert-True ($at -eq '01:30' -and $t.DaysInterval -eq 1) "trigger at $at ($($t.StartBoundary)) every $($t.DaysInterval) day(s)"
    Assert-Equal 'SYSTEM|ServiceAccount|Highest' "$($task.Principal.UserId)|$($task.Principal.LogonType)|$($task.Principal.RunLevel)"
    Assert-True ($task.Settings.StartWhenAvailable) 'a missed night is not caught up'
    Assert-Equal 'PT2H' $task.Settings.ExecutionTimeLimit
    $a = $task.Actions[0]
    Assert-True (Test-Path $a.Execute) "program $($a.Execute) missing"
    Assert-True ($a.Arguments -match '-File "([^"]+)"' -and (Test-Path $Matches[1])) "script path in '$($a.Arguments)'"
    Assert-True ($a.Arguments -match '-BackupRoot "E:\\CompuLab Backups"' -and $a.Arguments -match ' -Log$') $a.Arguments
}
Test-Case 'Server Status shortcut: offers the UAC prompt for the full report, otherwise runs the labelled limited report' {
    $cmd = Get-Content (Join-Path $Repo 'installer\server\Server Status.cmd') -Raw
    Assert-True ($cmd -match 'net session' -and $cmd -match 'choice /c FL' -and $cmd -match "Start-Process -FilePath '%~f0' -Verb RunAs") 'no elevation choice'
    Assert-True ($cmd -match ':limited\s+powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server-status\.ps1"') 'limited path does not run the report'
    $iss = Get-Content (Join-Path $Repo 'installer\build\CompuLab-Server.iss') -Raw
    Assert-True ($iss -match 'CompuLab Server Status"; Filename: "\{app\}\\installer\\server\\Server Status\.cmd"') 'Start-menu shortcut target changed'
}
Test-Case 'server-status.ps1 without administrator rights: says LIMITED, skips admin-only checks, exits normally' {
    if (Test-IsAdmin) { Write-Host '         (running as administrator: limited mode not exercised)' -ForegroundColor DarkYellow; return }
    $copy = Join-Path $Tmp 'statusapp'
    New-Item -ItemType Directory -Force (Join-Path $copy 'installer') | Out-Null
    Copy-Item (Join-Path $Repo 'installer\server') (Join-Path $copy 'installer\server') -Recurse
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $copy 'installer\server\server-status.ps1') 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    Assert-True ($o -match 'LIMITED REPORT') 'not labelled limited'
    Assert-True ($o -match 'Firewall rule\s+needs administrator' -and $o -match 'Nightly backup task\s+needs administrator') $o
    Assert-True ($o -match 'Backup folder\s+.*statusapp\\backups \(from default\)') 'backup folder not shown'
}

Write-Host "`nAgent installer logic" -ForegroundColor Cyan
. (Join-Path $Repo 'installer\agent\agent-common.ps1')
$good = [pscustomobject]@{ secret = 'x' * 40; server_url = 'http://192.168.1.10:8000'; port = 5555 }
Test-Case 'a downloaded-style agent config is accepted' { Assert-Equal 0 (Get-AgentConfigProblems $good).Count }
Test-Case 'placeholder, published and short secrets are rejected' {
    foreach ($s in $script:RejectedSecrets + @('short')) {
        $c = $good.PSObject.Copy(); $c.secret = $s
        Assert-True ((Get-AgentConfigProblems $c).Count -ge 1) "accepted secret '$s'"
    }
}
Test-Case 'the sample agent config is rejected until a real secret is filled in' {
    $sample = Read-AgentConfig (Join-Path $Repo 'installer\agent\agent_config.local.sample.json')
    Assert-True ((Get-AgentConfigProblems $sample).Count -ge 1) 'sample accepted'
    $sample.secret = 'y' * 40
    Assert-Equal 0 (Get-AgentConfigProblems $sample).Count
}
Test-Case 'server address format' {
    Assert-Equal 'http://192.168.1.10:8000' (Test-ServerUrlFormat ' http://192.168.1.10:8000/ ')
    Assert-Equal 'https://compulab.example.ts.net' (Test-ServerUrlFormat 'https://compulab.example.ts.net')
    foreach ($bad in @('192.168.1.10:8000', 'http://192.168.1.10:8000/labs', 'http://bad host', 'ftp://x')) { Assert-Throws { Test-ServerUrlFormat $bad } 'not a server address' }
    $c = $good.PSObject.Copy(); $c.port = 99999; Assert-True ((Get-AgentConfigProblems $c).Count -ge 1) 'port 99999 accepted'
}
Test-Case 'packaged agent runs CompuLabAgent.exe, a folder copy runs pythonw agent.py' {
    $d = Join-Path $Tmp 'agentdir'; New-Item -ItemType Directory -Force $d | Out-Null
    $l = Get-AgentLaunch $d; Assert-True (-not $l.Packaged) 'python mode'; Assert-True ($l.Exe -like '*pythonw.exe') $l.Exe
    Set-Content (Join-Path $d 'CompuLabAgent.exe') 'x'
    $l = Get-AgentLaunch $d; Assert-True $l.Packaged 'packaged mode'; Assert-Equal '' $l.Args
}
Test-Case 'queued event count (regression: PowerShell 5.1 ConvertFrom-Json returns an array as one object)' {
    $d = Join-Path $Tmp 'queue'; New-Item -ItemType Directory -Force $d | Out-Null
    Assert-Equal 0 (Get-QueuedEventCount $d)
    '[{"path": "/a/", "body": {}}, {"path": "/b/", "body": {}}]' | Set-Content (Join-Path $d 'pending_callbacks.json')
    Assert-Equal 2 (Get-QueuedEventCount $d)
    '[]' | Set-Content (Join-Path $d 'pending_callbacks.json'); Assert-Equal 0 (Get-QueuedEventCount $d)
    '{broken' | Set-Content (Join-Path $d 'pending_callbacks.json'); Assert-Equal 0 (Get-QueuedEventCount $d)
}
Test-Case 'agent config writes keep the secret and other keys' {
    $f = Join-Path $Tmp 'agent.json'
    Write-AgentConfig $f ([pscustomobject]@{ secret = 'z' * 40; server_url = 'http://a:8000'; pc_name = 'PC 07' })
    Set-AgentServerUrl $f 'http://b:8000'
    $c = Read-AgentConfig $f
    Assert-Equal ('z' * 40) $c.secret; Assert-Equal 'http://b:8000' $c.server_url; Assert-Equal 'PC 07' $c.pc_name
}
Test-Case 'agent start-up task (not registered): sign-in of the given group, back within a minute, never stopped, one copy, standard rights' {
    $d = Join-Path $Tmp 'agentdir'   # holds a stand-in CompuLabAgent.exe (test above)
    $def = New-AgentTaskDefinition $d 'S-1-5-32-545'
    $task = New-ScheduledTask @def
    $t = $task.Triggers[0]
    Assert-Equal 'MSFT_TaskLogonTrigger' $t.CimClass.CimClassName
    Assert-Equal 'PT1M' $t.Repetition.Interval
    Assert-True ([string]::IsNullOrEmpty($t.Repetition.Duration)) "repetition ends after $($t.Repetition.Duration)"
    Assert-True (-not $t.Repetition.StopAtDurationEnd) 'repetition end would stop the agent'
    Assert-Equal 'IgnoreNew' $task.Settings.MultipleInstances
    Assert-Equal 'PT0S' $task.Settings.ExecutionTimeLimit
    Assert-True (-not $task.Settings.DisallowStartIfOnBatteries -and -not $task.Settings.StopIfGoingOnBatteries) 'battery rules stop the agent'
    $toSid = { param($id) if ("$id" -match '^S-1-') { "$id" } else { (New-Object Security.Principal.NTAccount($id)).Translate([Security.Principal.SecurityIdentifier]).Value } }
    $sid = & $toSid $task.Principal.GroupId
    Assert-Equal 'S-1-5-32-545|Limited' "$sid|$($task.Principal.RunLevel)"
    Assert-Equal (Join-Path $d 'CompuLabAgent.exe') $task.Actions[0].Execute
    Assert-Equal $d $task.Actions[0].WorkingDirectory
    # The student group case: the task targets exactly the group it is given
    # (an existing built-in group stands in for "CompuLab Students" here).
    $defGroup = New-AgentTaskDefinition $d 'S-1-5-32-555'
    $g = New-ScheduledTask @defGroup
    $gsid = & $toSid $g.Principal.GroupId
    Assert-Equal 'S-1-5-32-555|Limited|PT1M' "$gsid|$($g.Principal.RunLevel)|$($g.Triggers[0].Repetition.Interval)"
    Assert-True (-not $g.Triggers[0].UserId) 'trigger limited to one user'
}
Test-Case 'who gets the lock screen: students group by default, kept on repair/update, all users only on request' {
    $none = @{ Kind = 'None'; Account = '' }
    $r = Resolve-AgentScope -StudentAccounts @('') -Existing $none
    Assert-Equal 'StudentGroup|0' "$($r.Scope)|$(@($r.AddAccounts).Count)"
    $r = Resolve-AgentScope -StudentAccounts @('student1, LAB\student2;student1', '') -Existing $none
    Assert-Equal 'StudentGroup|student1,LAB\student2' "$($r.Scope)|$($r.AddAccounts -join ',')"
    # An update of an older install (task for every account) keeps that until told otherwise: no surprise unlocking or locking.
    $r = Resolve-AgentScope -StudentAccounts @() -Existing @{ Kind = 'AllUsers'; Account = '' }
    Assert-True ($r.Scope -eq 'AllUsers' -and $r.Reason -match 'administrators included') $r.Reason
    $r = Resolve-AgentScope -StudentAccounts @('student') -Existing @{ Kind = 'AllUsers'; Account = '' }
    Assert-Equal 'StudentGroup' $r.Scope
    $r = Resolve-AgentScope -StudentAccounts @() -Existing @{ Kind = 'StudentGroup'; Account = 'CompuLab Students' }
    Assert-True ($r.Scope -eq 'StudentGroup' -and $r.Reason -match 'kept') $r.Reason
    $r = Resolve-AgentScope -StudentAccounts @() -Existing @{ Kind = 'SingleUser'; Account = 'LAB\student' }
    Assert-Equal 'StudentGroup|LAB\student' "$($r.Scope)|$($r.AddAccounts -join ',')"
    $r = Resolve-AgentScope -AllUsers -StudentAccounts @('student') -Existing $none
    Assert-Equal 'AllUsers' $r.Scope
}
Test-Case 'student accounts must exist and must not be administrators' {
    $known = @('student', "$env:COMPUTERNAME\student2", 'LAB\student3', 'itadmin')
    $admins = @("$env:COMPUTERNAME\itadmin", 'Administrator')
    Assert-Equal 0 (Get-StudentAccountProblems @('student', 'student2', ".\student", 'LAB\student3') $known $admins).Count
    $p = Get-StudentAccountProblems @('itadmin', 'ghost') $known $admins
    Assert-True ($p.Count -eq 2 -and $p[0] -match 'administrator account' -and $p[1] -match 'does not exist') ($p -join ' | ')
    Assert-Equal 'a,b,c' ((ConvertTo-AccountList 'a, b;;c ,a') -join ',')
}
Test-Case 'agent installer: scope decided and checked before any change; uses the group SID for the task' {
    $text = Get-Content (Join-Path $Repo 'installer\agent\install-agent.ps1') -Raw
    $check = $text.IndexOf('Checking which Windows accounts get the lock screen'); $copy = $text.IndexOf('Installing the agent in')
    Assert-True ($check -gt 0 -and $check -lt $copy) 'accounts are checked after files were changed'
    Assert-True ($text -match 'Register-AgentTask \$InstallDir \$group\.Sid') 'task not bound to the students group'
    Assert-True ($text -match 'the lock screen would start for nobody') 'empty group not refused'
    $iss = Get-Content (Join-Path $Repo 'installer\build\CompuLab-Agent.iss') -Raw
    Assert-True ($iss -match '-StudentAccounts' -and $iss -match "\{param:STUDENTS\|\}") 'setup does not pass the student accounts'
    # Regression: the page's own check aborted every silent install ("Failed to proceed to next wizard page").
    Assert-True ($iss -match 'StudentsPage\.ID\)[^\r\n]*not WizardSilent\(\)') 'the student page check runs in silent installs'
}
Test-Case 'agent firewall rules: port 5555 and ping from the server only; New-NetFirewallRule -WhatIf accepts them' {
    $specs = Get-AgentFirewallRuleSpecs @('192.168.1.10') 5555
    Assert-Equal 2 $specs.Count
    Assert-Equal 'Inbound|TCP|5555|192.168.1.10' "$($specs[0].Direction)|$($specs[0].Protocol)|$($specs[0].LocalPort)|$($specs[0].RemoteAddress -join ',')"
    Assert-Equal 'ICMPv4|8|192.168.1.10' "$($specs[1].Protocol)|$($specs[1].IcmpType)|$($specs[1].RemoteAddress -join ',')"
    foreach ($s in $specs) { New-NetFirewallRule @s -WhatIf 6>$null | Out-Null }
}

Write-Host "`nScript files" -ForegroundColor Cyan
Test-Case 'every installer .ps1 is ASCII-only (Windows PowerShell 5.1 misreads UTF-8 without BOM)' {
    $bad = Get-ChildItem (Join-Path $Repo 'installer') -Recurse -Filter *.ps1 | Where-Object { [IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 } | Select-Object -First 1 }
    Assert-True (-not $bad) "non-ASCII: $($bad.Name -join ', ')"
}
Test-Case 'every installer .ps1 parses' {
    $errors = @()
    foreach ($f in Get-ChildItem (Join-Path $Repo 'installer') -Recurse -Filter *.ps1) {
        $t = $null; $e = $null
        [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e) | Out-Null
        if ($e) { $errors += "$($f.Name): $($e[0].Message)" }
    }
    Assert-True (-not $errors) ($errors -join '; ')
}
Test-Case 'installer scripts avoid the Windows PowerShell 5.1 pitfalls (quotes in python -c, stderr, Select -First)' {
    $scripts = Get-ChildItem (Join-Path $Repo 'installer\server'), (Join-Path $Repo 'installer\agent') -Filter *.ps1
    foreach ($f in $scripts) {
        $n = 0
        foreach ($line in Get-Content $f.FullName) {
            $n++
            if ($line -match "-c '[^']*print\(`"") { throw "$($f.Name):$n passes double-quoted Python code (PowerShell 5.1 drops the quotes)" }
            if ($line -match '^\s*[^#].*&\s*\$\S+.*2>(\$null|&1)' -and $line -notmatch '& \$Exe @Arguments 2>') {   # inside Invoke-Quiet / Invoke-Logged themselves
                throw "$($f.Name):$n redirects a program's stderr outside Invoke-Quiet (fatal under ErrorActionPreference Stop)"
            }
            if ($line -match '(Invoke-Quiet|Invoke-Logged)\b[^#]*\|\s*Select-Object\s+-First') {
                throw "$($f.Name):$n pipes a program into Select-Object -First (stops it early: exit code -1)"
            }
        }
    }
}
Test-Case '.cmd launchers use CRLF line endings and point to existing scripts' {
    $cmds = @(Get-ChildItem $Repo -Filter *.cmd) + @(Get-ChildItem (Join-Path $Repo 'installer') -Recurse -Filter *.cmd)
    Assert-True ($cmds.Count -ge 7) "only $($cmds.Count) launchers"
    foreach ($c in $cmds) {
        $text = [IO.File]::ReadAllText($c.FullName)
        Assert-True (($text -split "`n").Count -eq ($text -split "`r`n").Count) "$($c.Name) has LF-only lines"
        foreach ($m in [regex]::Matches($text, '%~dp0([^"]+\.ps1)')) {
            $target = Join-Path $c.DirectoryName $m.Groups[1].Value
            Assert-True (Test-Path $target) "$($c.Name) -> missing $($m.Groups[1].Value)"
        }
    }
}
Test-Case 'Inno Setup scripts call scripts that exist' {
    foreach ($iss in Get-ChildItem (Join-Path $Repo 'installer\build') -Filter *.iss) {
        $text = Get-Content $iss.FullName -Raw
        foreach ($m in [regex]::Matches($text, '\\(installer\\(server|agent)\\[A-Za-z\-]+\.ps1)')) {
            Assert-True (Test-Path (Join-Path $Repo $m.Groups[1].Value)) "$($iss.Name) -> missing $($m.Groups[1].Value)"
        }
    }
}
Test-Case 'the menu is called "PC power status" everywhere the operator is told where to click' {
    $files = @(Get-ChildItem (Join-Path $Repo 'installer') -Recurse -Include *.ps1, *.iss, *.cmd, *.md |
               Where-Object { $_.FullName -notmatch '\\installer\\(build\\(work|tools|\.venv)|dist|tests)\\' }) +
             @(Get-ChildItem (Join-Path $Repo 'docs') -Filter 'COMPULAB_*.md') +
             @(Get-Item (Join-Path $Repo 'docs\SCHOOL_DEPLOYMENT_GUIDE.md'), (Join-Path $Repo 'docs\MANUAL_VERIFICATION.md'), (Join-Path $Repo 'docs\RELEASE_READINESS.md'), (Join-Path $Repo 'README.md'))
    $arrow = [string][char]0x2192   # the arrow used in the Markdown guides (kept out of this ASCII-only file)
    $stale = @($files | Select-String -Pattern "\bPC status\s*(>|$arrow|->)" | ForEach-Object { "$($_.Filename):$($_.LineNumber)" })
    Assert-True (-not $stale.Count) "old menu path in: $($stale -join ', ')"
}

Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n$($script:passed) passed, $($script:failed.Count) failed" -ForegroundColor $(if ($script:failed.Count) { 'Red' } else { 'Green' })
exit [int]($script:failed.Count -gt 0)
