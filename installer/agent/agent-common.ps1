# Shared helpers for the lab PC agent scripts. Dot-source it:
#   . "$PSScriptRoot\agent-common.ps1"
# Works with Windows PowerShell 5.1 (built into Windows 10/11).
# The pure functions (config validation, launch command) are covered by
# installer\tests\Installer.Tests.ps1.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:AgentTaskName = 'CompuLab Agent'
$script:AgentExeName = 'CompuLabAgent.exe'
# Same list as REJECTED_SECRETS in lab_pc_agent\agent.py: placeholders and a
# secret published in the project's history are never accepted.
$script:RejectedSecrets = @('', 'SET-IN-agent_config.local.json', 'danao_technological_college', 'PASTE-PC_AGENT_SHARED_SECRET-HERE')

function Write-Step([string]$t) { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Write-Ok([string]$t) { Write-Host "    OK: $t" -ForegroundColor Green }
function Write-Note([string]$t) { Write-Host "    $t" -ForegroundColor Yellow }

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Quiet([string]$Exe, [string[]]$Arguments) {
    # Runs a program and returns its standard output, ignoring its stderr
    # (Windows PowerShell 5.1 turns redirected stderr into a fatal error
    # under ErrorActionPreference 'Stop'). $LASTEXITCODE is set as usual.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @Arguments 2>$null } finally { $ErrorActionPreference = $previous }
}

function Assert-Admin {
    if (-not (Test-IsAdmin)) {
        throw 'Please run this as Administrator (right-click PowerShell > Run as administrator, or use the .cmd launcher, which asks for it).'
    }
}

function Stop-Agent([string]$InstallDir) {
    Get-ScheduledTask -TaskName $script:AgentTaskName -ErrorAction SilentlyContinue | Stop-ScheduledTask -ErrorAction SilentlyContinue
    Get-Process pythonw, python, CompuLabAgent -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$InstallDir*" } | Stop-Process -Force
}

function Test-ServerUrlFormat([string]$Url) {
    $Url = "$Url".Trim().TrimEnd('/')
    if ($Url -notmatch '^https?://[A-Za-z0-9.\-]+(:\d{1,5})?$') {
        throw "'$Url' is not a server address. Use the form http://192.168.1.10:8000 (the campus address shown on CompuLab's System status page)."
    }
    return $Url
}

function Read-AgentConfig([string]$Path) {
    return (Get-Content $Path -Raw -Encoding UTF8) | ConvertFrom-Json
}

function Write-AgentConfig([string]$Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

function Get-AgentConfigProblems($Config) {
    # What is wrong with an agent_config.local.json (empty list = usable).
    $problems = @()
    if (-not $Config) { return ,@('The configuration is empty.') }
    $secret = [string]$Config.secret
    if ($script:RejectedSecrets -contains $secret) { $problems += 'secret is missing or still a placeholder: download the PC''s Agent config from CompuLab (PC status > Agent config).' }
    elseif ($secret.Length -lt 16) { $problems += 'secret is too short to be the server''s PC_AGENT_SHARED_SECRET.' }
    try { Test-ServerUrlFormat ([string]$Config.server_url) | Out-Null } catch { $problems += "server_url: $($_.Exception.Message)" }
    if ($Config.PSObject.Properties.Name -contains 'port') {
        $p = 0
        if (-not [int]::TryParse([string]$Config.port, [ref]$p) -or $p -lt 1 -or $p -gt 65535) { $problems += "port must be 1-65535 (got '$($Config.port)')." }
    }
    return ,$problems
}

function Set-AgentServerUrl([string]$Path, [string]$Url) {
    $config = Read-AgentConfig $Path
    if ($config.PSObject.Properties.Name -contains 'server_url') { $config.server_url = $Url }
    else { $config | Add-Member -NotePropertyName server_url -NotePropertyValue $Url }
    Write-AgentConfig $Path $config
}

function Protect-AgentConfig([string]$Path) {
    # Administrators, SYSTEM and the (administrator) account running the
    # installer may change it; the lab users may only read it.
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls $Path /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' "*$($me):F" '*S-1-5-32-545:R' | Out-Null
}

function Get-AgentLaunch([string]$InstallDir) {
    # The packaged CompuLabAgent.exe needs no Python; a plain folder copy runs
    # agent.py with the agent's own Python environment.
    $exe = Join-Path $InstallDir $script:AgentExeName
    if (Test-Path $exe) { return @{ Exe = $exe; Args = ''; Packaged = $true } }
    return @{ Exe = (Join-Path $InstallDir 'venv\Scripts\pythonw.exe'); Args = "`"$(Join-Path $InstallDir 'agent.py')`""; Packaged = $false }
}

function Invoke-AgentSelfTest([string]$InstallDir, [string]$DataDir) {
    # Runs `--self-test` with the installed agent; returns its JSON report.
    $launch = Get-AgentLaunch $InstallDir
    $report = Join-Path $env:TEMP ("compulab-agent-selftest-" + [guid]::NewGuid().ToString('N') + '.json')
    $exe = if ($launch.Packaged) { $launch.Exe } else { Join-Path $InstallDir 'venv\Scripts\python.exe' }
    $argList = @()
    if (-not $launch.Packaged) { $argList += "`"$(Join-Path $InstallDir 'agent.py')`"" }
    $argList += @('--self-test', "`"$report`"")
    $oldData = $env:COMPULAB_AGENT_DATA_DIR
    $env:COMPULAB_AGENT_DATA_DIR = $DataDir
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $InstallDir -Wait -PassThru -WindowStyle Hidden
        if (-not (Test-Path $report)) { return @{ ok = $false; config_error = "the agent did not run (exit code $($p.ExitCode))" } }
        $json = Get-Content $report -Raw | ConvertFrom-Json
        $result = @{}
        foreach ($prop in $json.PSObject.Properties) { $result[$prop.Name] = $prop.Value }
        return $result
    } finally {
        $env:COMPULAB_AGENT_DATA_DIR = $oldData
        Remove-Item $report -Force -ErrorAction SilentlyContinue
    }
}

function Get-QueuedEventCount([string]$DataDir) {
    # Events waiting in pending_callbacks.json. (Assign before counting:
    # Windows PowerShell 5.1's ConvertFrom-Json emits an array as ONE object.)
    $file = Join-Path $DataDir 'pending_callbacks.json'
    if (-not (Test-Path $file)) { return 0 }
    try { $items = Get-Content $file -Raw | ConvertFrom-Json } catch { return 0 }
    if ($null -eq $items) { return 0 }
    return @($items).Count
}

function Get-ResponseText($Response) {
    # Invoke-WebRequest gives bytes instead of text when the server sends no
    # Content-Type (e.g. some proxies).
    if ($Response.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($Response.Content) }
    return [string]$Response.Content
}

function Test-CompuLabServer([string]$Url) {
    # @{ Ok; Detail } - does CompuLab answer /healthz at this address?
    try {
        $r = Invoke-WebRequest -Uri ($Url.TrimEnd('/') + '/healthz') -UseBasicParsing -TimeoutSec 8
        if ((Get-ResponseText $r).Trim() -eq 'ok') { return @{ Ok = $true; Detail = 'answers' } }
        return @{ Ok = $false; Detail = 'something answered, but it is not CompuLab (wrong address or port?)' }
    } catch {
        return @{ Ok = $false; Detail = "$($_.Exception.Message) - a campus network or server problem (the internet is not involved)" }
    }
}

function Set-AgentFirewall([string]$ServerUrl, [int]$AgentPort = 5555) {
    # Only the CompuLab server may send lock/unlock commands (port) and ping.
    $serverHost = ([Uri]$ServerUrl).Host
    $serverIps = @()
    try { $serverIps = @([Net.Dns]::GetHostAddresses($serverHost) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }) } catch { }
    Get-NetFirewallRule -DisplayName 'CompuLab Agent', 'CompuLab ping' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (-not $serverIps.Count) {
        Write-Note "Could not resolve $serverHost; firewall rules not created. Run set-agent-server.ps1 again when the server is reachable."
        return
    }
    New-NetFirewallRule -DisplayName 'CompuLab Agent' -Direction Inbound -Protocol TCP -LocalPort $AgentPort `
        -RemoteAddress $serverIps -Action Allow -Profile Any | Out-Null
    New-NetFirewallRule -DisplayName 'CompuLab ping' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 `
        -RemoteAddress $serverIps -Action Allow -Profile Any | Out-Null
    Write-Ok "Port $AgentPort and ping accept the CompuLab server ($($serverIps -join ', ')) only"
}

function Register-AgentTask([string]$InstallDir, [string]$LabUser) {
    # Starts the lock screen at every Windows sign-in (also after a restart)
    # and restarts it within a minute if it stops. A logon task, not a
    # service: the lock screen must run in the signed-in user's desktop.
    $launch = Get-AgentLaunch $InstallDir
    $action = if ($launch.Args) { New-ScheduledTaskAction -Execute $launch.Exe -Argument $launch.Args -WorkingDirectory $InstallDir }
              else { New-ScheduledTaskAction -Execute $launch.Exe -WorkingDirectory $InstallDir }
    if ($LabUser) {
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $LabUser
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId $LabUser -LogonType Interactive -RunLevel Limited
    } else {
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $taskPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited   # BUILTIN\Users
    }
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $script:AgentTaskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
}
