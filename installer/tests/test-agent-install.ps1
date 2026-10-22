<#
.SYNOPSIS
  End-to-end test of the lab PC agent installer, without administrator
  rights: everything goes into a temporary folder; no scheduled task,
  firewall rule or C:\ProgramData folder is created.

      powershell -ExecutionPolicy Bypass -File installer\tests\test-agent-install.ps1

  Needs: a build (installer\build\build-installers.ps1) and Inno Setup 6.
  A small stand-in CompuLab server (fake_compulab_server.py) answers the
  agent. The setups and the packaged agent run with a PATH that contains no
  Python (like a fresh lab PC). Checks, using test builds of
  CompuLab-Agent-Setup.exe (version 0.0.0-test, then 0.0.1-test):
    1. silent install with an Agent config file: files, settings, self-test,
       build record, no Python used;
    2. running the setup again keeps the settings and the queued events, and
       so does updating to the newer setup version;
    3. an unusable config file is refused and the installed one is kept;
    4. the packaged CompuLabAgent.exe: self-test with the server down and up,
       and --flush delivers queued events in order, emptying the queue;
    5. set-agent-server.ps1 changes the address and keeps the secret;
    6. agent-status.ps1 reports the queue and the server;
    7. uninstall removes the program and keeps the queued events;
    8. a plain folder copy installs in Python mode (agent.py + its own venv).
#>
[CmdletBinding()]
param([string]$IsccPath = '', [switch]$KeepFiles, [switch]$SkipPythonMode)

$ErrorActionPreference = 'Continue'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Payload = Join-Path $Repo 'installer\build\work\agent-payload'
$Tmp = Join-Path $env:TEMP ("compulab-agent-install-test-" + (Get-Date -Format 'HHmmss'))
$AgentDir = Join-Path $Tmp 'Agent'
$DataDir = Join-Path $Tmp 'Data'
$script:passed = 0; $script:failed = @()
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
    catch { $script:failed += $Name; Write-Host "  [FAIL] $Name`n         $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-FreePort { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); return $p }
function Read-Json([string]$Path) { return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }

if (-not (Test-Path (Join-Path $Payload 'agent-bundle\CompuLabAgent.exe'))) { throw "No staged agent payload in ${Payload}: run installer\build\build-installers.ps1 first." }
$iscc = @($IsccPath, (Join-Path $Repo 'installer\build\tools\InnoSetup6\ISCC.exe'), "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
          "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 not found.' }
$py = Join-Path $Repo 'venv\Scripts\python.exe'
if (-not (Test-Path $py)) { $py = 'python' }
New-Item -ItemType Directory -Force $Tmp, $DataDir | Out-Null
Write-Host "Test folder: $Tmp"

$servers = @{}
function Start-FakeServer([string]$Name) {
    $port = Get-FreePort
    $log = Join-Path $Tmp "$Name-events.jsonl"
    $p = Start-Process $py -ArgumentList "`"$PSScriptRoot\fake_compulab_server.py`"", $port, "`"$log`"" -PassThru -WindowStyle Hidden
    foreach ($i in 1..30) { try { if ((Invoke-WebRequest "http://127.0.0.1:$port/healthz" -UseBasicParsing -TimeoutSec 2).Content -eq 'ok') { break } } catch { Start-Sleep -Milliseconds 300 } }
    $servers[$Name] = @{ Proc = $p; Url = "http://127.0.0.1:$port"; Log = $log }
    return $servers[$Name]
}
function Stop-FakeServer([string]$Name) { if ($servers[$Name]) { Stop-Process -Id $servers[$Name].Proc.Id -Force -ErrorAction SilentlyContinue } }
# A fresh lab PC has no Python: the setups and the packaged agent run with
# only Windows' own folders on PATH (py.exe lives in C:\Windows, left out).
$NoPythonPath = "$env:SystemRoot\System32;$env:SystemRoot\System32\Wbem;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
function Invoke-WithoutPython([scriptblock]$Body) {
    $oldPath = $env:PATH; $oldHome = $env:PYTHONHOME; $oldPyPath = $env:PYTHONPATH
    $env:PATH = $NoPythonPath; $env:PYTHONHOME = $null; $env:PYTHONPATH = $null
    try { & $Body } finally { $env:PATH = $oldPath; $env:PYTHONHOME = $oldHome; $env:PYTHONPATH = $oldPyPath }
}
function Invoke-AgentExe([string[]]$Arguments) {
    $old = $env:COMPULAB_AGENT_DATA_DIR; $env:COMPULAB_AGENT_DATA_DIR = $DataDir
    try { return Invoke-WithoutPython { (Start-Process (Join-Path $AgentDir 'CompuLabAgent.exe') -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden).ExitCode } }
    finally { $env:COMPULAB_AGENT_DATA_DIR = $old }
}
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{3A9E5C1F-7B2D-4E8A-B6C4-91D0F2E77E57}_is1'   # test build AppId
function New-QueueItem([string]$Id, [string]$Secret) {
    return @{ path = '/labs/api/pc-agent-end-session/'; queued_at = [double]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 30)
              body = @{ reason = 'manual'; secret = $Secret; event_id = $Id; agent_version = 'test' } }
}

try {
    $builds = @{}
    foreach ($v in '0.0.0', '0.0.1') {
        $out = Join-Path $Tmp "out-$v"
        & $iscc /Q /DTestBuild "/DPayload=$Payload" "/DAppVersion=$v-test" "/DFileVersion=$v.1" "/DOutputDir=$out" (Join-Path $Repo 'installer\build\CompuLab-Agent.iss') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Compiling the agent test build $v failed." }
        $builds[$v] = (Get-ChildItem $out -Filter '*.exe' | Select-Object -First 1).FullName
    }
    $setup = $builds['0.0.0']
    # No quotes: they would reach install-agent.ps1 literally (the test folder has no spaces).
    $psArgs = "-InstallDir $AgentDir -DataDir $DataDir -SkipFirewall -SkipTask"
    function Invoke-Setup([string]$Log, [string]$Config = '') {
        $a = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$AgentDir`"", "/PSARGS=`"$psArgs`"", "/LOG=`"$Log`"")
        if ($Config) { $a += "/CONFIG=`"$Config`"" }
        Invoke-WithoutPython { Start-Process $setup -ArgumentList $a -Wait | Out-Null }
        return (Get-Content $Log -Raw) -notmatch 'install-agent.ps1 failed'
    }

    $a = Start-FakeServer 'A'
    $secret = 'test-secret-' + [guid]::NewGuid().ToString('N')
    $cfg = Join-Path $Tmp 'pc-01.json'
    [IO.File]::WriteAllText($cfg, (@{ secret = $secret; server_url = $a.Url; port = 5555; pc_name = 'PC 01'; lab_name = 'Lab 1' } | ConvertTo-Json))

    Write-Host "`n1. Silent install with the PC's Agent config" -ForegroundColor Cyan
    $ok = Invoke-Setup (Join-Path $Tmp 'setup-1.log') $cfg
    Test-Case 'setup succeeded; packaged agent, tools and settings installed' {
        Assert-True $ok 'install-agent.ps1 failed (see the logs in the data folder)'
        foreach ($f in 'CompuLabAgent.exe', '_internal', 'agent_config.json', 'tools\agent-status.ps1', 'tools\set-agent-server.ps1', 'tools\uninstall-agent.ps1', 'uninstall') {
            Assert-True (Test-Path (Join-Path $AgentDir $f)) "missing $f"
        }
        $c = Read-Json (Join-Path $AgentDir 'agent_config.local.json')
        Assert-True ($c.secret -eq $secret -and $c.server_url -eq $a.Url -and $c.pc_name -eq 'PC 01') 'settings not copied'
    }
    Test-Case 'self-test after install: settings read, queue writable, server answers' {
        $log = Get-ChildItem $DataDir -Filter 'install-*.log' | Sort-Object Name | Select-Object -Last 1
        $t = Get-Content $log.FullName -Raw
        Assert-True ($t -match 'starts, reads its settings and can write its queue; server: answers') 'self-test line missing'
        Assert-True ($t -notmatch [regex]::Escape($secret)) 'the secret appears in the install log'
    }
    Test-Case 'installed and self-tested with no Python on the PATH (packaged agent, no Python check)' {
        Assert-True (-not (Invoke-WithoutPython { Get-Command python.exe, python3.exe, py.exe -ErrorAction SilentlyContinue })) 'the test PATH still finds a Python'
        $log = Get-ChildItem $DataDir -Filter 'install-*.log' | Sort-Object Name | Select-Object -Last 1
        $t = Get-Content $log.FullName -Raw
        Assert-True ($t -match 'Packaged agent \(no Python needed\)') 'not installed in packaged mode'
        Assert-True ($t -notmatch 'OK: Python \d') 'the installer looked for Python'
        Assert-True (Test-Path (Join-Path $AgentDir '_internal\python3*.dll')) 'the bundle does not carry its own Python runtime'
        Assert-True (-not (Test-Path (Join-Path $AgentDir 'venv'))) 'a Python environment was created'
    }
    Test-Case 'build record installed next to the agent' {
        $b = Read-Json (Join-Path $AgentDir 'BUILDINFO.json')
        Assert-True ($b.commit -match '^[0-9a-f]{40}$' -and $b.version) "BUILDINFO: $($b | ConvertTo-Json -Compress)"
    }
    Test-Case 'lab users can read but not change the agent settings' {
        $rules = (Get-Acl (Join-Path $AgentDir 'agent_config.local.json')).Access | Where-Object { $_.IdentityReference.Value -match 'Users$' }
        Assert-True ($rules) 'no rule for Users'
        Assert-True (-not ($rules | Where-Object { $_.FileSystemRights -match 'Write|Modify|FullControl' })) 'Users may write the settings'
    }

    Write-Host "`n2. Running the setup again keeps settings and queued events" -ForegroundColor Cyan
    $queue = Join-Path $DataDir 'pending_callbacks.json'
    [IO.File]::WriteAllText($queue, (ConvertTo-Json -Depth 5 @((New-QueueItem 'evt-001' $secret), (New-QueueItem 'evt-002' $secret))))
    $cfgHash = (Get-FileHash (Join-Path $AgentDir 'agent_config.local.json')).Hash
    $ok = Invoke-Setup (Join-Path $Tmp 'setup-2.log')
    Test-Case 'repair without a config file: settings unchanged, 2 queued events kept' {
        Assert-True $ok 'repair failed'
        Assert-True ((Get-FileHash (Join-Path $AgentDir 'agent_config.local.json')).Hash -eq $cfgHash) 'settings changed'
        Assert-True (@(Read-Json $queue).Count -eq 2) 'queue lost'
        $log = Get-ChildItem $DataDir -Filter 'install-*.log' | Sort-Object Name | Select-Object -Last 1
        Assert-True ((Get-Content $log.FullName -Raw) -match '2 queued event\(s\) kept') 'install log does not mention the queue'
    }
    $setup = $builds['0.0.1']
    $ok = Invoke-Setup (Join-Path $Tmp 'setup-update.log')
    Test-Case 'update 0.0.0 -> 0.0.1 without a config file: settings unchanged, 2 queued events kept, new version registered' {
        Assert-True $ok 'update failed'
        Assert-True ((Get-FileHash (Join-Path $AgentDir 'agent_config.local.json')).Hash -eq $cfgHash) 'settings changed by the update'
        Assert-True (@(Read-Json $queue).Count -eq 2) 'queue lost by the update'
        Assert-True ((Get-ItemProperty $UninstallKey -ErrorAction SilentlyContinue).DisplayVersion -eq '0.0.1-test') 'Apps list still shows the old version'
        Assert-True (Test-Path (Join-Path $AgentDir 'CompuLabAgent.exe')) 'program missing after update'
    }

    Write-Host "`n3. An unusable config file is refused" -ForegroundColor Cyan
    $bad = Join-Path $Tmp 'placeholder.json'
    Copy-Item (Join-Path $Repo 'installer\agent\agent_config.local.sample.json') $bad
    $ok = Invoke-Setup (Join-Path $Tmp 'setup-3.log') $bad
    Test-Case 'placeholder secret: setup reports failure, installed settings kept' {
        Assert-True (-not $ok) 'placeholder config accepted'
        Assert-True ((Get-FileHash (Join-Path $AgentDir 'agent_config.local.json')).Hash -eq $cfgHash) 'installed settings overwritten'
        $log = Get-ChildItem $DataDir -Filter 'install-*.log' | Sort-Object Name | Select-Object -Last 1
        Assert-True ((Get-Content $log.FullName -Raw) -match 'secret is missing or still a placeholder') 'unclear message'
    }

    Write-Host "`n4. The packaged CompuLabAgent.exe" -ForegroundColor Cyan
    Test-Case 'self-test with the server down: settings OK, server reported unreachable, exit code 0' {
        Stop-FakeServer 'A'; Start-Sleep 1
        $r = Join-Path $Tmp 'selftest-down.json'
        $code = Invoke-AgentExe @('--self-test', "`"$r`"")
        $j = Read-Json $r
        Assert-True ($code -eq 0 -and $j.config_ok -and $j.frozen -and -not $j.server_reachable) "exit $code, $($j | ConvertTo-Json -Compress)"
        Assert-True ($j.pending_events -eq 2) "pending $($j.pending_events)"
    }
    Test-Case '--flush while the server is down keeps the queue (exit code 2)' {
        $code = Invoke-AgentExe @('--flush')
        Assert-True ($code -eq 2) "exit $code"
        Assert-True (@(Read-Json $queue).Count -eq 2) 'events lost while offline'
        $s = Read-Json (Join-Path $DataDir 'agent_status.json')
        Assert-True (-not $s.server_reachable) 'status says reachable'
    }
    Test-Case 'server back: --flush delivers both events in order and empties the queue' {
        $back = Start-FakeServer 'A2'
        $c = Read-Json (Join-Path $AgentDir 'agent_config.local.json')
        # The PC's settings point at server A; point them at the restarted one.
        $c.server_url = $back.Url
        [IO.File]::WriteAllText((Join-Path $AgentDir 'agent_config.local.json'), ($c | ConvertTo-Json))
        $code = Invoke-AgentExe @('--flush')
        Assert-True ($code -eq 0) "exit $code"
        $events = @(Get-Content $back.Log | ForEach-Object { ($_ | ConvertFrom-Json).body.event_id })
        Assert-True (($events -join ',') -eq 'evt-001,evt-002') "delivered: $($events -join ',')"
        Assert-True (@(Read-Json $queue).Count -eq 0) 'queue not emptied'
        Assert-True ((Read-Json (Join-Path $DataDir 'agent_status.json')).server_reachable) 'status not updated'
    }

    Write-Host "`n5-6. Changing the server address; status" -ForegroundColor Cyan
    $b = Start-FakeServer 'B'
    Test-Case 'set-agent-server.ps1 changes the address and keeps the secret' {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AgentDir 'tools\set-agent-server.ps1') -InstallDir $AgentDir -ServerUrl $b.Url -SkipFirewall *> (Join-Path $Tmp 'set-server.log')
        $c = Read-Json (Join-Path $AgentDir 'agent_config.local.json')
        Assert-True ($c.server_url -eq $b.Url -and $c.secret -eq $secret) "url $($c.server_url)"
    }
    Test-Case 'set-agent-server.ps1 refuses an address that does not answer (unless -Force)' {
        $dead = "http://127.0.0.1:$(Get-FreePort)"
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AgentDir 'tools\set-agent-server.ps1') -InstallDir $AgentDir -ServerUrl $dead -SkipFirewall 2>&1 | Out-String
        Assert-True ((Read-Json (Join-Path $AgentDir 'agent_config.local.json')).server_url -eq $b.Url) 'address changed anyway'
        Assert-True ($o -match 'does not answer') 'no explanation'
    }
    Test-Case 'agent-status.ps1 shows the address, the queue and a live check' {
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AgentDir 'tools\agent-status.ps1') -InstallDir $AgentDir -DataDir $DataDir 2>&1 | Out-String
        Assert-True ($o -match [regex]::Escape($b.Url) -and $o -match 'Queued events\s+: 0' -and $o -match 'server answers') $o
    }

    Write-Host "`n7. Uninstall" -ForegroundColor Cyan
    [IO.File]::WriteAllText($queue, (ConvertTo-Json -Depth 5 @(New-QueueItem 'evt-keep' $secret)))
    Test-Case 'uninstall removes the program and keeps queued events' {
        $unins = Get-ChildItem (Join-Path $AgentDir 'uninstall') -Filter 'unins*.exe' | Select-Object -First 1
        Start-Process $unins.FullName -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
        foreach ($i in 1..30) { if (-not (Test-Path (Join-Path $AgentDir 'CompuLabAgent.exe'))) { break }; Start-Sleep 1 }
        Assert-True (-not (Test-Path (Join-Path $AgentDir 'CompuLabAgent.exe'))) 'program still there'
        Assert-True (@(Read-Json $queue).Count -eq 1) 'queued events deleted'
    }

    if (-not $SkipPythonMode) {
        Write-Host "`n8. Plain folder copy (Python mode)" -ForegroundColor Cyan
        $pyDir = Join-Path $Tmp 'AgentPy'
        Test-Case 'install-agent.ps1 from the source folder: own venv, agent.py, self-test passes' {
            $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'installer\agent\install-agent.ps1') -NonInteractive `
                -ConfigFile $cfg -ServerUrl $b.Url -InstallDir $pyDir -DataDir $DataDir -SourceDir (Join-Path $Repo 'lab_pc_agent') -SkipFirewall -SkipTask 2>&1 | Out-String
            Assert-True ($LASTEXITCODE -eq 0) ($o -split "`n" | Select-String 'stopped|FAIL|Error' | Select-Object -First 3 | Out-String)
            foreach ($f in 'agent.py', 'hardening.py', 'venv\Scripts\pythonw.exe') { Assert-True (Test-Path (Join-Path $pyDir $f)) "missing $f" }
            Assert-True (-not (Test-Path (Join-Path $pyDir 'tests'))) 'test files copied'
            Assert-True ($o -match 'server: answers') 'self-test did not reach the server'
        }
    }
} finally {
    foreach ($n in @($servers.Keys)) { Stop-FakeServer $n }
    Get-Process CompuLabAgent, pythonw -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Tmp*" } | Stop-Process -Force
    if (-not $KeepFiles -and -not $script:failed.Count) { Start-Sleep 2; Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host "`n$($script:passed) passed, $($script:failed.Count) failed" -ForegroundColor $(if ($script:failed.Count) { 'Red' } else { 'Green' })
if ($KeepFiles -or $script:failed.Count) { Write-Host "Test files: $Tmp" }
exit [int]($script:failed.Count -gt 0)
