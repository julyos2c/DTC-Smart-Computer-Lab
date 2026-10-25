<#
.SYNOPSIS
  Stages TEST payloads from the current working tree (including uncommitted
  changes) into a temporary folder, for the end-to-end installer tests. It
  is not a release build and never touches installer\dist.

      powershell -ExecutionPolicy Bypass -File installer\tests\stage-test-payload.ps1
      powershell -ExecutionPolicy Bypass -File installer\tests\test-server-install.ps1 -Payload <printed>\server-payload
      powershell -ExecutionPolicy Bypass -File installer\tests\test-agent-install.ps1 -Payload <printed>\agent-payload

  Reuses the parts of the last build (installer\build\work) that do not come
  from git: WinSW-x64.exe, the offline Python packages and the packaged
  CompuLabAgent.exe bundle. If lab_pc_agent\agent.py changed since that
  build, the packaged agent is out of date: the script says so and stops
  (a real build is needed then). Prints the folder; delete it afterwards.
#>
[CmdletBinding()]
param([string]$Out = '',
      # The work folder of the build to take WinSW, packages, the packaged
      # agent and (with -WithRuntime) runtime\ from (build-installers.ps1 -WorkDir).
      [string]$Built = '',
      # Also copy the bundled runtime (runtime\python, runtime\mariadb): a
      # payload for CompuLab's own database (test-server-bundled.ps1).
      [switch]$WithRuntime)

$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Built) { $Built = Join-Path $Repo 'installer\build\work' }
if (-not (Test-Path (Join-Path $Built 'server-payload\installer\server\bin\WinSW-x64.exe'))) { throw 'No previous build in installer\build\work: run installer\build\build-installers.ps1 once.' }
if (-not $Out) { $Out = Join-Path $env:TEMP ('compulab-test-payload-' + (Get-Date -Format 'HHmmss')) }
function Invoke-Git([string[]]$Arguments) {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $Repo @Arguments 2>$null } finally { $ErrorActionPreference = $previous }
}

# The packaged agent must still match agent.py.
$builtInfo = Get-Content (Join-Path $Built 'server-payload\BUILDINFO.json') -Raw | ConvertFrom-Json
$agentChanged = @(Invoke-Git @('diff', '--name-only', $builtInfo.commit, '--', 'lab_pc_agent/agent.py', 'lab_pc_agent/hardening.py')) + @(Invoke-Git @('status', '--porcelain', '--', 'lab_pc_agent/agent.py', 'lab_pc_agent/hardening.py'))
if (@($agentChanged | Where-Object { $_ }).Count) { throw "lab_pc_agent changed since build $($builtInfo.commit.Substring(0, 7)): the packaged agent is out of date. Run a real build." }

$server = Join-Path $Out 'server-payload'
$agent = Join-Path $Out 'agent-payload'
New-Item -ItemType Directory -Force $server, $agent | Out-Null

# Server: the working tree (same rules as build-installers.ps1) + WinSW + wheels.
$skip = '^(installer/build/|installer/dist/|\.git)|(^|/)tests/|(^|/)tests\.py$|(^|/)test_[^/]*\.py$'
$count = 0
foreach ($rel in Invoke-Git @('ls-files', '--cached', '--others', '--exclude-standard')) {
    if ($rel -match $skip) { continue }
    $src = Join-Path $Repo $rel
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
    $dst = Join-Path $server $rel
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item -LiteralPath $src $dst
    $count++
}
foreach ($rel in 'installer\server\bin', 'installer\server\wheels') {
    # The contents (bin\ already exists: README.txt is in git).
    New-Item -ItemType Directory -Force (Join-Path $server $rel) | Out-Null
    Copy-Item (Join-Path $Built "server-payload\$rel\*") (Join-Path $server $rel) -Recurse -Force
}
if ($WithRuntime) {
    $rt = Join-Path $Built 'server-payload\runtime'
    if (-not (Test-Path (Join-Path $rt 'mariadb\bin\mariadbd.exe'))) { throw "No bundled runtime in ${rt}: build once with the current build-installers.ps1 (it bundles runtime\)." }
    Copy-Item $rt (Join-Path $server 'runtime') -Recurse
}
$head = [string](Invoke-Git @('rev-parse', 'HEAD'))
$info = [ordered]@{ product = 'CompuLab'; version = 'test-payload'; commit = $head; clean_tree = $false
                    note = 'TEST payload staged from the working tree by installer\tests\stage-test-payload.ps1 - not a release' }
$json = $info | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $server 'BUILDINFO.json'), $json, (New-Object Text.UTF8Encoding $false))

# Agent: the packaged agent of the last build + the current installer\agent scripts.
Copy-Item (Join-Path $Built 'agent-payload\agent-bundle') (Join-Path $agent 'agent-bundle') -Recurse
[IO.File]::WriteAllText((Join-Path $agent 'agent-bundle\BUILDINFO.json'), $json, (New-Object Text.UTF8Encoding $false))
$scripts = Join-Path $agent 'installer\agent'
New-Item -ItemType Directory -Force $scripts | Out-Null
Get-ChildItem (Join-Path $Repo 'installer\agent\*') -Include '*.ps1', '*.cmd', '*.json', '*.md' | Copy-Item -Destination $scripts
Copy-Item (Join-Path $Repo 'Install CompuLab Agent.cmd') $agent

Write-Host "Staged $count working-tree files (+ WinSW, packages, packaged agent$(if ($WithRuntime) { ', bundled runtime' }) from build $($builtInfo.commit.Substring(0, 7)))"
$Out
