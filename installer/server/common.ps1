# Shared helpers for the CompuLab server scripts. Dot-source it:
#   . "$PSScriptRoot\common.ps1"
# Works with Windows PowerShell 5.1 (built into Windows 10/11).

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

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "    OK: $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "    $Text" -ForegroundColor Yellow }

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Please run this script as Administrator (right-click PowerShell > Run as administrator).'
    }
}

function New-RandomSecret([int]$Length = 50) {
    $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_'
    $bytes = New-Object byte[] $Length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
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
    # Only Administrators and SYSTEM may read .env (it holds passwords).
    & icacls $script:EnvFile /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' | Out-Null
}

# ---------------------------------------------------------------- network
function Get-LanAddresses {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
        Select-Object -ExpandProperty IPAddress
}

function Wait-Healthy([string]$Url = 'http://127.0.0.1:8000/healthz', [int]$Seconds = 60) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'ok') { return $true }
        } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ---------------------------------------------------------------- database tools
function Find-MySqlTool([string]$Name) {
    # Name: mysql.exe, mysqldump.exe, mariadb.exe, mariadb-dump.exe
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $roots = @("$env:ProgramFiles\MariaDB*\bin", "$env:ProgramFiles\MySQL\MySQL Server*\bin", 'C:\xampp\mysql\bin')
    foreach ($root in $roots) {
        $hit = Get-ChildItem -Path $root -Filter $Name -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function New-MySqlDefaultsFile([string]$User, [string]$Password, [string]$DbHost = '127.0.0.1', [string]$Port = '3306') {
    # Credentials go in a temporary options file (not on the command line,
    # where other processes could read them). Caller deletes it.
    $path = Join-Path $env:TEMP ("compulab-db-" + [guid]::NewGuid().ToString('N') + '.cnf')
    $content = "[client]`nuser=$User`npassword=$Password`nhost=$DbHost`nport=$Port`n"
    [IO.File]::WriteAllText($path, $content, (New-Object Text.UTF8Encoding $false))
    & icacls $path /inheritance:r /grant:r "$($env:USERNAME):F" 'SYSTEM:F' | Out-Null
    return $path
}

function Get-DbServerVersion([string]$MySqlExe, [string]$DefaultsFile) {
    # Returns e.g. '10.11.6-MariaDB' or '8.4.3', or $null if it can't connect.
    $out = 'SELECT VERSION();' | & $MySqlExe "--defaults-extra-file=$DefaultsFile" --batch --skip-column-names 2>$null
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

function Get-DbServiceName {
    # The Windows service name of the local database server, if any.
    $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(MariaDB|MySQL)' } |
        Sort-Object @{ Expression = { $_.Status -eq 'Running' }; Descending = $true }, Name | Select-Object -First 1
    if ($svc) { return $svc.Name }
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
    $json = & $TailscaleExe status --json 2>$null
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

function Invoke-Manage([string[]]$Arguments) {
    Push-Location $script:AppDir
    try {
        & $script:VenvPython manage.py @Arguments
        if ($LASTEXITCODE -ne 0) { throw "manage.py $($Arguments -join ' ') failed (exit code $LASTEXITCODE)." }
    } finally { Pop-Location }
}
