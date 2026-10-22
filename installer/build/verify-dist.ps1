<#
.SYNOPSIS
  Verifies a CompuLab build in installer\dist (or a copy of it on a USB
  stick) and writes its distribution manifest.

.DESCRIPTION
      powershell -ExecutionPolicy Bypass -File installer\build\verify-dist.ps1
      powershell -ExecutionPolicy Bypass -File installer\build\verify-dist.ps1 -Dist E:\CompuLab-2026.10.23.1200

  Checks, for the newest version in the folder (or -Version):
    * the three files are there: CompuLab-Server-Setup-<v>.exe,
      CompuLab-Agent-Setup-<v>.exe, CompuLab-Agent-Package-<v>.zip;
    * their SHA-256 hashes match SHA256SUMS-<v>.txt (and the manifest);
    * the Authenticode signature state of the two .exe files (reported as
      it is: "not signed" is expected; a broken signature is an error);
    * the agent zip contains the packaged agent and no settings, per-PC
      file, queue, database, log or test file;
    * BUILDINFO-<v>.json is for this version and was built from a clean
      tree (a commit).
  Exit code 0 = all checks passed.

  -WriteManifest (used by build-installers.ps1) writes
  DISTRIBUTION-MANIFEST-<v>.md. -Rehash, after signing the .exe files with
  signtool, recomputes SHA256SUMS and rewrites the manifest. Nothing here
  signs, unblocks or changes the setup files themselves.
#>
[CmdletBinding()]
param(
    [string]$Dist = '',
    [string]$Version = '',
    [switch]$WriteManifest,
    [switch]$Rehash
)

$ErrorActionPreference = 'Stop'
if (-not $Dist) { $Dist = Join-Path $PSScriptRoot '..\dist' }
$Dist = (Resolve-Path $Dist).Path
$script:problems = @()
function Write-Check([bool]$Ok, [string]$Text) {
    if ($Ok) { Write-Host "    OK: $Text" -ForegroundColor Green } else { Write-Host "    PROBLEM: $Text" -ForegroundColor Red; $script:problems += $Text }
}

if (-not $Version) {
    $newest = Get-ChildItem $Dist -Filter 'SHA256SUMS-*.txt' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No SHA256SUMS-<version>.txt in $Dist." }
    $Version = $newest.BaseName.Substring('SHA256SUMS-'.Length)
}
Write-Host "Verifying CompuLab $Version in $Dist" -ForegroundColor Cyan
$names = [ordered]@{
    "CompuLab-Server-Setup-$Version.exe"   = 'Server setup: run once on the CompuLab server computer'
    "CompuLab-Agent-Setup-$Version.exe"    = 'Lab PC agent setup: run on each lab PC (no Python needed)'
    "CompuLab-Agent-Package-$Version.zip"  = 'The same agent as a zip, for installing with Install CompuLab Agent.cmd'
}
$sumsFile = Join-Path $Dist "SHA256SUMS-$Version.txt"
$infoFile = Join-Path $Dist "BUILDINFO-$Version.json"

# ------------------------------------------------------------ files and hashes
$files = @()
foreach ($n in $names.Keys) {
    $path = Join-Path $Dist $n
    Write-Check (Test-Path $path) "$n present"
    if (Test-Path $path) {
        $item = Get-Item $path
        $files += [pscustomobject]@{ Name = $n; Purpose = $names[$n]; Size = $item.Length; Path = $path
                                     Sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLower(); Signature = '' }
    }
}
if ($Rehash) {
    [IO.File]::WriteAllLines($sumsFile, [string[]]($files | ForEach-Object { "$($_.Sha256)  $($_.Name)" }))
    Write-Host "    Rewrote $(Split-Path $sumsFile -Leaf) from the current files." -ForegroundColor Yellow
    $WriteManifest = $true
}
Write-Check (Test-Path $sumsFile) "$(Split-Path $sumsFile -Leaf) present"
if (Test-Path $sumsFile) {
    $listed = @{}
    foreach ($line in Get-Content $sumsFile) { if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $listed[$Matches[2].Trim()] = $Matches[1].ToLower() } }
    foreach ($f in $files) {
        Write-Check ($listed[$f.Name] -eq $f.Sha256) "$($f.Name) SHA-256 matches SHA256SUMS ($($f.Sha256.Substring(0, 16))...)"
    }
}
$manifestFile = Join-Path $Dist "DISTRIBUTION-MANIFEST-$Version.md"
if ((Test-Path $manifestFile) -and -not $WriteManifest) {
    $m = Get-Content $manifestFile -Raw
    foreach ($f in $files) { Write-Check ($m -match [regex]::Escape($f.Sha256)) "$($f.Name) hash is the one in the manifest" }
}

# ------------------------------------------------------------ signatures (reported, never changed)
foreach ($f in $files | Where-Object { $_.Name -like '*.exe' }) {
    $sig = Get-AuthenticodeSignature $f.Path
    switch ($sig.Status) {
        'Valid'     { $f.Signature = "signed: $($sig.SignerCertificate.Subject)"; Write-Check $true "$($f.Name) is signed ($($sig.SignerCertificate.Subject))" }
        'NotSigned' { $f.Signature = 'not signed'; Write-Host "    NOTE: $($f.Name) is not code-signed: Windows SmartScreen will show 'Unknown publisher'." -ForegroundColor Yellow }
        default     { $f.Signature = "signature problem: $($sig.Status)"; Write-Check $false "$($f.Name) signature state is $($sig.Status) ($($sig.StatusMessage))" }
    }
    $fv = (Get-Item $f.Path).VersionInfo.FileVersion
    Write-Check ($fv -and $Version.StartsWith(($fv -split '[^0-9.]')[0].TrimEnd('.'))) "$($f.Name) file version $fv matches $Version"
}

# ------------------------------------------------------------ agent zip contents
$zipPath = Join-Path $Dist "CompuLab-Agent-Package-$Version.zip"
if (Test-Path $zipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entries = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        foreach ($required in 'agent-bundle/CompuLabAgent.exe', 'agent-bundle/BUILDINFO.json', 'installer/agent/install-agent.ps1', 'Install CompuLab Agent.cmd') {
            Write-Check ($entries -contains $required) "agent zip contains $required"
        }
        $bad = @($entries | Where-Object {
            $leaf = ($_ -split '/')[-1].ToLower()
            $thirdParty = $_ -like 'agent-bundle/_internal/*'
            ($leaf -eq '.env') -or ($leaf -in @('agent_config.local.json', 'pending_callbacks.json', 'agent_status.json', 'self_test.json')) -or
            ($leaf -match '\.(sqlite3?|sql|dump|bak|log|pfx|p12|key)$') -or
            (-not $thirdParty -and ($leaf -eq 'tests.py' -or $leaf -like 'test_*.py' -or $_ -match '(^|/)tests/'))
        })
        Write-Check ($bad.Count -eq 0) "agent zip has no settings, per-PC, queue, database, log or test files$(if ($bad.Count) { ': ' + ($bad -join ', ') })"
        Write-Check (-not ($entries -match '(^|/)python\.exe$')) 'agent zip does not rely on a separate python.exe'
    } finally { $zip.Dispose() }
}

# ------------------------------------------------------------ build record
$info = $null
Write-Check (Test-Path $infoFile) "$(Split-Path $infoFile -Leaf) present"
if (Test-Path $infoFile) {
    $info = Get-Content $infoFile -Raw | ConvertFrom-Json
    Write-Check ($info.version -eq $Version) "build record is for $Version"
    Write-Check ($info.clean_tree -eq $true) "built from a clean tree (commit $($info.commit))"
    $git = Get-Command git -ErrorAction SilentlyContinue
    $repo = Join-Path $PSScriptRoot '..\..'
    if ($git -and (Test-Path (Join-Path $repo '.git'))) {
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            & git -C $repo cat-file -e "$($info.commit)^{commit}" 2>$null
            $known = $LASTEXITCODE -eq 0
            $head = [string](& git -C $repo rev-parse HEAD 2>$null)
        } finally { $ErrorActionPreference = $previous }
        Write-Check $known "commit $($info.commit.Substring(0, 7)) exists in this repository"
        if ($known -and $head -ne $info.commit) { Write-Host "    NOTE: this checkout is at $($head.Substring(0, 7)), the build is from $($info.commit.Substring(0, 7))." -ForegroundColor Yellow }
    }
}

# ------------------------------------------------------------ manifest
if ($WriteManifest) {
    $mb = { param($b) '{0:N1} MB' -f ($b / 1MB) }
    $rows = ($files | ForEach-Object { "| ``$($_.Name)`` | $($_.Purpose) | $($_.Size.ToString('N0')) bytes ($(& $mb $_.Size)) | ``$($_.Sha256)`` | $(if ($_.Signature) { $_.Signature } else { 'n/a (zip)' }) |" }) -join "`r`n"
    $commitText = if ($info) { "$($info.commit) ($($info.branch), committed $($info.commit_date))" } else { 'unknown (BUILDINFO missing)' }
    $treeText = if ($info -and $info.clean_tree) { 'clean (the setups contain exactly that commit)' } else { 'NOT CLEAN - not for distribution' }
    $tools = if ($info) { "Python $($info.tools.python), PyInstaller $($info.tools.pyinstaller), Inno Setup $($info.tools.inno_setup), WinSW $($info.tools.winsw)" } else { 'unknown' }
    $built = if ($info) { $info.built_at_utc } else { 'unknown' }
    $md = @"
# CompuLab $Version - distribution manifest

| | |
|---|---|
| Version | $Version |
| Built (UTC) | $built |
| Source commit | $commitText |
| Working tree | $treeText |
| Build tools | $tools |
| Code signing | **Not code-signed** unless the table below says "signed". |
| Status | Built and tested without administrator rights. The first installation must be **supervised**: the administrator-level checks in ``docs/RELEASE_READINESS.md`` have not been done yet. |

## Files

| File | Purpose | Size | SHA-256 | Signature |
|---|---|---|---|---|
$rows

``SHA256SUMS-$Version.txt`` holds the same hashes; ``BUILDINFO-$Version.json`` the build record (also installed as
``BUILDINFO.json`` next to the program).

### Checking a file before running it

On the computer where it will run (after copying it there):

``````
powershell -Command "Get-FileHash -Algorithm SHA256 'CompuLab-Server-Setup-$Version.exe'"
certutil -hashfile CompuLab-Server-Setup-$Version.exe SHA256
``````

The hash must equal the one above, character for character (upper/lower case does not matter). If it differs, do not run
the file: copy it again from the original source.

## Supported Windows

| | Server setup | Agent setup |
|---|---|---|
| Windows 11 (64-bit, x64) Pro / Education / Enterprise | yes (recommended) | yes |
| Windows 11 Home (x64) | works, not recommended for an always-on server | yes |
| Windows 10 22H2 (64-bit, x64) | works; Windows 10 is out of Microsoft support since 14 Oct 2025 (security updates only with ESU) | yes (same note) |
| Windows Server 2016 / 2019 / 2022 / 2025 (x64) | yes | not intended |
| 32-bit Windows, Windows 8.1 or older | no (the setups refuse to run) | no |
| Windows on ARM (ARM64) | not tested - do not use for the first installation | not tested |

Both setups need Windows PowerShell 5.1 (built into every supported Windows) and an administrator account to install.

## Prerequisites

**Server** - installed by the school before running the server setup (the setup checks them, explains what is missing and
stops; it never installs, upgrades or replaces Python or the database server):

1. **Python 3.13, 64-bit** from python.org ("Windows installer (64-bit)"): *Customize installation*, tick
   *Install Python 3.13 for all users* and *Add Python to environment variables*. 3.12 / 3.11 64-bit are accepted;
   3.14 and 32-bit Python are refused.
2. **MariaDB 11.4 LTS** (or 10.11 LTS; any 10.5+) 64-bit MSI from mariadb.org, *Install as service* ticked, a strong
   root password written down safely - or **MySQL 8.0.11+** (8.4 LTS). XAMPP's MariaDB 10.4 is refused (too old).
3. A **fixed IP address** for the server (DHCP reservation in the router) and its network set to **Private**.

The setup includes everything else: CompuLab, the Python packages (offline) and the service wrapper (WinSW 2.12.0).

**Lab PC agent** - nothing to install first (no Python: the agent is a packaged program). Needed:
the PC's ``agent_config.local.json`` (CompuLab > PC power status > Agent config, with that PC's own agent secret), the PC
registered in CompuLab with its fixed IP, an administrator account to install, and the standard (non-administrator)
Windows account(s) students sign in with - only those get the lock screen (local group "CompuLab Students").

## Installing

1. **Copy the files to the local disk** of the computer (Desktop or Downloads), not a mapped network drive: after
   Windows asks for administrator rights, mapped drive letters are not available.
2. **Check the hash** (above).
3. **Run the setup.** Because the files are not code-signed, Windows SmartScreen shows *Windows protected your PC* with
   *Publisher: Unknown publisher*. Only after the hash matched: *More info* > *Run anyway*. Do not turn SmartScreen or
   the antivirus off. If the school's Group Policy / AppLocker / Smart App Control blocks unsigned programs, the IT
   administrator must allow these exact files (by hash) or sign them with the school's code-signing certificate
   (then run ``installer\build\verify-dist.ps1 -Rehash`` to update the hashes here).
4. **Server:** ``CompuLab-Server-Setup-$Version.exe`` -> campus address and port -> a console window runs the checks and
   the installation (asks for the MariaDB root password and the first Administrator account). Log:
   ``C:\CompuLab\logs\install-<time>.log``. Guide: ``docs\SCHOOL_DEPLOYMENT_GUIDE.md``, ``installer\server\README.md``.
5. **Each lab PC:** put ``CompuLab-Agent-Setup-$Version.exe`` and that PC's ``agent_config.local.json`` side by side, run
   the setup, then sign out and back in. Log: ``C:\ProgramData\CompuLab Agent\install-<time>.log``. Guide:
   ``installer\agent\README.md``.

Silent installs (as administrator):

``````
CompuLab-Server-Setup-$Version.exe /VERYSILENT /SERVERADDRESS=192.168.1.10 /PORT=8000 /DBPORT=3306
    (needs the environment variables COMPULAB_DB_ROOT_PASSWORD, and for a new installation
     DJANGO_SUPERUSER_EMAIL (@gmail.com) and DJANGO_SUPERUSER_PASSWORD for the first Administrator)
CompuLab-Agent-Setup-$Version.exe /VERYSILENT /CONFIG="C:\Setup\PC-01.json" /STUDENTS="student"
``````

**Update / repair:** run a newer (or the same) setup again. Server: settings (.env), database, uploads, backups and logs
are kept, a backup is made before database changes. Agent: the PC's settings and queued events are kept.
**Uninstall:** Settings > Apps. Server data (database, .env, uploads, backups, logs) and the agent's queued events are
kept.
"@
    $md = $md -replace "(?<!`r)`n", "`r`n"
    [IO.File]::WriteAllText($manifestFile, $md, (New-Object Text.UTF8Encoding $false))
    Write-Host "    Wrote $(Split-Path $manifestFile -Leaf)" -ForegroundColor Green
}

if ($script:problems.Count) {
    Write-Host "`n$($script:problems.Count) problem(s): do not distribute these files." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll checks passed for CompuLab $Version." -ForegroundColor Green
exit 0
