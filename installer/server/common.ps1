# Shared helpers for the CompuLab server scripts. Dot-source it:
#   . "$PSScriptRoot\common.ps1"
# Works with Windows PowerShell 5.1 (built into Windows 10/11).
# The pure functions here (settings, .env, validation, service XML, the
# firewall / scheduled task / service recovery definitions) are covered by
# installer\tests\test-installer-logic.ps1.

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 may default to old TLS versions; https checks
# (e.g. the Tailscale https:// address) need TLS 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# The application folder is two levels above this script (installer\server\).
$script:AppDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:EnvFile = Join-Path $script:AppDir '.env'
$script:VenvPython = Join-Path $script:AppDir 'venv\Scripts\python.exe'
$script:ServiceDir = Join-Path $script:AppDir 'service'
$script:WebService = 'CompuLabWeb'
$script:WorkerService = 'CompuLabWorker'
$script:BackupTaskName = 'CompuLab nightly backup'
$script:DefaultBackupRoot = Join-Path $script:AppDir 'backups'
$script:DefaultAllowFrom = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10')

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "    OK: $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "    $Text" -ForegroundColor Yellow }

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-IsAdmin)) {
        throw 'Please run this script as Administrator (right-click PowerShell > Run as administrator, or use the .cmd launcher, which asks for it).'
    }
}

function Get-CurrentUserSid { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

function Invoke-Quiet([string]$Exe, [string[]]$Arguments, $InputText = $null) {
    # Runs a program and returns its standard output, ignoring its stderr.
    # (Windows PowerShell 5.1 turns a redirected stderr line into a fatal
    # error under ErrorActionPreference 'Stop'; pip, mysql, py and WinSW all
    # print harmless warnings there.) $LASTEXITCODE is set as usual.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($null -ne $InputText) { $InputText | & $Exe @Arguments 2>$null } else { & $Exe @Arguments 2>$null }
    } finally { $ErrorActionPreference = $previous }
}

function Invoke-Captured([string]$Exe, [string[]]$Arguments) {
    # Runs a program and returns everything it printed (stdout and stderr)
    # as text lines, without showing it. $LASTEXITCODE tells success.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $previous }
}

function Invoke-Logged([string]$Exe, [string[]]$Arguments) {
    # Runs a program and shows everything it prints (stdout and stderr) on the
    # screen and in the install log, so a failure explains itself. Returns
    # nothing; $LASTEXITCODE tells success.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host "      $_" } }
    finally { $ErrorActionPreference = $previous }
}

# Python code passed to `python -c` must not contain double quotes: Windows
# PowerShell 5.1 drops them when starting a program.
$script:PyVersionCode = 'import sys; print(*sys.version_info[:2], sep=chr(46))'
# One line "major.minor|bits|base folder", e.g. 3.13|64|C:\Program Files\Python313
$script:PyProbeCode = 'import sys; print(*sys.version_info[:2], sep=chr(46), end=chr(124)); print(64 if sys.maxsize > 2**32 else 32, sys.base_prefix, sep=chr(124))'

function New-RandomSecret([int]$Length = 50) {
    $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_'
    $bytes = New-Object byte[] $Length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# ---------------------------------------------------------------- install log
function Start-InstallLog([string]$Name) {
    # Everything shown on screen is also written to logs\<name>-<time>.log
    # (passwords are never shown, so they are never logged).
    $dir = Join-Path $script:AppDir 'logs'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Join-Path $dir ("$Name-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    try { Start-Transcript -Path $path -Force | Out-Null } catch { return $null }
    return $path
}

function Stop-InstallLog { try { Stop-Transcript | Out-Null } catch { } }

# ---------------------------------------------------------------- settings
$script:SettingKeys = @('ServerAddress', 'Port', 'RemoteUrl', 'DbName', 'DbUser', 'DbHost', 'DbPort', 'DbServiceName',
                        'BackupRoot', 'AllowFrom', 'AdminEmail')

function Read-InstallConfig([string]$Path) {
    # A JSON file with any of $SettingKeys (see server-install.sample.json).
    # Unknown keys are an error, so a typo is not silently ignored.
    if (-not (Test-Path $Path)) { throw "Configuration file not found: $Path" }
    try { $json = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw "Configuration file $Path is not valid JSON: $($_.Exception.Message)" }
    $values = @{}
    foreach ($prop in $json.PSObject.Properties) {
        if ($prop.Name -like '_*') { continue }   # "_comment" style keys
        if ($script:SettingKeys -notcontains $prop.Name) {
            throw "Unknown setting '$($prop.Name)' in $Path. Allowed: $($script:SettingKeys -join ', ')"
        }
        $values[$prop.Name] = $prop.Value
    }
    return $values
}

function Merge-InstallSettings([hashtable]$Defaults, [hashtable]$FromFile, [hashtable]$Explicit) {
    # Precedence: values given on the command line > config file > defaults.
    $merged = @{}
    foreach ($k in $Defaults.Keys) { $merged[$k] = $Defaults[$k] }
    foreach ($source in @($FromFile, $Explicit)) {
        if (-not $source) { continue }
        foreach ($k in $source.Keys) { if ($null -ne $source[$k] -and "$($source[$k])" -ne '') { $merged[$k] = $source[$k] } }
    }
    return $merged
}

function Test-CidrOrAddress([string]$Value) {
    if ($Value -in @('LocalSubnet', 'Any')) { return $true }
    $parts = $Value.Split('/')
    if ($parts.Count -gt 2) { return $false }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($parts[0], [ref]$ip)) { return $false }
    if ($parts.Count -eq 2) { $bits = 0; return ([int]::TryParse($parts[1], [ref]$bits) -and $bits -ge 0 -and $bits -le 32) }
    return $true
}

function Test-InstallSettings([hashtable]$S) {
    # Returns a list of problems (empty = valid). Database and user names go
    # into SQL statements, so only plain names are accepted.
    $problems = @()
    $port = 0
    if (-not [int]::TryParse("$($S.Port)", [ref]$port) -or $port -lt 1 -or $port -gt 65535) { $problems += "Port must be 1-65535 (got '$($S.Port)')." }
    if ($S.ServerAddress -and "$($S.ServerAddress)" -notmatch '^[A-Za-z0-9]([A-Za-z0-9.\-]{0,251}[A-Za-z0-9])?$') {
        $problems += "ServerAddress '$($S.ServerAddress)' is not an IP address or computer name (no http://, no port)."
    }
    if ($S.RemoteUrl -and "$($S.RemoteUrl)" -notmatch '^https?://[A-Za-z0-9.\-]+(:\d+)?/?$') {
        $problems += "RemoteUrl '$($S.RemoteUrl)' must look like https://name.tailnet.ts.net or http://100.x.y.z:8000."
    }
    foreach ($k in 'DbName', 'DbUser') {
        if ("$($S[$k])" -notmatch '^[A-Za-z0-9_]{1,64}$') { $problems += "$k may only contain letters, digits and _ (got '$($S[$k])')." }
    }
    $dbPort = 0
    if (-not [int]::TryParse("$($S.DbPort)", [ref]$dbPort) -or $dbPort -lt 1 -or $dbPort -gt 65535) { $problems += "DbPort must be 1-65535 (got '$($S.DbPort)')." }
    foreach ($a in @($S.AllowFrom)) {
        if ($a -eq 'Any') { $problems += 'AllowFrom "Any" would open CompuLab to every network: list campus ranges instead.' }
        elseif (-not (Test-CidrOrAddress "$a")) { $problems += "AllowFrom entry '$a' is not an address or range like 192.168.0.0/16." }
    }
    if ($S.AdminEmail -and (Test-AdminEmail $S.AdminEmail)) { $problems += "AdminEmail: $(Test-AdminEmail $S.AdminEmail)" }
    if ($S.BackupRoot -and (Test-BackupRootFormat "$($S.BackupRoot)")) { $problems += "BackupRoot: $(Test-BackupRootFormat "$($S.BackupRoot)")" }
    return ,$problems
}

# ---------------------------------------------------------------- .env
function Read-DotEnv {
    $values = @{}
    if (Test-Path $script:EnvFile) {
        foreach ($line in Get-Content $script:EnvFile -Encoding UTF8) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
                $values[$Matches[1]] = $Matches[2].Trim()
            }
        }
    }
    return $values
}

function Set-DotEnvValue([string]$Key, [string]$Value) {
    $lines = @()
    if (Test-Path $script:EnvFile) { $lines = @(Get-Content $script:EnvFile -Encoding UTF8) }
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $lines[$i] = "$Key=$Value"
            $found = $true
        }
    }
    if (-not $found) { $lines += "$Key=$Value" }
    # UTF-8 without BOM so python-dotenv reads the first key correctly.
    [IO.File]::WriteAllLines($script:EnvFile, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
}

function Protect-EnvFile {
    # Only Administrators, SYSTEM (the services) and the account that ran the
    # installer (an administrator) may read .env: it holds passwords.
    & icacls $script:EnvFile /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' "*$(Get-CurrentUserSid):F" | Out-Null
}

function New-DotEnvSettings([hashtable]$S, [string[]]$LanAddresses, [string]$ComputerName) {
    # The complete first-run .env, with fresh random secrets.
    $hosts = @('127.0.0.1', 'localhost', $ComputerName.ToLower(), $S.ServerAddress) + $LanAddresses | Where-Object { $_ } | Select-Object -Unique
    $origins = $hosts | ForEach-Object { "http://$($_):$($S.Port)" }
    return [ordered]@{
        'DJANGO_DEBUG' = 'False'
        'DJANGO_SECRET_KEY' = (New-RandomSecret 60)
        'DJANGO_ALLOWED_HOSTS' = ($hosts -join ',')
        'DJANGO_CSRF_TRUSTED_ORIGINS' = ($origins -join ',')
        'DJANGO_SECURE_SSL' = 'False'
        'SITE_URL' = "http://$($S.ServerAddress):$($S.Port)"
        'COMPULAB_PORT' = "$($S.Port)"
        'COMPULAB_REMOTE_URL' = "$($S.RemoteUrl)".TrimEnd('/')
        'DB_NAME' = $S.DbName
        'DB_USER' = $S.DbUser
        'DB_PASSWORD' = (New-RandomSecret 32)
        'DB_HOST' = $S.DbHost
        'DB_PORT' = "$($S.DbPort)"
        'PC_AGENT_SHARED_SECRET' = (New-RandomSecret 40)
        # The CompuLab Worker service runs the background work; the website must not.
        'COMPULAB_BACKGROUND_TASKS' = 'False'
        'DJANGO_SERVE_MEDIA' = 'True'
        # Email is optional (configure-email.ps1); until then emails go to the log.
        'EMAIL_HOST_USER' = ''
        'EMAIL_HOST_PASSWORD' = ''
        # Cloud sync is optional and needs a receiver (cloud_sync\PROTOCOL.md).
        'CLOUD_SERVER_URL' = ''
        'CLOUD_SYNC_API_KEY' = ''
    }
}

function Initialize-DotEnv([hashtable]$S, [string[]]$LanAddresses, [switch]$WorkerService) {
    # First run: write a complete .env. Later runs (repair / update): keep
    # every existing value, above all the secrets and the database password,
    # and only add keys that are missing. Returns $true on the first run.
    $firstRun = -not (Test-Path $script:EnvFile)
    $fresh = New-DotEnvSettings $S $LanAddresses $env:COMPUTERNAME
    if ($firstRun) {
        foreach ($key in $fresh.Keys) { Set-DotEnvValue $key $fresh[$key] }
    } else {
        $existing = Read-DotEnv
        foreach ($key in 'COMPULAB_PORT', 'COMPULAB_REMOTE_URL', 'CLOUD_SERVER_URL', 'CLOUD_SYNC_API_KEY') {
            if (-not $existing.ContainsKey($key)) { Set-DotEnvValue $key $fresh[$key] }
        }
        if ($WorkerService -and $existing['COMPULAB_BACKGROUND_TASKS'] -ne 'False') { Set-DotEnvValue 'COMPULAB_BACKGROUND_TASKS' 'False' }
    }
    Protect-EnvFile
    return $firstRun
}

# ---------------------------------------------------------------- backup location
function Get-BackupRootFromTaskArguments([string]$Arguments) {
    # The -BackupRoot of the nightly task's command line, or $null.
    if ($Arguments -match '-BackupRoot\s+"([^"]+)"') { return $Matches[1] }
    if ($Arguments -match '-BackupRoot\s+([^\s"]+)') { return $Matches[1] }
    return $null
}

function Get-ConfiguredBackupRoot {
    # Where backups go, as @{ Path; Source }: COMPULAB_BACKUP_ROOT in .env
    # (written by install-server.ps1), else - for installations from before
    # it was recorded - the nightly task's -BackupRoot, else C:\CompuLab\backups.
    # Repair, Update, "Back Up CompuLab Now" and restore all use this, so a
    # custom location is never silently replaced by the default.
    try { $values = Read-DotEnv } catch { $values = @{} }
    if ($values['COMPULAB_BACKUP_ROOT']) { return @{ Path = $values['COMPULAB_BACKUP_ROOT']; Source = '.env (COMPULAB_BACKUP_ROOT)' } }
    try {
        $task = Get-ScheduledTask -TaskName $script:BackupTaskName -ErrorAction Stop
        $fromTask = Get-BackupRootFromTaskArguments ([string]$task.Actions[0].Arguments)
        if ($fromTask) { return @{ Path = $fromTask; Source = 'the nightly backup task' } }
    } catch { }
    return @{ Path = $script:DefaultBackupRoot; Source = 'default' }
}

function Test-BackupRootFormat([string]$Path) {
    # $null if the path has a usable form (drive letter or \\server\share),
    # else why not. Pure; Test-BackupRoot also checks that it is writable.
    if (-not $Path) { return 'No backup folder given.' }
    if ($Path -notmatch '^[A-Za-z]:\\' -and $Path -notmatch '^\\\\[^\\]+\\[^\\]+') {
        return "Backup folder '$Path' must be a full path such as E:\CompuLabBackups or \\server\share\CompuLab."
    }
    if ($Path.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or $Path.Substring(2) -match '[<>:"|?*]') {
        return "Backup folder '$Path' contains characters Windows does not allow."
    }
    return $null
}

function Test-BackupRoot([string]$Path) {
    # $null if backups can be written to $Path (creates the folder if needed).
    $problem = Test-BackupRootFormat $Path
    if ($problem) { return $problem }
    if ($Path -match '^([A-Za-z]:)\\' -and -not (Test-Path ($Matches[1] + '\'))) {
        return "Drive $($Matches[1]) for the backup folder '$Path' does not exist (USB drive unplugged?)."
    }
    try {
        New-Item -ItemType Directory -Force -Path $Path -ErrorAction Stop | Out-Null
        $probe = Join-Path $Path ('.compulab-write-test-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force
    } catch {
        return "Cannot write to the backup folder '$Path': $($_.Exception.Message)"
    }
    return $null
}

# ---------------------------------------------------------------- network
function Get-LanAddresses {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
        Select-Object -ExpandProperty IPAddress
}

function Get-PortOwner([int]$Port) {
    # Name of the program listening on this TCP port, or $null if it is free.
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) { return $null }
    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    if ($proc) { return $proc.ProcessName }
    return "process $($conn.OwningProcess)"
}

function Get-ResponseText($Response) {
    # Invoke-WebRequest gives bytes instead of text when the server sends no
    # Content-Type (e.g. some proxies).
    if ($Response.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($Response.Content) }
    return [string]$Response.Content
}

function Wait-Healthy([string]$Url = 'http://127.0.0.1:8000/healthz', [int]$Seconds = 60) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            # Bytes instead of text when a proxy sends no Content-Type.
            $text = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
            if ($r.StatusCode -eq 200 -and $text.Trim() -eq 'ok') { return $true }
        } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ---------------------------------------------------------------- Python
function ConvertFrom-PythonProbe([string]$Text) {
    # Parses the output of $PyProbeCode: @{ Version; Bits; BasePrefix } or $null.
    if ("$Text".Trim() -notmatch '^(\d+\.\d+)\|(32|64)\|(.+)$') { return $null }
    return @{ Version = $Matches[1]; Bits = [int]$Matches[2]; BasePrefix = $Matches[3].Trim() }
}

function Test-PythonSupported([hashtable]$Probe) {
    # $null when this Python can run the server, else the reason it can't.
    # 64-bit 3.11-3.13 only: the bundled packages are built for those
    # (win_amd64), and production runs 3.13.
    if (-not $Probe) { return 'not a working Python' }
    if ([version]$Probe.Version -lt [version]'3.11' -or [version]$Probe.Version -ge [version]'3.14') { return "Python $($Probe.Version) is not supported (needs 3.11-3.13; 3.13 recommended)" }
    if ($Probe.Bits -ne 64) { return "Python $($Probe.Version) is the 32-bit version (needs the 64-bit Windows installer)" }
    return $null
}

function Test-PythonForAllUsers([string]$BasePrefix) {
    # A Python installed "just for me" lives in that user's profile; the
    # CompuLab services (LocalSystem) then depend on that one account.
    return -not ($BasePrefix -like "$env:SystemDrive\Users\*" -or ($env:USERPROFILE -and $BasePrefix -like "$env:USERPROFILE\*"))
}

function Find-Python {
    # The first 64-bit Python 3.11-3.13 found (3.13 first: production runs
    # it), as @{ Command (program + arguments); Version; BasePrefix }.
    # $null if none; $script:PythonRejected then says what was found instead.
    $script:PythonRejected = @()
    foreach ($candidate in @('py -3.13-64', 'py -3.13', 'py -3.12-64', 'py -3.12', 'py -3.11-64', 'py -3.11', 'python')) {
        $parts = $candidate.Split(' ')
        try {
            # Collect the output first: Select-Object -First in the same
            # pipeline would stop python early and leave $LASTEXITCODE at -1.
            $out = @(Invoke-Quiet $parts[0] (@($parts | Select-Object -Skip 1) + @('-c', $script:PyProbeCode)))
            if ($LASTEXITCODE -ne 0 -or -not $out.Count) { continue }
            $probe = ConvertFrom-PythonProbe ([string]$out[0])
            if (-not $probe) { continue }
            $why = Test-PythonSupported $probe
            if (-not $why) { return @{ Command = $parts; Version = $probe.Version; BasePrefix = $probe.BasePrefix } }
            if ($script:PythonRejected -notcontains $why) { $script:PythonRejected += $why }
        } catch { }
    }
    return $null
}

function Install-PythonPackages([string]$Requirements) {
    # Offline first: the CompuLab-Server-Setup.exe ships the packages in
    # installer\server\wheels; a plain copy of the folder downloads them.
    $wheels = Join-Path $PSScriptRoot 'wheels'
    Invoke-Quiet $script:VenvPython @('-m', 'pip', 'install', '--upgrade', 'pip', '--disable-pip-version-check', '--quiet') | Out-Null
    if (Test-Path $wheels) {
        # --no-warn-script-location: pip's check whether the venv is on PATH can
        # fail on PATH folders that are junctions (WinError 448 under setup
        # programs that enable Windows' redirection protection); not needed.
        Invoke-Logged $script:VenvPython @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-warn-script-location', '--no-index', '--find-links', $wheels, '-r', $Requirements)
        if ($LASTEXITCODE -eq 0) { return 'offline package folder' }
        Write-Note 'The bundled packages could not be installed (see above); downloading them instead.'
    }
    Invoke-Logged $script:VenvPython @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-warn-script-location', '-r', $Requirements)
    if ($LASTEXITCODE -ne 0) {
        throw 'Installing packages failed. This step needs internet access (or the offline package folder of CompuLab-Server-Setup.exe).'
    }
    return 'internet'
}

# ---------------------------------------------------------------- database tools
function Find-MySqlTool([string]$Name) {
    # Name: mysql.exe, mysqldump.exe, mariadb.exe, mariadb-dump.exe
    # A real MariaDB / MySQL installation first (its client matches the
    # server), then PATH, and XAMPP's old MariaDB 10.4 client only last: it
    # cannot sign in to a MySQL 8 server.
    foreach ($root in @("$env:ProgramFiles\MariaDB*\bin", "$env:ProgramFiles\MySQL\MySQL Server*\bin")) {
        # The file name goes in the path: with a wildcard folder, -Filter
        # would match the folders themselves in Windows PowerShell 5.1.
        $hit = Get-ChildItem -Path (Join-Path $root $Name) -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*\xampp\*' } | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $xampp = Join-Path 'C:\xampp\mysql\bin' $Name
    if (Test-Path $xampp) { return $xampp }
    return $null
}

function New-MySqlDefaultsFile([string]$User, [string]$Password, [string]$DbHost = '127.0.0.1', [string]$Port = '3306') {
    # Credentials go in a temporary options file (not on the command line,
    # where other processes could read them). Caller deletes it.
    $path = Join-Path $env:TEMP ("compulab-db-" + [guid]::NewGuid().ToString('N') + '.cnf')
    $content = "[client]`nuser=$User`npassword=$Password`nhost=$DbHost`nport=$Port`n"
    [IO.File]::WriteAllText($path, $content, (New-Object Text.UTF8Encoding $false))
    & icacls $path /inheritance:r /grant:r "*$(Get-CurrentUserSid):F" 'SYSTEM:F' | Out-Null
    return $path
}

function Get-DbServerVersion([string]$MySqlExe, [string]$DefaultsFile) {
    # Returns e.g. '10.11.6-MariaDB' or '8.4.3', or $null if it can't connect.
    $out = Invoke-Quiet $MySqlExe @("--defaults-extra-file=$DefaultsFile", '--batch', '--skip-column-names') 'SELECT VERSION();'
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    return ([string]($out | Select-Object -First 1)).Trim()
}

function Assert-SupportedDbVersion([string]$VersionText) {
    # Django 5.2 (requirements-production.txt) supports MariaDB 10.5+ and MySQL 8.0.11+.
    if ($VersionText -notmatch '^(\d+)\.(\d+)\.(\d+)') { throw "Could not read the database server version ('$VersionText')." }
    $v = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
    if ($VersionText -match 'MariaDB') {
        if ($v -lt [version]'10.5.0') {
            throw "MariaDB $v is too old for this version of CompuLab (needs 10.5 or newer; 10.11 or 11.4 LTS recommended). XAMPP ships MariaDB 10.4: install MariaDB from mariadb.org instead."
        }
        return "MariaDB $v"
    }
    if ($v -lt [version]'8.0.11') { throw "MySQL $v is too old for this version of CompuLab (needs 8.0.11 or newer)." }
    return "MySQL $v"
}

function Get-DbSetupSql([string]$DbName, [string]$DbUser, [string]$DbPassword) {
    # Idempotent: safe to run on every install / repair. Also resets the
    # application user's password to the one in .env, which repairs a
    # database user whose password no longer matches.
    if ($DbName -notmatch '^[A-Za-z0-9_]{1,64}$' -or $DbUser -notmatch '^[A-Za-z0-9_]{1,64}$') { throw 'Invalid database or user name.' }
    $pw = $DbPassword.Replace('\', '\\').Replace("'", "''")
    return @"
CREATE DATABASE IF NOT EXISTS ``$DbName`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DbUser'@'localhost' IDENTIFIED BY '$pw';
CREATE USER IF NOT EXISTS '$DbUser'@'127.0.0.1' IDENTIFIED BY '$pw';
ALTER USER '$DbUser'@'localhost' IDENTIFIED BY '$pw';
ALTER USER '$DbUser'@'127.0.0.1' IDENTIFIED BY '$pw';
GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'localhost';
GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'127.0.0.1';
FLUSH PRIVILEGES;
"@
}

function Select-DbService($Services, [string]$PortOwner = '') {
    # Picks the database service CompuLab depends on from objects with Name,
    # State ('Running'...) and PathName (as Win32_Service has them).
    # XAMPP's MariaDB 10.4 is never chosen (too old, not meant as a service).
    # The service that owns the database port ($PortOwner) wins; otherwise
    # with several candidates the single running one, otherwise the
    # installer asks for -DbServiceName instead of guessing.
    $candidates = @($Services | Where-Object { $_.Name -match '^(MariaDB|MySQL)' -and "$($_.PathName)" -notmatch '\\xampp\\' })
    if ($candidates.Count -eq 0) { return $null }
    if ($PortOwner -and @($candidates | Where-Object { $_.Name -eq $PortOwner }).Count) { return $PortOwner }
    if ($candidates.Count -eq 1) { return $candidates[0].Name }
    $running = @($candidates | Where-Object { $_.State -eq 'Running' })
    if ($running.Count -eq 1) { return $running[0].Name }
    throw ("Several database services are installed ($(($candidates | ForEach-Object { $_.Name }) -join ', ')). " +
           'Run the installer again with -DbServiceName <the one CompuLab should use> (or "none").')
}

function Get-DbServiceName([string]$PortOwner = '') {
    # The Windows service name of the local database server, if any.
    return Select-DbService @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Select-Object Name, State, PathName) $PortOwner
}

function Get-ListenerInfo([int]$Port) {
    # What listens on this TCP port: @{ ProcessId; ProcessPath; ServiceName }, or $null.
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) { return $null }
    $procId = [int]$conn.OwningProcess
    $svc = Get-CimInstance Win32_Service -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue | Select-Object -First 1
    $path = ''
    try { $path = [string](Get-Process -Id $procId -ErrorAction Stop).Path } catch { }
    if (-not $path -and $svc) { $path = [string]$svc.PathName }
    return @{ ProcessId = $procId; ProcessPath = $path; ServiceName = $(if ($svc) { [string]$svc.Name } else { '' }) }
}

function Test-DbListener($Listener, [string]$DbHost, [int]$Port) {
    # $null if CompuLab may use the database server listening on $Port of
    # this computer, else what is wrong and what to do. Pure (tested).
    # CompuLab never stops, changes or replaces another database: it refuses.
    if ($DbHost -notin @('127.0.0.1', 'localhost')) { return $null }   # a database on another computer: not checked here
    if (-not $Listener) {
        return ("No database server is listening on port $Port of this computer. Start the MariaDB/MySQL service (Services app), " +
                'or install MariaDB 11.4 LTS (it uses port 3306 unless you choose another). If your database uses another port, ' +
                'give it with -DbPort <port> (setup: the "Database port" field).')
    }
    $path = "$($Listener.ProcessPath)"
    if ($path -match '\\xampp\\') {
        return ("Port $Port is used by XAMPP's database ($path). CompuLab does not use, stop or change XAMPP. " +
                'Install MariaDB 11.4 LTS on another port (for example 3307: choose it in the MariaDB setup) and enter that port ' +
                'as the "Database port" in the setup (or -DbPort 3307), or use a server computer without XAMPP.')
    }
    if ($path -and $path -notmatch '(?i)(mysqld|mariadbd)(\.exe)?\b') {
        return "Port $Port is used by '$path', which is not a MariaDB/MySQL server. Free that port, or give the database's real port with -DbPort."
    }
    return $null
}

function Wait-DbListener([int]$Port, [int]$Seconds = 20) {
    # A just-started database service needs a few seconds to open its port.
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $l = Get-ListenerInfo $Port
        if ($l) { return $l }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    return $null
}

# ---------------------------------------------------------------- addresses
function Get-SitePort {
    # The port the CompuLab Web service listens on (COMPULAB_PORT, written by
    # install-server.ps1), else the one in SITE_URL, else 8000.
    $values = Read-DotEnv
    if ($values['COMPULAB_PORT'] -match '^\d+$') { return [int]$values['COMPULAB_PORT'] }
    $site = $values['SITE_URL']
    if ($site -match '^https?://[^/:]+:(\d+)') { return [int]$Matches[1] }
    if ($site -match '^https://') { return 443 }
    if ($site -match '^http://') { return 80 }
    return 8000
}

function Find-Tailscale {
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:ProgramFiles\Tailscale\tailscale.exe", "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

function Get-TailscaleSelf([string]$TailscaleExe) {
    # Returns @{ State; DnsName; IPv4 } from `tailscale status --json`, or $null.
    $json = Invoke-Quiet $TailscaleExe @('status', '--json')
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    try { $s = ($json -join "`n") | ConvertFrom-Json } catch { return $null }
    $ipv4 = @($s.Self.TailscaleIPs | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) | Select-Object -First 1
    return @{ State = $s.BackendState; DnsName = ([string]$s.Self.DNSName).TrimEnd('.'); IPv4 = $ipv4 }
}

# ---------------------------------------------------------------- services
function Get-WinSWExe {
    $exe = Get-ChildItem -Path (Join-Path $PSScriptRoot 'bin') -Filter 'WinSW*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { return $exe.FullName }
    return $null
}

function Test-WinSWExe([string]$Path) {
    # A real WinSW executable is a ~10-20 MB .NET program whose file
    # description mentions the service wrapper. Unblock it (downloaded files
    # are marked as coming from the internet).
    $item = Get-Item $Path
    if ($item.Length -lt 100KB) { throw "$Path is only $($item.Length) bytes: the download is incomplete or is a web page. Download WinSW-x64.exe again from github.com/winsw/winsw/releases." }
    Unblock-File -Path $Path -ErrorAction SilentlyContinue
    $info = $item.VersionInfo
    $label = (@($info.FileDescription, $info.ProductName) | Where-Object { $_ }) -join ' / '
    if ($label -notmatch 'WinSW|Service Wrapper') { Write-Note "Could not confirm $Path is WinSW (file says: '$label'). Continuing." }
    return "$label $($info.ProductVersion)".Trim()
}

function Get-ServiceDefinitions([int]$Port) {
    $waitress = Join-Path $script:AppDir 'venv\Scripts\waitress-serve.exe'
    return @(
        # 0.0.0.0: reachable on the campus LAN and, if configured, the
        # Tailscale address; the firewall rule limits who may connect.
        @{ Id = $script:WebService; Name = 'CompuLab Web'; Exe = $waitress;
           Args = "--listen=0.0.0.0:$Port --threads=8 compulab.wsgi:application";
           Desc = "CompuLab website (waitress). Serves the campus network on port $Port.";
           Env = [ordered]@{ 'COMPULAB_BACKGROUND_TASKS' = 'False' } },
        @{ Id = $script:WorkerService; Name = 'CompuLab Worker'; Exe = $script:VenvPython;
           Args = 'manage.py run_worker';
           Desc = 'CompuLab background work: lab PC online/offline checks, email outbox, cloud sync, reminders, durable jobs.';
           Env = [ordered]@{ 'COMPULAB_BACKGROUND_TASKS' = 'False'; 'DJANGO_LOG_FILE_NAME' = 'worker.log' } }
    )
}

function New-WinSWXml([hashtable]$Definition, [string]$DependsOn, [string]$LogDir) {
    # WinSW 2.x service definition: starts at boot (delayed, after the
    # database service), restarts itself after a crash, rolls its own logs.
    $esc = { param($v) [Security.SecurityElement]::Escape([string]$v) }
    $envXml = ($Definition.Env.GetEnumerator() | ForEach-Object { "  <env name=`"$(& $esc $_.Key)`" value=`"$(& $esc $_.Value)`"/>" }) -join "`n"
    $dependXml = if ($DependsOn) { "  <depend>$(& $esc $DependsOn)</depend>`n" } else { '' }
    return @"
<service>
  <id>$(& $esc $Definition.Id)</id>
  <name>$(& $esc $Definition.Name)</name>
  <description>$(& $esc $Definition.Desc)</description>
  <executable>$(& $esc $Definition.Exe)</executable>
  <arguments>$(& $esc $Definition.Args)</arguments>
  <workingdirectory>$(& $esc $script:AppDir)</workingdirectory>
$envXml
  <startmode>Automatic</startmode>
  <delayedAutoStart>true</delayedAutoStart>
$dependXml  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="restart" delay="60 sec"/>
  <resetfailure>1 hour</resetfailure>
  <logpath>$(& $esc $LogDir)</logpath>
  <log mode="roll-by-size"><sizeThreshold>5120</sizeThreshold><keepFiles>5</keepFiles></log>
</service>
"@
}

function Get-ServiceRecoveryArgs([string]$ServiceId) {
    # sc.exe arguments for Windows' own recovery settings (a second safety net
    # behind WinSW's <onfailure>): restart after 10 s, 30 s, then every 60 s;
    # the failure count resets after an hour without failures.
    return @('failure', $ServiceId, 'reset=', '3600', 'actions=', 'restart/10000/restart/30000/restart/60000')
}

function Get-WebFirewallRuleSpec([int]$Port, [string[]]$AllowFrom) {
    # Parameters for New-NetFirewallRule: the web port only, only from the
    # campus / VPN ranges, only on Private and Domain networks.
    return @{ DisplayName = 'CompuLab Web'; Direction = 'Inbound'; Protocol = 'TCP'; LocalPort = $Port
              RemoteAddress = $AllowFrom; Action = 'Allow'; Profile = @('Private', 'Domain') }
}

function New-BackupTaskDefinition([string]$BackupScript, [string]$BackupRoot) {
    # The parts of the "CompuLab nightly backup" task, without registering it:
    # 1:30 AM as SYSTEM, or as soon as possible after a missed run (server
    # off); stopped if it hangs for more than 2 hours; each run writes
    # logs\backup-<time>.log (backup.ps1 -Log).
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$BackupScript`" -BackupRoot `"$BackupRoot`" -Log"
    $trigger = New-ScheduledTaskTrigger -Daily -At '1:30AM'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    return @{ Action = $action; Trigger = $trigger; Principal = $principal; Settings = $taskSettings }
}

function Stop-CompuLabServices {
    foreach ($name in $script:WorkerService, $script:WebService) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Stopped') { Stop-Service -Name $name -Force; Write-Ok "Stopped $name" }
    }
}

function Start-CompuLabServices {
    foreach ($name in $script:WebService, $script:WorkerService) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) { Start-Service -Name $name; Write-Ok "Started $name" }
        else { Write-Note "Service $name is not installed (run install-server.ps1)." }
    }
}

# ---------------------------------------------------------------- first Administrator
function Test-AdminEmail([string]$Email) {
    # $null if usable as the Administrator's sign-in, else why not. CompuLab
    # accepts only @gmail.com addresses for every account
    # (accounts/email_rules.py, an application rule); ensure_admin checks again.
    $Email = "$Email".Trim()
    if (-not $Email) { return 'Enter the email address the Administrator will sign in with.' }
    if ($Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { return "'$Email' is not an email address." }
    if ($Email -notmatch '^[^@\s]+@gmail\.com$') { return "'$Email' is not a @gmail.com address. CompuLab accepts only Gmail addresses for every account." }
    return $null
}

function ConvertFrom-EnsureAdminOutput([string[]]$Lines, [int]$ExitCode) {
    # The RESULT line of `manage.py ensure_admin` as @{ ExitCode; Code; Message }.
    $line = @($Lines | Where-Object { "$_" -match '^RESULT: [A-Z_]+: ' }) | Select-Object -Last 1
    if ("$line" -match '^RESULT: ([A-Z_]+): (.*)$') { return @{ ExitCode = $ExitCode; Code = $Matches[1]; Message = $Matches[2].Trim() } }
    $tail = (@($Lines | Where-Object { "$_".Trim() }) | Select-Object -Last 3) -join ' | '
    return @{ ExitCode = $(if ($ExitCode) { $ExitCode } else { 1 }); Code = 'ERROR'; Message = "manage.py ensure_admin failed (exit code $ExitCode): $tail" }
}

function Invoke-EnsureAdmin([string[]]$Arguments, [string]$Password = '') {
    # Runs `manage.py ensure_admin`. The password reaches it only through
    # the environment variable COMPULAB_ADMIN_PASSWORD of this one process
    # (never on a command line, never in the install log).
    Push-Location $script:AppDir
    try {
        if ($Password) { $env:COMPULAB_ADMIN_PASSWORD = $Password } else { Remove-Item Env:\COMPULAB_ADMIN_PASSWORD -ErrorAction SilentlyContinue }
        $out = @(Invoke-Captured $script:VenvPython (@('manage.py', 'ensure_admin') + $Arguments))
        $code = $LASTEXITCODE
    } finally {
        Remove-Item Env:\COMPULAB_ADMIN_PASSWORD -ErrorAction SilentlyContinue
        Pop-Location
    }
    return ConvertFrom-EnsureAdminOutput $out $code
}

function Read-SecretText([string]$Prompt) {
    # Read-Host -AsSecureString, returned as text for this process only.
    $secure = Read-Host -AsSecureString $Prompt
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-Manage([string[]]$Arguments) {
    Push-Location $script:AppDir
    try {
        Invoke-Logged $script:VenvPython (@('manage.py') + $Arguments)
        if ($LASTEXITCODE -ne 0) { throw "manage.py $($Arguments -join ' ') failed (exit code $LASTEXITCODE)." }
    } finally { Pop-Location }
}
