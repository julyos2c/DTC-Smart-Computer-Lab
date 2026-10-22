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
Test-Case 'agent start-up task (not registered): every sign-in, back within a minute, never stopped, one copy, standard rights' {
    $d = Join-Path $Tmp 'agentdir'   # holds a stand-in CompuLabAgent.exe (test above)
    $def = New-AgentTaskDefinition $d ''
    $task = New-ScheduledTask @def
    $t = $task.Triggers[0]
    Assert-Equal 'MSFT_TaskLogonTrigger' $t.CimClass.CimClassName
    Assert-Equal 'PT1M' $t.Repetition.Interval
    Assert-True ([string]::IsNullOrEmpty($t.Repetition.Duration)) "repetition ends after $($t.Repetition.Duration)"
    Assert-True (-not $t.Repetition.StopAtDurationEnd) 'repetition end would stop the agent'
    Assert-Equal 'IgnoreNew' $task.Settings.MultipleInstances
    Assert-Equal 'PT0S' $task.Settings.ExecutionTimeLimit
    Assert-True (-not $task.Settings.DisallowStartIfOnBatteries -and -not $task.Settings.StopIfGoingOnBatteries) 'battery rules stop the agent'
    $sid = (New-Object Security.Principal.NTAccount($task.Principal.GroupId)).Translate([Security.Principal.SecurityIdentifier]).Value
    Assert-Equal 'S-1-5-32-545|Limited' "$sid|$($task.Principal.RunLevel)"
    Assert-Equal (Join-Path $d 'CompuLabAgent.exe') $task.Actions[0].Execute
    Assert-Equal $d $task.Actions[0].WorkingDirectory
    $me = "$env:USERDOMAIN\$env:USERNAME"
    $defOne = New-AgentTaskDefinition $d $me
    $one = New-ScheduledTask @defOne
    Assert-Equal "$me|Interactive|Limited" "$($one.Principal.UserId)|$($one.Principal.LogonType)|$($one.Principal.RunLevel)"
    Assert-Equal 'PT1M' $one.Triggers[0].Repetition.Interval
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

Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n$($script:passed) passed, $($script:failed.Count) failed" -ForegroundColor $(if ($script:failed.Count) { 'Red' } else { 'Green' })
exit [int]($script:failed.Count -gt 0)
