<#
.SYNOPSIS
  Builds CompuLab-Server-Setup-<version>.exe and CompuLab-Agent-Setup-<version>.exe
  into installer\dist\.

.DESCRIPTION
  Run on a developer PC (no administrator rights needed), from the CompuLab folder:

      powershell -ExecutionPolicy Bypass -File installer\build\build-installers.ps1 -InstallInnoSetup

  Needs internet (packages, WinSW) and:
    * Python 3.13 from python.org (py -3.13) - builds the agent .exe;
    * Inno Setup 6 (ISCC.exe). -InstallInnoSetup downloads the official,
      signed installer from GitHub and installs it for the current user into
      installer\build\tools\InnoSetup6 (checks the Authenticode signature).

  Steps:
    1. A build Python environment (installer\build\.venv) with PyInstaller,
       Pillow and uiautomation.
    2. lab_pc_agent\agent.py -> CompuLabAgent.exe (windowed, one folder), so
       lab PCs need no Python; a --self-test run checks the packaged program.
    3. Server payload: every file git tracks (never .env, databases, logs or
       anything in .gitignore) except the developer tests, plus
       WinSW-x64.exe v2.12.0 (SHA-256 checked) and the Python packages for
       Python 3.11-3.13 (offline install on the server).
    4. Agent payload: the packaged agent plus installer\agent.
    5. Both payloads are scanned: no .env, database, dump, log, queue file,
       per-PC agent config, test module or value of this PC's .env /
       agent_config.local.json secrets may be in them (the build stops).
    6. Inno Setup compiles both setups. installer\dist then holds:
         SHA256SUMS-<version>.txt              hashes of the setups and the zip
         BUILDINFO-<version>.json              commit, tools, file list
         DISTRIBUTION-MANIFEST-<version>.md    files, sizes, hashes, supported
                                               Windows, install steps
       and installer\build\verify-dist.ps1 checks them.

  The build refuses uncommitted changes (the setups must match a commit);
  -AllowDirty overrides that for a local experiment and marks the build
  "dirty" in BUILDINFO and the manifest.

  The setups are not code-signed (no certificate): Windows SmartScreen shows
  "Windows protected your PC / Unknown publisher". To sign them, run signtool
  on the two .exe files with the college's code-signing certificate, then
  verify-dist.ps1 -Rehash to update the hashes and the manifest.
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$IsccPath = '',
    [switch]$InstallInnoSetup,
    [switch]$SkipWheels,
    [switch]$AllowDirty
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
function Write-Step([string]$t) { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Write-Ok([string]$t) { Write-Host "    OK: $t" -ForegroundColor Green }
function Invoke-Tool([string]$Exe, [string[]]$Arguments, [string]$What) {
    # Runs a build tool, sending its output (much of it on stderr, which
    # PowerShell 5.1 would treat as an error) to installer\build\work\build.log;
    # only the exit code decides success.
    $log = Join-Path $Work 'build.log'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @Arguments *>> $log } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { throw "$What failed (exit code $LASTEXITCODE); see $log" }
}

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Build = $PSScriptRoot
$Work = Join-Path $Build 'work'
$Dist = Join-Path $Repo 'installer\dist'
$Tools = Join-Path $Build 'tools'
$WinSWUrl = 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe'
# SHA-256 of WinSW-x64.exe v2.12.0 (unsigned upstream), recorded at the first
# download on 2026-10-22; the build stops if the download ever differs.
$WinSWSha256 = '05B82D46AD331CC16BDC00DE5C6332C1EF818DF8CEEFCD49C726553209B3A0DA'
$InnoUrl = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe'

function Invoke-Git([string[]]$Arguments) {
    # git prints warnings (e.g. line endings) on stderr: not an error here.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & git -C $Repo @Arguments 2>$null } finally { $ErrorActionPreference = $previous }
}

if (-not $Version) { $Version = Get-Date -Format 'yyyy.M.d.HHmm' }
$fileVersion = ($Version -split '[^0-9.]')[0]
$commit = [string](Invoke-Git @('rev-parse', 'HEAD'))
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'This is not a git checkout of CompuLab: the setups are built from git (the commit is recorded in them).' }
$branch = [string](Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD'))
$changes = @(Invoke-Git @('status', '--porcelain', '--untracked-files=all') | Where-Object { $_ })
$dirty = $changes.Count -gt 0
if ($dirty -and -not $AllowDirty) {
    throw ("Uncommitted changes ($($changes.Count) file(s), e.g. $(($changes | Select-Object -First 3) -join '; ')). " +
           'Commit them first so the setups match a commit, or pass -AllowDirty for a local experiment.')
}
Write-Host "Building CompuLab setups $Version (commit $($commit.Substring(0, 7)) on $branch$(if ($dirty) { ', WITH UNCOMMITTED CHANGES' }))" -ForegroundColor Cyan
if (Test-Path $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
New-Item -ItemType Directory -Force $Work, $Dist | Out-Null

# ------------------------------------------------------------ 0. Inno Setup
Write-Step 'Finding Inno Setup'
$candidates = @($IsccPath, (Join-Path $Tools 'InnoSetup6\ISCC.exe'), "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
                "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { $_ }
$iscc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc -and $InstallInnoSetup) {
    $dl = Join-Path $Tools 'download'
    New-Item -ItemType Directory -Force $dl | Out-Null
    $setup = Join-Path $dl 'innosetup-6.7.3.exe'
    Invoke-WebRequest $InnoUrl -OutFile $setup -UseBasicParsing
    $sig = Get-AuthenticodeSignature $setup
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Pyrsys') { throw "The Inno Setup download is not signed by its publisher ($($sig.Status)); not running it." }
    $p = Start-Process $setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', '/NOICONS', "/DIR=`"$(Join-Path $Tools 'InnoSetup6')`"" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Installing Inno Setup failed (exit code $($p.ExitCode))." }
    $iscc = Join-Path $Tools 'InnoSetup6\ISCC.exe'
}
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) was not found. Run again with -InstallInnoSetup, or pass -IsccPath.' }
Write-Ok $iscc

# ------------------------------------------------------------ 1. build Python
Write-Step 'Preparing the build Python environment'
$venv = Join-Path $Build '.venv'
$py = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $py)) {
    Invoke-Tool 'py' @('-3.13', '-m', 'venv', $venv) 'Creating the build environment (needs Python 3.13 from python.org: py -3.13)'
}
Invoke-Tool $py @('-m', 'pip', 'install', '--disable-pip-version-check', 'pyinstaller>=6.10,<7', '-r', (Join-Path $Repo 'lab_pc_agent\requirements.txt')) 'Installing PyInstaller and the agent packages'
$buildPython = [string](& $py -c 'import sys; print(sys.version.split()[0])')
$pyInstallerVersion = [string](& $py -c 'import PyInstaller; print(PyInstaller.__version__)')
Write-Ok "Python $buildPython, PyInstaller $pyInstallerVersion"

# ------------------------------------------------------------ 2. agent .exe
Write-Step 'Packaging the lab PC agent (CompuLabAgent.exe)'
$agentSrc = Join-Path $Repo 'lab_pc_agent'
Invoke-Tool $py @('-m', 'PyInstaller', '--noconfirm', '--clean', '--windowed', '--name', 'CompuLabAgent',
    '--distpath', (Join-Path $Work 'pyi-dist'), '--workpath', (Join-Path $Work 'pyi-build'), '--specpath', $Work,
    '--paths', $agentSrc, '--hidden-import', 'hardening', '--collect-all', 'uiautomation', (Join-Path $agentSrc 'agent.py')) 'PyInstaller'
$bundle = Join-Path $Work 'pyi-dist\CompuLabAgent'
if (-not (Test-Path (Join-Path $bundle 'CompuLabAgent.exe'))) { throw 'PyInstaller did not produce CompuLabAgent.exe.' }
foreach ($item in 'agent_config.json', 'manual_unlock.html', 'README.md', 'assets') {
    $src = Join-Path $agentSrc $item
    if (Test-Path $src) { Copy-Item $src $bundle -Recurse -Force }
}
# Smoke test: the packaged program starts and writes a self-test report
# (the configuration error is expected: there is no agent_config.local.json).
$report = Join-Path $Work 'agent-selftest.json'
$env:COMPULAB_AGENT_DATA_DIR = Join-Path $Work 'agent-selftest-data'
try {
    $p = Start-Process (Join-Path $bundle 'CompuLabAgent.exe') -ArgumentList '--self-test', "`"$report`"" -Wait -PassThru -WindowStyle Hidden
} finally { Remove-Item Env:\COMPULAB_AGENT_DATA_DIR }
if (-not (Test-Path $report)) { throw "The packaged agent did not run (exit code $($p.ExitCode))." }
$r = Get-Content $report -Raw | ConvertFrom-Json
if (-not $r.frozen -or -not $r.data_dir_writable) { throw 'The packaged agent self-test report is wrong.' }
Write-Ok "CompuLabAgent.exe $($r.agent_version) runs (self-test without settings: '$($r.config_error)')"

# ------------------------------------------------------------ 3. server payload
Write-Step 'Staging the server payload'
$serverPayload = Join-Path $Work 'server-payload'
$files = Invoke-Git @('ls-files', '--cached', '--others', '--exclude-standard')
# Build tooling, git metadata and the developer tests (Django tests.py /
# test_*.py, tests\ folders, lab_pc_agent\test_url.py) stay out of the setup.
$skip = '^(installer/build/|installer/dist/|\.git)|(^|/)tests/|(^|/)tests\.py$|(^|/)test_[^/]*\.py$'
$count = 0; $skipped = 0
foreach ($rel in $files) {
    if ($rel -match $skip) { $skipped++; continue }
    $src = Join-Path $Repo $rel
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }   # deleted in the working tree
    $dst = Join-Path $serverPayload $rel
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath $src $dst
    $count++
}
$bin = Join-Path $serverPayload 'installer\server\bin'
New-Item -ItemType Directory -Force $bin | Out-Null
$winsw = Join-Path $bin 'WinSW-x64.exe'
Invoke-WebRequest $WinSWUrl -OutFile $winsw -UseBasicParsing
$hash = (Get-FileHash $winsw -Algorithm SHA256).Hash
if ($hash -ne $WinSWSha256) { throw "WinSW-x64.exe has an unexpected SHA-256 ($hash); not packaging it." }
Write-Ok "$count application files ($skipped build/test files left out) + WinSW-x64.exe 2.12.0 (SHA-256 verified)"

if (-not $SkipWheels) {
    $wheels = Join-Path $serverPayload 'installer\server\wheels'
    $req = Join-Path $Repo 'installer\server\requirements-server.txt'
    foreach ($pv in '3.11', '3.12', '3.13') {
        try {
            Invoke-Tool $py @('-m', 'pip', 'download', '--disable-pip-version-check', '--only-binary=:all:', '--platform', 'win_amd64',
                '--python-version', $pv, '--implementation', 'cp', '-r', $req, '--dest', $wheels) "Downloading packages for Python $pv"
        } catch { Write-Host "    Python $pv packages incomplete: a server with that Python downloads them during install instead." -ForegroundColor Yellow }
    }
    Write-Ok "$(@(Get-ChildItem $wheels -Filter *.whl).Count) Python packages for offline installation"
}

# ------------------------------------------------------------ 4. agent payload
Write-Step 'Staging the agent payload'
$agentPayload = Join-Path $Work 'agent-payload'
Copy-Item $bundle (Join-Path $agentPayload 'agent-bundle') -Recurse
$agentScripts = Join-Path $agentPayload 'installer\agent'
New-Item -ItemType Directory -Force $agentScripts | Out-Null
Get-ChildItem (Join-Path $Repo 'installer\agent\*') -Include '*.ps1', '*.cmd', '*.json', '*.md' | Copy-Item -Destination $agentScripts
Copy-Item (Join-Path $Repo 'Install CompuLab Agent.cmd') $agentPayload

# ------------------------------------------------------------ 5. contents check + build record
Write-Step 'Checking the payloads (no secrets, data, logs or tests)'
function Get-LocalSecretValues {
    # Values of this PC's real secrets, to prove none was packaged. Never printed.
    $values = @()
    $envFile = Join-Path $Repo '.env'
    $placeholders = @()
    $example = Join-Path $Repo '.env.example'
    if (Test-Path $example) { $placeholders = @(Get-Content $example | ForEach-Object { if ($_ -match '^\s*[A-Za-z_]+\s*=\s*(.*)$') { $Matches[1].Trim() } }) }
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { continue }
            $key = $Matches[1]; $v = $Matches[2].Trim().Trim('"').Trim("'")
            if ($key -match 'SECRET|PASSWORD|API_KEY|TOKEN' -and $v.Length -ge 8 -and $placeholders -notcontains $v) { $values += $v }
        }
    }
    $agentLocal = Join-Path $Repo 'lab_pc_agent\agent_config.local.json'
    if (Test-Path $agentLocal) {
        try { $s = [string](Get-Content $agentLocal -Raw | ConvertFrom-Json).secret; if ($s.Length -ge 8) { $values += $s } } catch { }
    }
    return ,@($values | Select-Object -Unique)
}
function Find-PayloadProblems([string]$Root, [string[]]$SecretValues) {
    # Everything that must never be in a setup. Third-party files inside the
    # packaged agent (agent-bundle\_internal) are exempt from the folder and
    # test-file rules only.
    $problems = @()
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force) {
        $rel = $item.FullName.Substring($Root.Length + 1).Replace('\', '/')
        $thirdParty = $rel -like 'agent-bundle/_internal/*'
        if ($item.PSIsContainer) {
            if (-not $thirdParty -and $item.Name -in @('.git', 'venv', '.venv', '__pycache__', 'media', 'logs', 'backups', 'staticfiles', 'service')) { $problems += "folder $rel" }
            continue
        }
        $n = $item.Name.ToLower()
        if ($n -eq '.env' -or ($n -like '.env.*' -and $n -ne '.env.example')) { $problems += "settings file $rel" }
        elseif ($n -in @('agent_config.local.json', 'pending_callbacks.json', 'agent_status.json', 'self_test.json')) { $problems += "per-PC file $rel" }
        elseif ($item.Extension -in @('.sqlite3', '.sqlite', '.sql', '.dump', '.bak', '.log', '.pfx', '.p12', '.key')) { $problems += "data/log/key file $rel" }
        elseif (-not $thirdParty -and ($n -eq 'tests.py' -or $n -like 'test_*.py' -or $rel -match '(^|/)tests/')) { $problems += "test file $rel" }
        if ($SecretValues.Count -and $item.Extension -ne '.whl' -and $item.Length -lt 64MB) {
            $text = $latin1.GetString([IO.File]::ReadAllBytes($item.FullName))
            foreach ($s in $SecretValues) { if ($text.IndexOf($s, [StringComparison]::Ordinal) -ge 0) { $problems += "a secret from this PC's .env / agent config is inside $rel"; break } }
        }
    }
    return ,$problems
}
$secretValues = Get-LocalSecretValues
foreach ($payloadRoot in $serverPayload, $agentPayload) {
    $problems = Find-PayloadProblems $payloadRoot $secretValues
    if ($problems.Count) { throw "Refusing to package $(Split-Path $payloadRoot -Leaf):`n  - $(($problems | Select-Object -First 20) -join "`n  - ")" }
}
Write-Ok "No settings, secrets ($($secretValues.Count) local value(s) checked), databases, logs, per-PC files or tests in either payload"

$isccVersion = (Get-Item $iscc).VersionInfo.ProductVersion
$commitDate = [string](Invoke-Git @('log', '-1', '--format=%cI'))
$buildInfo = [ordered]@{
    product = 'CompuLab'; version = $Version; commit = $commit; branch = $branch; commit_date = $commitDate
    clean_tree = (-not $dirty); built_at_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    tools = [ordered]@{ python = $buildPython; pyinstaller = $pyInstallerVersion; inno_setup = $isccVersion; winsw = "2.12.0 (SHA-256 $WinSWSha256)" }
    code_signed = $false
    payload_files = [ordered]@{ server = @(Get-ChildItem $serverPayload -Recurse -File).Count; agent = @(Get-ChildItem $agentPayload -Recurse -File).Count }
}
$buildInfoJson = $buildInfo | ConvertTo-Json -Depth 5
$utf8 = New-Object Text.UTF8Encoding $false
# Installed with the program: C:\CompuLab\BUILDINFO.json and C:\Program Files\CompuLab Agent\BUILDINFO.json.
[IO.File]::WriteAllText((Join-Path $serverPayload 'BUILDINFO.json'), $buildInfoJson, $utf8)
[IO.File]::WriteAllText((Join-Path $agentPayload 'agent-bundle\BUILDINFO.json'), $buildInfoJson, $utf8)
Write-Ok "Build record: commit $($commit.Substring(0, 7)), $(if ($dirty) { 'UNCOMMITTED CHANGES' } else { 'clean tree' })"

# Only the newest build is kept in installer\dist (each is ~75 MB). The
# previous one is removed only now that every check has passed.
Get-ChildItem $Dist -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'CompuLab-*' -or $_.Name -like 'SHA256SUMS-*' -or $_.Name -like 'BUILDINFO-*' -or $_.Name -like 'DISTRIBUTION-MANIFEST-*' } | Remove-Item -Force

# The same files as a zip, for installing from a USB stick without the .exe.
$zip = Join-Path $Dist "CompuLab-Agent-Package-$Version.zip"
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($attempt in 1..5) {
    # Antivirus scanners briefly open freshly copied files: retry.
    if (Test-Path $zip) { Remove-Item $zip -Force }
    try { [IO.Compression.ZipFile]::CreateFromDirectory($agentPayload, $zip); break }
    catch { if ($attempt -eq 5) { throw }; Start-Sleep -Seconds 5 }
}
Write-Ok 'Packaged agent + installer scripts'

# ------------------------------------------------------------ 6. compile
Write-Step 'Compiling the setups with Inno Setup'
foreach ($pair in @(@('CompuLab-Server.iss', $serverPayload), @('CompuLab-Agent.iss', $agentPayload))) {
    Invoke-Tool $iscc @('/Q', "/DPayload=$($pair[1])", "/DAppVersion=$Version", "/DFileVersion=$fileVersion", "/DOutputDir=$Dist",
        (Join-Path $Build $pair[0])) "Inno Setup ($($pair[0]))"
}
$outputs = Get-ChildItem $Dist -File | Where-Object { $_.Name -like 'CompuLab-*' -and $_.Name -like "*$Version*" }
$sums = $outputs | ForEach-Object { "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())  $($_.Name)" }
[IO.File]::WriteAllLines((Join-Path $Dist "SHA256SUMS-$Version.txt"), [string[]]$sums)
[IO.File]::WriteAllText((Join-Path $Dist "BUILDINFO-$Version.json"), $buildInfoJson, $utf8)

# ------------------------------------------------------------ 7. manifest + verification
Write-Step 'Writing the distribution manifest and verifying the files'
& (Join-Path $Build 'verify-dist.ps1') -Dist $Dist -Version $Version -WriteManifest
if ($LASTEXITCODE -ne 0) { throw 'verify-dist.ps1 found a problem with the built files (see above).' }
Write-Host "`nBuilt in $($Dist):" -ForegroundColor Green
Get-ChildItem $Dist -File | Where-Object { $_.Name -like "*$Version*" } | ForEach-Object { Write-Host ("  {0,-52} {1,8:N1} MB" -f $_.Name, ($_.Length / 1MB)) }
if ($dirty) { Write-Host '  Built WITH UNCOMMITTED CHANGES (-AllowDirty): not for distribution.' -ForegroundColor Yellow }
