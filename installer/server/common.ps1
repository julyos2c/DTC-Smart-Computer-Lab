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

# Bundled runtime (CompuLab-Server-Setup.exe ships it; a plain folder copy of
# the source has none and uses an installed Python + venv and an existing
# MariaDB/MySQL instead). Program files under runtime\ are replaced by every
# update; the database's data under data\ is never touched by the setup.
$script:RuntimeDir = Join-Path $script:AppDir 'runtime'
$script:BundledPython = Join-Path $script:RuntimeDir 'python\python.exe'
$script:BundledDbDir = Join-Path $script:RuntimeDir 'mariadb'
$script:BundledDbBin = Join-Path $script:BundledDbDir 'bin'
$script:DataDir = Join-Path $script:AppDir 'data'
$script:BundledDbData = Join-Path $script:DataDir 'mariadb'
$script:BundledDbConfig = Join-Path $script:BundledDbData 'my.ini'
$script:BundledDbMarker = Join-Path $script:BundledDbData 'compulab-provisioned.txt'
# The database administrator's (root's) sign-in: only Administrators and
# SYSTEM can read it. Never printed, never on a command line.
$script:DbAdminCnf = Join-Path $script:DataDir 'db-admin.cnf'
$script:BundledDbService = 'CompuLabMariaDB'
$script:BundledDbPreferredPort = 3308
$script:RuntimeManifestName = 'COMPULAB-MANIFEST.txt'

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
    Protect-SecretFile $script:EnvFile
}

function Get-SecretFileAclArgs([string]$Path) {
    # icacls arguments for a file holding passwords: inherited permissions
    # removed; Administrators, SYSTEM and the installing account only. SIDs,
    # not names, so it also works on a non-English Windows.
    return @($Path, '/inheritance:r', '/grant:r', '*S-1-5-32-544:F', '*S-1-5-18:F', "*$(Get-CurrentUserSid):F")
}

function Protect-SecretFile([string]$Path) {
    & icacls @(Get-SecretFileAclArgs $Path) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not restrict access to $Path (icacls exit code $LASTEXITCODE)." }
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

# Every .env this installer writes has all five; the database is found and
# signed in to with them.
$script:DbEnvKeys = @('DB_NAME', 'DB_USER', 'DB_PASSWORD', 'DB_HOST', 'DB_PORT')

function Test-ExistingDbSettings([hashtable]$EnvValues, [string[]]$Given = @()) {
    # Repair / update (a .env already exists): which database holds the data
    # and how to sign in to it come from that .env. Returns the problems
    # (none: usable). Credentials are never invented for existing data; a
    # missing DB_HOST / DB_PORT is only filled in when given explicitly
    # (-DbHost / -DbPort, listed in $Given).
    $problems = @()
    $missing = @($script:DbEnvKeys | Where-Object { -not "$($EnvValues[$_])".Trim() })
    $credentials = @($missing | Where-Object { $_ -in @('DB_NAME', 'DB_USER', 'DB_PASSWORD') })
    if ($credentials.Count) {
        $problems += ("The existing .env ($script:EnvFile) has no $($missing -join ', '). Every CompuLab installation has all five DB_ settings, " +
                      'so this .env was not written by this installer (a development copy of CompuLab, or a hand-made .env?). ' +
                      'The installer does not invent database credentials for existing data. Install into an empty folder instead ' +
                      '(CompuLab-Server-Setup.exe, default C:\CompuLab), or put this installation''s database name, user and password into .env.')
        return $problems
    }
    $parameter = @{ DB_HOST = 'DbHost'; DB_PORT = 'DbPort' }
    $notGiven = @($missing | Where-Object { $parameter[$_] -notin $Given })
    if ($notGiven.Count) {
        $problems += ("The existing .env has no $($notGiven -join ' / '). Give the database's address explicitly, for example " +
                      '-DbHost 127.0.0.1 -DbPort 3306 (only if that is where this installation''s database is).')
    }
    return $problems
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

function Get-BackupSpaceNeed([string]$BackupRoot) {
    # Free space a new backup needs: twice the newest earlier backup, at least 100 MB.
    $last = Get-ChildItem -LiteralPath $BackupRoot -Directory -Filter 'compulab-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    $size = 0
    if ($last) { $size = [double](Get-ChildItem -LiteralPath $last.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
    return [long][Math]::Max(100MB, 2 * $size)
}

function Get-BackupSpaceProblem([string]$BackupRoot, [long]$NeedBytes) {
    # $null if the backup drive has $NeedBytes free (a network share is not checked).
    if ($BackupRoot -like '\\*') { return $null }
    try { $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($BackupRoot)))).AvailableFreeSpace } catch { return $null }
    if ($free -ge $NeedBytes) { return $null }
    return ("Only {0:N0} MB free for the backup folder '{1}'; a backup needs about {2:N0} MB. Free some space or use another drive (-BackupRoot). Nothing was written." -f ($free / 1MB), $BackupRoot, ($NeedBytes / 1MB))
}

function Get-BackupAllowedSids { return @(@('S-1-5-32-544', 'S-1-5-18', (Get-CurrentUserSid)) | Sort-Object -Unique) }

function Test-BackupFolderProtected([string]$Path) {
    # True if $Path inherits nothing and grants access only to Administrators,
    # SYSTEM and the account running the backup.
    $acl = Get-Acl -LiteralPath $Path
    $allowed = Get-BackupAllowedSids
    $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
    return [bool]($acl.AreAccessRulesProtected -and $sids.Count -and -not @($sids | Where-Object { $allowed -notcontains $_ }).Count)
}

function New-ProtectedBackupFolder([string]$BackupRoot, [string]$Stamp) {
    # Creates <BackupRoot>\partial-compulab-<Stamp>[-n] and closes it to
    # everyone but Administrators, SYSTEM and this account BEFORE anything is
    # written into it (the backup holds the database and a copy of .env).
    # New-Item refuses an existing name, so two backups started in the same
    # second never share a folder. Returns the folder; Invoke-ProtectedBackup
    # renames it to compulab-... once complete.
    for ($n = 1; $n -le 100; $n++) {
        $name = "compulab-$Stamp" + $(if ($n -gt 1) { "-$n" } else { '' })
        $target = Join-Path $BackupRoot "partial-$name"
        if ((Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath (Join-Path $BackupRoot $name))) { continue }
        try { New-Item -ItemType Directory -Path $target -ErrorAction Stop | Out-Null }
        catch { if (Test-Path -LiteralPath $target) { continue }; throw }   # taken by a backup running at the same time
        try {
            $ds = New-Object Security.AccessControl.DirectorySecurity
            $ds.SetAccessRuleProtection($true, $false)
            foreach ($sid in Get-BackupAllowedSids) {
                $ds.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
            }
            [IO.Directory]::SetAccessControl($target, $ds)
            if (-not (Test-BackupFolderProtected $target)) { throw 'its permissions could not be restricted' }
            if (@(Get-ChildItem -LiteralPath $target -Force).Count) { throw 'something was put into it before it was protected' }
        } catch {
            $why = $_.Exception.Message
            try { [IO.Directory]::Delete($target, $false) } catch { }   # only an empty folder, never recursively
            throw "The backup folder $target could not be protected ($why). Nothing was written."
        }
        return $target
    }
    throw "No free backup folder name for compulab-$Stamp in $BackupRoot."
}

function Invoke-ProtectedBackup([string]$BackupRoot, [string]$Stamp, [scriptblock]$Write) {
    # Runs $Write (which fills the folder) in a folder protected first, then
    # gives it its final name compulab-... and returns that. Only complete
    # backups are ever named compulab-* (what restore lists and the retention
    # counts): a backup that fails is renamed incomplete-compulab-..., one
    # whose process is killed stays partial-compulab-... - both kept and still
    # protected, never counted as a backup. The error is passed on.
    $work = New-ProtectedBackupFolder $BackupRoot $Stamp
    $final = Join-Path $BackupRoot ((Split-Path $work -Leaf) -replace '^partial-', '')
    try { $null = & $Write $work }
    catch {
        $err = $_
        try { Rename-Item -LiteralPath $work -NewName ('incomplete-' + (Split-Path $final -Leaf)) -ErrorAction Stop } catch { }
        throw $err
    }
    Rename-Item -LiteralPath $work -NewName (Split-Path $final -Leaf) -ErrorAction Stop
    return $final
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

function Read-VenvConfig([string]$VenvDir) {
    # The pyvenv.cfg of a Python environment: @{ Home; Version ('3.13') }, or $null.
    $cfg = Join-Path $VenvDir 'pyvenv.cfg'
    if (-not (Test-Path $cfg)) { return $null }
    $info = @{ Home = ''; Version = '' }
    foreach ($line in Get-Content $cfg) {
        if ($line -match '^\s*home\s*=\s*(.+?)\s*$') { $info.Home = $Matches[1] }
        elseif ($line -match '^\s*version(_info)?\s*=\s*(\d+\.\d+)') { $info.Version = $Matches[2] }
    }
    return $info
}

function Test-VenvMatchesPython([string]$VenvDir, [hashtable]$Python) {
    # $null when the existing venv was made from the Python this setup uses
    # (same version, same installation), else why it cannot be reused. A
    # venv of another Python would keep running the old one: packages built
    # for 3.13 don't install into it, and a "just for me" Python replaced by
    # an "all users" one would still be used.
    if (-not (Test-Path (Join-Path $VenvDir 'Scripts\python.exe'))) { return 'its python.exe is missing' }
    $cfg = Read-VenvConfig $VenvDir
    if (-not $cfg -or -not $cfg.Version) { return 'its pyvenv.cfg is missing or unreadable' }
    if ($cfg.Version -ne $Python.Version) { return "it uses Python $($cfg.Version), but this setup uses Python $($Python.Version)" }
    if ($cfg.Home -and $Python.BasePrefix -and $cfg.Home.TrimEnd('\') -ne "$($Python.BasePrefix)".TrimEnd('\')) {
        return "it was made from the Python in $($cfg.Home), but this setup uses $($Python.BasePrefix)"
    }
    return $null
}

function Move-VenvAside([string]$VenvDir) {
    # Renames the old environment instead of deleting it; returns the new name.
    $target = "$VenvDir.old-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    try { Move-Item -LiteralPath $VenvDir -Destination $target -ErrorAction Stop }
    catch {
        throw ("The old Python environment ($VenvDir) could not be moved aside: $($_.Exception.Message) " +
               'Close the programs that use CompuLab (or restart the computer) and run the setup again.')
    }
    return $target
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
    # An empty host or port would make mysql fail with a misleading message.
    if (-not "$DbHost".Trim()) { throw 'The database host is empty (DB_HOST in .env).' }
    if ("$Port" -notmatch '^\d{1,5}$') { throw "The database port is empty or not a number ('$Port', DB_PORT in .env)." }
    $path = Join-Path $env:TEMP ("compulab-db-" + [guid]::NewGuid().ToString('N') + '.cnf')
    $content = "[client]`nuser=$User`npassword=$Password`nhost=$DbHost`nport=$Port`n"
    [IO.File]::WriteAllText($path, $content, (New-Object Text.UTF8Encoding $false))
    & icacls $path /inheritance:r /grant:r "*$(Get-CurrentUserSid):F" 'SYSTEM:F' | Out-Null
    return $path
}

function Get-DbSignIn([string]$MySqlExe, [string]$DefaultsFile) {
    # Signs in with the options file and asks for the server version.
    # @{ Version = e.g. '11.4.13-MariaDB' or '8.4.3'; Lines = @() } when it
    # works, @{ Version = $null; Lines = what mysql printed } when it doesn't
    # (ConvertTo-DbErrorText explains those lines).
    $out = @(Invoke-Captured $MySqlExe @("--defaults-extra-file=$DefaultsFile", '--batch', '--skip-column-names', '-e', 'SELECT VERSION();'))
    $code = $LASTEXITCODE
    $version = @($out | Where-Object { $_ -match '^\s*\d+\.\d+\.\d+' })
    if ($code -eq 0 -and $version.Count) { return @{ Version = $version[0].Trim(); Lines = @() } }
    return @{ Version = $null; Lines = $out }
}

function ConvertTo-DbErrorText([string[]]$Lines, [string]$DbHost, [string]$Port, [string]$Secret = '', [string]$User = 'root') {
    # mysql's own message, cleaned up (no password, no temporary file path, no
    # warnings), after what it means in plain words. Never just "wrong
    # password": an empty password, a stopped server or an empty port are
    # different problems with different fixes.
    $raw = @($Lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -notmatch '\[Warning\]' })
    $errors = @($raw | Where-Object { $_ -match 'ERROR|Unknown|Can.t connect|Empty value' })
    $text = (@($(if ($errors.Count) { $errors } else { $raw })) | Select-Object -First 2) -join ' '
    $text = $text -replace '(^|\s)(mysql|mariadb)(\.exe)?\s*:\s*', '$1'
    $text = $text -replace '[A-Za-z]:\\[^\s''"]*?\.cnf', '<options file>'
    # mysql never prints the password; masked anyway in case a message ever
    # does (only when long enough not to give itself away by the masking).
    if ($Secret -and $Secret.Length -ge 6) { $text = $text.Replace($Secret, '********') }
    $text = $text.Trim()
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
    if (-not $text) { $text = '(no message)' }
    $meaning = switch -Regex ($text) {
        'Empty value for .port.' { 'The database port is empty (DB_PORT in .env).'; break }
        '1045.*using password: NO' { "No password was given, but the database server needs one for '$User'. Type the MariaDB/MySQL root password: click into this window first; each character shows as *."; break }
        '1045' { "The password for '$User' was not accepted: it is wrong, or '$User' may not sign in from $DbHost."; break }
        '1130|is not allowed to connect' { "'$User' may not sign in to the database server from this computer (host $DbHost)."; break }
        '2059|authentication plugin|caching_sha2' { 'This mysql.exe cannot use the database server''s sign-in method: use the client that came with the server (not XAMPP''s).'; break }
        '2005|Unknown (MySQL|MariaDB) server host' { "The database host '$DbHost' was not found."; break }
        '2002|2003|Can.t connect' { "No database server answered on ${DbHost}:$Port (is the MariaDB/MySQL service running?)."; break }
        default { 'The database server refused the sign-in.' }
    }
    return "$meaning Database server said: $text"
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
    if (-not $svc) {
        # MySQL 8.4 runs as a service process that starts a second mysqld,
        # which owns the port: the service is the parent's.
        $parent = (Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue).ParentProcessId
        if ($parent) { $svc = Get-CimInstance Win32_Service -Filter "ProcessId = $parent" -ErrorAction SilentlyContinue | Select-Object -First 1 }
    }
    $path = ''
    try { $path = [string](Get-Process -Id $procId -ErrorAction Stop).Path } catch { }
    if (-not $path -and $svc) { $path = [string]$svc.PathName }
    return @{ ProcessId = $procId; ProcessPath = $path; ServiceName = $(if ($svc) { [string]$svc.Name } else { '' }) }
}

function Test-DbListener($Listener, [string]$DbHost, [int]$Port, [string]$AllowedService = '') {
    # $null if CompuLab may use the database server listening on $Port of
    # this computer, else what is wrong and what to do. Pure (tested).
    # CompuLab never stops, changes or replaces another database: it refuses.
    # $AllowedService: a service named explicitly with -DbServiceName.
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
    # A MariaDB/MySQL that another program installed as its own service (for
    # example an inventory or accounting program's bundled database) holds
    # that program's data: never used, unless named with -DbServiceName.
    $service = "$($Listener.ServiceName)"
    if ($service -and $service -notmatch '^(MariaDB|MySQL)' -and $service -ne $AllowedService) {
        $where = if ($path) { " ($path)" } else { '' }
        return ("Port $Port is used by the database of another program: the service '$service'$where. CompuLab does not use, stop or change it. " +
                'Install MariaDB 11.4 LTS on a free port (for example 3308: choose it in the MariaDB setup) and enter that port as the ' +
                '"Database port" in the setup (or -DbPort 3308).')
    }
    return $null
}

function Get-DbServerBinDir($Listener) {
    # The folder of the database server program that owns the port (from
    # its path, or its service command line), or $null.
    if (-not $Listener) { return $null }
    $exe = "$($Listener.ProcessPath)".Trim()
    if ($exe -match '^"([^"]+)"') { $exe = $Matches[1] }
    elseif ($exe -match '^(.+?\.exe)\b') { $exe = $Matches[1] }
    if (-not $exe -or $exe -notmatch '(?i)\.exe$') { return $null }
    $dir = Split-Path -Parent $exe
    if ($dir -and (Test-Path -LiteralPath $dir)) { return $dir }
    return $null
}

function Select-DbClientInDir([string]$Dir, [string]$Kind) {
    # The client ('client': mariadb.exe / mysql.exe) or dump program ('dump':
    # mariadb-dump.exe / mysqldump.exe) in that folder, or $null. MariaDB 11
    # may ship only the mariadb* names.
    if (-not $Dir) { return $null }
    $names = if ($Kind -eq 'dump') { @('mariadb-dump.exe', 'mysqldump.exe') } else { @('mariadb.exe', 'mysql.exe') }
    foreach ($n in $names) {
        $p = Join-Path $Dir $n
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Find-DbClient([string]$Kind, [string]$Port = '', [string]$DbHost = '127.0.0.1') {
    # The client or dump program that belongs to the database server CompuLab
    # uses: from the folder of the server listening on its port on this
    # computer (another product's tools can fail against it, e.g. MySQL's
    # mysqldump against MariaDB), else the first one installed.
    if ("$Port" -match '^\d{1,5}$' -and $DbHost -in @('127.0.0.1', 'localhost')) {
        $own = Select-DbClientInDir (Get-DbServerBinDir (Get-ListenerInfo ([int]$Port))) $Kind
        if ($own) { return $own }
    }
    $names = if ($Kind -eq 'dump') { @('mysqldump.exe', 'mariadb-dump.exe') } else { @('mysql.exe', 'mariadb.exe') }
    foreach ($n in $names) {
        $found = Find-MySqlTool $n
        if ($found) { return $found }
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
    $python = Get-AppPython
    return @(
        # 0.0.0.0: reachable on the campus LAN and, if configured, the
        # Tailscale address; the firewall rule limits who may connect.
        # "python -m waitress" works with the bundled Python (which has no
        # Scripts\ folder) and with a venv alike.
        @{ Id = $script:WebService; Name = 'CompuLab Web'; Exe = $python;
           Args = "-m waitress --listen=0.0.0.0:$Port --threads=8 compulab.wsgi:application";
           Desc = "CompuLab website (waitress). Serves the campus network on port $Port.";
           Env = [ordered]@{ 'COMPULAB_BACKGROUND_TASKS' = 'False' } },
        @{ Id = $script:WorkerService; Name = 'CompuLab Worker'; Exe = $python;
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

function Get-OwnService([string]$Name) {
    # The Windows service of that name, but only if it belongs to THIS
    # CompuLab folder (its program is inside $script:AppDir). Service names
    # are global: a service of another CompuLab installation (or of a test
    # installation) on the same computer is never stopped, started, changed
    # or removed from here.
    $w = Get-CimInstance Win32_Service -Filter "Name = '$Name'" -ErrorAction SilentlyContinue
    if (-not $w) { return $null }
    if ("$($w.PathName)".IndexOf($script:AppDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $null }
    return Get-Service -Name $Name -ErrorAction SilentlyContinue
}

function Get-ForeignServicePath([string]$Name) {
    # The program path of a service of that name that does NOT belong to this
    # folder, or '' (none, or ours).
    $w = Get-CimInstance Win32_Service -Filter "Name = '$Name'" -ErrorAction SilentlyContinue
    if (-not $w -or (Get-OwnService $Name)) { return '' }
    return "$($w.PathName)"
}

function Stop-CompuLabServices {
    foreach ($name in $script:WorkerService, $script:WebService) {
        $svc = Get-OwnService $name
        if ($svc -and $svc.Status -ne 'Stopped') { Stop-Service -Name $name -Force; Write-Ok "Stopped $name" }
    }
}

function Start-CompuLabServices {
    foreach ($name in $script:WebService, $script:WorkerService) {
        $svc = Get-OwnService $name
        if ($svc) { Start-Service -Name $name; Write-Ok "Started $name" }
        else { Write-Note "Service $name is not installed for $($script:AppDir) (run install-server.ps1)." }
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
        $out = @(Invoke-Captured (Get-AppPython) (@('manage.py', 'ensure_admin') + $Arguments))
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
        Invoke-Logged (Get-AppPython) (@('manage.py') + $Arguments)
        if ($LASTEXITCODE -ne 0) { throw "manage.py $($Arguments -join ' ') failed (exit code $LASTEXITCODE)." }
    } finally { Pop-Location }
}

# ---------------------------------------------------------------- bundled runtime
# CompuLab-Server-Setup.exe ships runtime\python (the official Python
# embeddable package with CompuLab's packages already installed) and
# runtime\mariadb (the official MariaDB server files), so the server needs
# no Python, no database server, no root password and no internet.
$script:BundledDbRequiredFiles = @('bin\mariadbd.exe', 'bin\server.dll', 'bin\mariadb.exe', 'bin\mariadb-dump.exe',
    'bin\mariadb-admin.exe', 'bin\mariadb-install-db.exe', 'bin\mariadb-upgrade.exe', 'share\english\errmsg.sys', 'COPYING')
$script:BundledPythonRequiredFiles = @('python.exe', 'python313.dll', 'python313.zip', 'python313._pth', 'LICENSE.txt')

function Get-AppPython {
    # The Python that runs CompuLab: the bundled one if present, else the
    # venv of a plain folder copy.
    if (Test-Path -LiteralPath $script:BundledPython) { return $script:BundledPython }
    return $script:VenvPython
}

function Test-BundledPython { return (Test-Path -LiteralPath $script:BundledPython) }
function Test-BundledDbAvailable { return (Test-Path -LiteralPath (Join-Path $script:BundledDbBin 'mariadbd.exe')) }

function Test-RuntimeFiles([string]$Dir, [string[]]$Required) {
    # Problems with a bundled runtime folder (none: usable). Every required
    # file must be there, and every file listed in COMPULAB-MANIFEST.txt
    # (written by the build: "<sha256>  <relative path>") must have exactly
    # that SHA-256: an incomplete or damaged copy is refused before use.
    $problems = @()
    foreach ($r in $Required) { if (-not (Test-Path -LiteralPath (Join-Path $Dir $r))) { $problems += "missing $r" } }
    $manifest = Join-Path $Dir $script:RuntimeManifestName
    if (-not (Test-Path -LiteralPath $manifest)) { $problems += "missing $($script:RuntimeManifestName)"; return $problems }
    $listed = 0
    foreach ($line in Get-Content -LiteralPath $manifest) {
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { continue }
        $listed++
        $expected = $Matches[1]; $rel = $Matches[2]
        $file = Join-Path $Dir $rel
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { $problems += "missing $rel"; continue }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower() -ne $expected) { $problems += "damaged $rel (SHA-256 differs from the build)" }
    }
    if ($listed -eq 0) { $problems += "$($script:RuntimeManifestName) lists no files" }
    return $problems
}

function Test-TcpPortFree([int]$Port) {
    # Nothing listens on it, and it can be opened on 127.0.0.1 (this also
    # catches ports Windows reserves, e.g. for Hyper-V).
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { return $false }
    $l = $null
    try { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port); $l.Start(); return $true }
    catch { return $false }
    finally { if ($l) { $l.Stop() } }
}

function Select-DbPort([int]$Preferred, [scriptblock]$IsFree = $null, [int]$Tries = 92) {
    # The preferred port if free, else the next free one above it. A port in
    # use is only skipped: the program using it (MySQL, another program's
    # database, ...) is never stopped, changed or asked.
    if (-not $IsFree) { $IsFree = { param($p) Test-TcpPortFree $p } }
    $last = [Math]::Min(65535, $Preferred + $Tries - 1)
    for ($p = $Preferred; $p -le $last; $p++) { if (& $IsFree $p) { return $p } }
    throw "No free port for CompuLab's database between $Preferred and $last. Free one, or choose another starting port with -DbPort."
}

function New-BundledDbConfig([string]$DataDir, [int]$Port, [string]$BaseDir) {
    # CompuLab's own my.ini, written as a whole (settings appended to the one
    # mariadb-install-db writes would end up in its [client] section). The
    # server listens on 127.0.0.1 only: never reachable from the LAN.
    $fwd = { param($p) ("$p" -replace '\\', '/') }
    return (@(
        '# Written by CompuLab (installer\server\install-server.ps1) and rewritten on every repair: do not edit.',
        '[mysqld]',
        "datadir=$(& $fwd $DataDir)",
        "port=$Port",
        'bind-address=127.0.0.1',
        'character-set-server=utf8mb4',
        'collation-server=utf8mb4_unicode_ci',
        "log-error=$(& $fwd (Join-Path $DataDir 'compulab-mariadb.err'))",
        'innodb_buffer_pool_size=256M',
        'max_allowed_packet=64M',
        '[client]',
        "port=$Port",
        "plugin-dir=$(& $fwd (Join-Path $BaseDir 'lib\plugin'))"
    ) -join "`r`n") + "`r`n"
}

function Get-BundledDbPort {
    # The port in CompuLab's my.ini ([mysqld] section), or 0 if there is none
    # yet or it cannot be read (an earlier installer could leave it without
    # permissions; Repair-BundledDbFiles fixes that before it is used).
    if (-not (Test-Path -LiteralPath $script:BundledDbConfig)) { return 0 }
    try { $lines = @(Get-Content -LiteralPath $script:BundledDbConfig -ErrorAction Stop) } catch { return 0 }
    $section = ''
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $section = $Matches[1].ToLower(); continue }
        if ($section -eq 'mysqld' -and $line -match '^\s*port\s*=\s*(\d+)\s*$') { return [int]$Matches[1] }
    }
    return 0
}

function Get-BundledDbRootSql([string]$RootPassword) {
    # Run by mariadbd --bootstrap, which has no network at all, before the
    # server ever listens: root gets a password (mariadb-install-db leaves it
    # empty) and may sign in from this computer only (the root@<computer
    # name> account mariadb-install-db also creates, without a password, is
    # removed); no anonymous accounts.
    # Bootstrap runs with --skip-grant-tables: FLUSH PRIVILEGES loads the
    # account tables first, else ALTER USER is refused (error 1290).
    $pw = $RootPassword.Replace('\', '\\').Replace("'", "''")
    return @"
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '$pw';
ALTER USER IF EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '$pw';
ALTER USER IF EXISTS 'root'@'::1' IDENTIFIED BY '$pw';
DELETE FROM mysql.global_priv WHERE User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'%';
FLUSH PRIVILEGES;
"@
}

function Get-BundledDbHardeningSql([switch]$DropTestDatabase) {
    # CompuLab's own server only (never an external one). mariadb-install-db
    # gives every account (the PUBLIC role) full rights on `test` and on any
    # database named test_...: those rights are removed on every install and
    # repair (idempotent). The empty `test` database itself is dropped only
    # for a data folder created in this run (never one that holds data).
    $sql = "DELETE FROM mysql.db WHERE User = 'PUBLIC' AND Db IN ('test', 'test\\_%');`r`nFLUSH PRIVILEGES;`r`n"
    if ($DropTestDatabase) { $sql = "DROP DATABASE IF EXISTS ``test``;`r`n" + $sql }
    return $sql
}

function Hide-Secret([string]$Text, [string[]]$Secrets) {
    # Masks passwords in program output before it is shown or logged.
    foreach ($s in $Secrets) { if ($s -and $s.Length -ge 6) { $Text = $Text.Replace($s, '********') } }
    return $Text
}

function Invoke-WithStdin([string]$Exe, [string[]]$Arguments, [string]$InputText, [string[]]$Secrets = @()) {
    # Runs a program with text on its standard input as UTF-8 WITHOUT a byte
    # order mark (Windows PowerShell 5.1 adds one when piping, which
    # mariadbd --bootstrap rejects). Passwords travel only this way, never on
    # a command line. Returns @{ ExitCode; Lines } with the secrets masked.
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (@($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # .NET Framework opens the program's stdin with the console's input
    # encoding and, when that is UTF-8 (code page 65001), writes a BOM as soon
    # as the program starts: start it with UTF-8 *without* BOM instead.
    $previousEncoding = $null
    try { $previousEncoding = [Console]::InputEncoding; [Console]::InputEncoding = New-Object Text.UTF8Encoding $false } catch { $previousEncoding = $null }
    try { $p = [Diagnostics.Process]::Start($psi) }
    finally { if ($previousEncoding) { try { [Console]::InputEncoding = $previousEncoding } catch { } } }
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($InputText)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
    $p.WaitForExit()
    $text = Hide-Secret ($out.Result + "`n" + $err.Result) $Secrets
    return @{ ExitCode = $p.ExitCode; Lines = @($text -split "`r?`n" | Where-Object { $_.Trim() }) }
}

function Read-DbAdminCnf {
    # @{ Password; Port } from db-admin.cnf, or $null.
    if (-not (Test-Path -LiteralPath $script:DbAdminCnf)) { return $null }
    $v = @{}
    foreach ($line in Get-Content -LiteralPath $script:DbAdminCnf) { if ($line -match '^\s*(password|port)\s*=\s*(.*)$') { $v[$Matches[1]] = $Matches[2].Trim() } }
    if (-not $v['password']) { return $null }
    return @{ Password = $v['password']; Port = $v['port'] }
}

function Write-DbAdminCnf([string]$Password, [int]$Port) {
    New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
    [IO.File]::WriteAllText($script:DbAdminCnf, "[client]`r`nuser=root`r`npassword=$Password`r`nhost=127.0.0.1`r`nport=$Port`r`n", (New-Object Text.UTF8Encoding $false))
    Protect-SecretFile $script:DbAdminCnf
}

function Get-BundledDbProcess {
    # mariadbd processes started from CompuLab's own runtime\mariadb\bin (never
    # another program's database).
    $prefix = $script:BundledDbBin.TrimEnd('\') + '\'
    return @(Get-CimInstance Win32_Process -Filter "Name = 'mariadbd.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}

function Test-ListenerIsBundledDb($Listener) {
    if (-not $Listener) { return $false }
    if ($Listener.ServiceName -eq $script:BundledDbService) { return $true }
    $dir = Get-DbServerBinDir $Listener
    return [bool]($dir -and $dir.TrimEnd('\') -ieq $script:BundledDbBin.TrimEnd('\'))
}

function Get-ListenerAddresses([int]$Port) {
    return @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $_.LocalAddress } | Select-Object -Unique)
}

function Test-LocalOnlyAddresses([string[]]$Addresses) {
    # True when a server listens on 127.0.0.1 only (not reachable from the LAN).
    return ($Addresses.Count -gt 0 -and @($Addresses | Where-Object { $_ -ne '127.0.0.1' }).Count -eq 0)
}

function Get-BundledDbServiceSpec {
    # How the CompuLabMariaDB service is registered (checked by the tests
    # without registering it): mariadbd runs as a service when the service
    # name is its last argument; it gets its own virtual account
    # (NT SERVICE\CompuLabMariaDB), not LocalSystem.
    $exe = Join-Path $script:BundledDbBin 'mariadbd.exe'
    return @{
        Name = $script:BundledDbService
        DisplayName = 'CompuLab Database (MariaDB)'
        Description = 'CompuLab''s own MariaDB database. Listens on 127.0.0.1 only; CompuLab Web and CompuLab Worker start after it.'
        BinaryPathName = "`"$exe`" `"--defaults-file=$($script:BundledDbConfig)`" $($script:BundledDbService)"
        Account = "NT SERVICE\$($script:BundledDbService)"
    }
}

function Register-BundledDbService {
    # Creates the CompuLabMariaDB service once; a repair keeps it. A service
    # of that name that runs anything else is never changed.
    $spec = Get-BundledDbServiceSpec
    $existing = Get-CimInstance Win32_Service -Filter "Name = '$($spec.Name)'" -ErrorAction SilentlyContinue
    if ($existing) {
        if ("$($existing.PathName)".IndexOf($script:BundledDbBin, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "A Windows service named $($spec.Name) already exists and runs '$($existing.PathName)', not CompuLab's database. It was not changed. Remove or rename it, then run the installer again."
        }
        return $false
    }
    # Manual until it has started and answered once (Set-BundledDbAutoStart):
    # a failed installation must not leave a service Windows restarts every
    # minute.
    New-Service -Name $spec.Name -BinaryPathName $spec.BinaryPathName -DisplayName $spec.DisplayName -Description $spec.Description -StartupType Manual | Out-Null
    if (-not (Get-Service -Name $spec.Name -ErrorAction SilentlyContinue)) { throw "Registering the $($spec.Name) service failed." }
    Invoke-Quiet 'sc.exe' @('config', $spec.Name, 'obj=', $spec.Account) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not set the account of the $($spec.Name) service (sc.exe exit code $LASTEXITCODE)." }
    Invoke-Quiet 'sc.exe' (Get-ServiceRecoveryArgs $spec.Name) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not set the restart-on-failure actions of the $($spec.Name) service (sc.exe exit code $LASTEXITCODE)." }
    return $true
}

function Set-BundledDbAutoStart {
    # After the database service started and answered: start at every boot.
    $svc = Get-CimInstance Win32_Service -Filter "Name = '$($script:BundledDbService)'" -ErrorAction SilentlyContinue
    if ($svc -and $svc.StartMode -ne 'Auto') {
        Set-Service -Name $script:BundledDbService -StartupType Automatic
        Write-Ok "Service $($script:BundledDbService) set to start automatically at boot"
    }
}

function Get-BundledDbAclArgs {
    # icacls calls for the database files: Administrators, SYSTEM and the
    # database service's own account; not ordinary users.
    #  1. The data folder itself: inherited permissions removed, these
    #     granted as inheritable. Never with /T: icacls /inheritance:r ... /T
    #     leaves every FILE inside with no permission entry at all (nobody,
    #     not even the database, can open my.ini - found on a real install).
    #  2. Everything inside: back to plain inheritance from the folder (also
    #     repairs files an earlier installer left without permissions).
    #  3. The program files: readable for the service account (inherited by
    #     the files inside without /T).
    $svc = "NT SERVICE\$($script:BundledDbService)"
    return @(
        @($script:BundledDbData, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', "${svc}:(OI)(CI)M", '/Q'),
        @((Join-Path $script:BundledDbData '*'), '/reset', '/T', '/Q'),
        @($script:BundledDbDir, '/grant', "${svc}:(OI)(CI)RX", '/Q')
    )
}

function Protect-BundledDbData {
    foreach ($a in Get-BundledDbAclArgs) {
        $out = @(& icacls @a 2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) { throw "Could not set the permissions of $($a[0]) (icacls exit code $LASTEXITCODE): $(($out | Select-Object -Last 2) -join ' ')" }
    }
    # Proof, not trust: the database settings must be readable afterwards.
    try { $null = [IO.File]::ReadAllText($script:BundledDbConfig) }
    catch { throw "After setting its permissions, $($script:BundledDbConfig) cannot be read: $($_.Exception.Message)" }
}

function Repair-BundledDbFiles {
    # A data folder an earlier installer left with unreadable files (icacls
    # /inheritance:r ... /T: no permission entry at all, so not even an
    # Administrator can open my.ini): everything inside goes back to
    # inheriting the folder's permissions, before any file in it is read or
    # written. Only when my.ini cannot be read; nothing is moved or deleted.
    if (-not (Test-Path -LiteralPath $script:BundledDbConfig)) { return }
    try { $null = [IO.File]::ReadAllText($script:BundledDbConfig); return } catch { }
    $out = @(& icacls (Join-Path $script:BundledDbData '*') /reset /T /Q 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw ("$($script:BundledDbConfig) cannot be read and its permissions could not be repaired (icacls exit code $LASTEXITCODE): " +
               "$(($out | Select-Object -Last 2) -join ' '). Run the setup as Administrator. The database files were not changed.")
    }
    try { $null = [IO.File]::ReadAllText($script:BundledDbConfig) }
    catch { throw "After repairing its permissions, $($script:BundledDbConfig) still cannot be read: $($_.Exception.Message). The database files were not changed." }
    Write-Ok "Permissions of the files in $($script:BundledDbData) repaired (an earlier installation left them unreadable); data unchanged"
}

function Initialize-BundledDbService {
    # Registers the service (once) and gives its account the data folder.
    # Returns $true when the service was created now.
    $created = Register-BundledDbService
    if ($created) { Write-Ok "Service $($script:BundledDbService) registered (its own account NT SERVICE\$($script:BundledDbService))" }
    Protect-BundledDbData
    return $created
}

function Wait-BundledDbListening([int]$Port, [int]$Seconds = 90, $Process = $null) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $l = Get-ListenerInfo $Port
        if ($l) { return $l }
        if ($Process -and $Process.HasExited) { return $null }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Get-BundledDbErrorTail([int]$Lines = 6) {
    $err = Join-Path $script:BundledDbData 'compulab-mariadb.err'
    if (-not (Test-Path -LiteralPath $err)) { return '(no database log yet)' }
    return ((Get-Content -LiteralPath $err -Tail $Lines -ErrorAction SilentlyContinue | ForEach-Object { "$_".Trim() }) -join ' | ')
}

function Get-ListenerDescription($Listener) {
    if ($Listener.ServiceName) { return "the service '$($Listener.ServiceName)'$(if ($Listener.ProcessPath) { " ($($Listener.ProcessPath))" })" }
    if ($Listener.ProcessPath) { return "'$($Listener.ProcessPath)'" }
    return "process $($Listener.ProcessId)"
}

function Start-BundledDb([int]$Port, [switch]$AsService) {
    # Starts CompuLab's database (its Windows service, or without services a
    # background process) and waits until it listens on 127.0.0.1:$Port.
    $listener = Get-ListenerInfo $Port
    if ($listener) {
        if (Test-ListenerIsBundledDb $listener) { return $listener }
        throw ("Port $Port, CompuLab's database port, is used by $(Get-ListenerDescription $listener). That program was not stopped or changed. " +
               'Stop it, or move CompuLab''s database to a free port: run the installer again with -DbPort <port>.')
    }
    $proc = $null
    if ($AsService) {
        if (-not (Get-OwnService $script:BundledDbService)) {
            throw "The service $($script:BundledDbService) does not belong to $($script:AppDir) ($(Get-ForeignServicePath $script:BundledDbService)). It was not started or changed."
        }
        try { Start-Service -Name $script:BundledDbService -ErrorAction Stop }
        catch { throw "The $($script:BundledDbService) service did not start: $($_.Exception.Message) Its log says: $(Get-BundledDbErrorTail)" }
    } else {
        $proc = Start-Process -FilePath (Join-Path $script:BundledDbBin 'mariadbd.exe') -ArgumentList "--defaults-file=`"$($script:BundledDbConfig)`"" -WindowStyle Hidden -PassThru
    }
    $listener = Wait-BundledDbListening $Port 90 $proc
    if (-not $listener) { throw "CompuLab's database did not start on port $Port. Its log says: $(Get-BundledDbErrorTail)" }
    if (-not (Test-ListenerIsBundledDb $listener)) {
        throw "Port $Port answered, but by $(Get-ListenerDescription $listener), not CompuLab's database. Nothing was changed."
    }
    return $listener
}

function Stop-BundledDb {
    # Stops CompuLab's own database cleanly (its service, or its background
    # process); never any other database, and never the database service of
    # another CompuLab folder.
    $svc = Get-OwnService $script:BundledDbService
    if ($svc -and $svc.Status -ne 'Stopped') {
        Stop-Service -Name $script:BundledDbService -Force
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(120))
    }
    $procs = @(Get-BundledDbProcess)
    if (-not $procs.Count) { return }
    # A clean shutdown needs the administrator sign-in; without it (lost
    # db-admin.cnf) the process is ended after a short wait: InnoDB recovers
    # on the next start. Only CompuLab's own process is ever ended.
    $wait = 5
    if (Read-DbAdminCnf) {
        Invoke-Quiet (Join-Path $script:BundledDbBin 'mariadb-admin.exe') @("--defaults-extra-file=$($script:DbAdminCnf)", 'shutdown') | Out-Null
        $wait = 60
    }
    foreach ($p in $procs) {
        try { Wait-Process -Id $p.ProcessId -Timeout $wait -ErrorAction Stop } catch { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

function Initialize-BundledDb([int]$Port, [switch]$AsService) {
    # Creates (first run) or repairs CompuLab's own database server; returns
    # @{ Port; Created; Listener }. Idempotent and never destructive:
    #   - an existing data folder is never initialized again or emptied;
    #   - a half-created one (interrupted install: no system database) is
    #     moved aside, kept, and made again;
    #   - root's password is saved to db-admin.cnf BEFORE it is set, and a
    #     lost or rejected root sign-in is reset offline (--bootstrap), data
    #     unchanged.
    $bin = $script:BundledDbBin
    $created = $false
    New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
    Repair-BundledDbFiles
    $running = @(Get-BundledDbProcess).Count -gt 0
    if ($running -and (Get-BundledDbPort) -ne $Port) { Stop-BundledDb; $running = $false }   # moving to another port
    if (-not (Test-Path -LiteralPath (Join-Path $script:BundledDbData 'mysql'))) {
        if ($running) { Stop-BundledDb }
        if (Test-Path -LiteralPath $script:BundledDbData) {
            $aside = "$($script:BundledDbData).incomplete-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item -LiteralPath $script:BundledDbData -Destination $aside
            Write-Note "An unfinished database folder from an interrupted installation was moved to $aside (kept; delete it once CompuLab works)."
        }
        $out = @(Invoke-Captured (Join-Path $bin 'mariadb-install-db.exe') @("--datadir=$($script:BundledDbData)", "--port=$Port", '--silent'))
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $script:BundledDbData 'mysql'))) {
            throw "Creating CompuLab's database folder failed (mariadb-install-db exit code $LASTEXITCODE): $((@($out) | Select-Object -Last 3) -join ' | ')"
        }
        $created = $true
        Write-Ok "Database folder created: $($script:BundledDbData)"
    }
    # Order: the database is secured (bootstrap, as the installer) BEFORE its
    # service exists and before the folder is closed to everyone else. A
    # service that already exists (repair, update) first gets its folder
    # permissions repaired, before any file in it is written or read.
    if ($AsService -and (Get-OwnService $script:BundledDbService)) { Initialize-BundledDbService | Out-Null }
    [IO.File]::WriteAllText($script:BundledDbConfig, (New-BundledDbConfig $script:BundledDbData $Port $script:BundledDbDir), (New-Object Text.UTF8Encoding $false))

    $admin = Read-DbAdminCnf
    $setRoot = $created -or -not $admin -or -not (Test-Path -LiteralPath $script:BundledDbMarker)
    if (-not $setRoot) {
        Write-DbAdminCnf $admin.Password $Port
        Start-BundledDb $Port -AsService:$AsService | Out-Null
        $signIn = Get-DbSignIn (Join-Path $bin 'mariadb.exe') $script:DbAdminCnf
        if (-not $signIn.Version) {
            Write-Note "The saved database administrator sign-in was refused ($(ConvertTo-DbErrorText $signIn.Lines '127.0.0.1' "$Port" $admin.Password)). It is set again offline; the data is not changed."
            $setRoot = $true
        }
    }
    if ($setRoot) {
        # No second server on the same files while the bootstrap runs: an
        # existing service (e.g. one Windows keeps restarting after a failed
        # install) is disabled first, and set back to Manual afterwards.
        $hasService = $AsService -and (Get-OwnService $script:BundledDbService)
        if ($hasService) { Set-Service -Name $script:BundledDbService -StartupType Disabled }
        Stop-BundledDb
        $password = if ($admin) { $admin.Password } else { New-RandomSecret 32 }
        Write-DbAdminCnf $password $Port
        $r = Invoke-WithStdin (Join-Path $bin 'mariadbd.exe') @("--defaults-file=$($script:BundledDbConfig)", '--bootstrap', '--console') (Get-BundledDbRootSql $password) @($password)
        if ($r.ExitCode -ne 0) {
            throw "Securing CompuLab's database failed (bootstrap exit code $($r.ExitCode)): $((@($r.Lines) | Select-Object -Last 4) -join ' | ')"
        }
        [IO.File]::WriteAllText($script:BundledDbMarker, "CompuLab database administrator set $(Get-Date -Format s)`r`n", (New-Object Text.UTF8Encoding $false))
        $password = $null
        Write-Ok 'Database administrator password set (saved for Administrators only in data\db-admin.cnf)'
        if ($hasService) { Set-Service -Name $script:BundledDbService -StartupType Manual }
    }
    if ($AsService) { Initialize-BundledDbService | Out-Null }
    $listener = Start-BundledDb $Port -AsService:$AsService
    $addresses = Get-ListenerAddresses $Port
    if (-not (Test-LocalOnlyAddresses $addresses)) {
        throw "CompuLab's database listens on $($addresses -join ', '), not only on 127.0.0.1. Stopped here so it is not reachable from the network; check $($script:BundledDbConfig)."
    }
    return @{ Port = $Port; Created = $created; Listener = $listener }
}

function Test-DbHasCompuLabData([string]$MySqlExe, [hashtable]$EnvValues) {
    # Whether the database in .env already holds CompuLab tables: $true,
    # $false, or $null when it cannot be checked (not reachable, refused).
    $cnf = New-MySqlDefaultsFile $EnvValues['DB_USER'] $EnvValues['DB_PASSWORD'] $EnvValues['DB_HOST'] $EnvValues['DB_PORT']
    try {
        $name = "$($EnvValues['DB_NAME'])"
        if ($name -notmatch '^[A-Za-z0-9_]{1,64}$') { return $null }
        $out = @(Invoke-Captured $MySqlExe @("--defaults-extra-file=$cnf", '--batch', '--skip-column-names', '-e',
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$name' AND table_name = 'django_migrations'"))
        if ($LASTEXITCODE -ne 0) { return $null }
        $n = @($out | Where-Object { "$_" -match '^\s*\d+\s*$' })
        if (-not $n.Count) { return $null }
        return ([int]"$($n[0])".Trim() -gt 0)
    } finally { Remove-Item $cnf -Force -ErrorAction SilentlyContinue }
}

function Get-AppFolderAclArgs {
    # icacls arguments for the program folder when CompuLab runs as Windows
    # services (SYSTEM runs its Python from here): only Administrators and
    # SYSTEM may change it; users may read and run it. Files with their own
    # stricter permissions (.env, data\) keep them.
    return @($script:AppDir, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/Q')
}
