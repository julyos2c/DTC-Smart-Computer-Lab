# Shared helpers for the lab PC agent scripts. Dot-source it:
#   . "$PSScriptRoot\agent-common.ps1"
# Works with Windows PowerShell 5.1 (built into Windows 10/11).
# The pure functions (config validation, launch command, task and firewall
# definitions) are covered by installer\tests\test-installer-logic.ps1.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:AgentTaskName = 'CompuLab Agent'
$script:AgentExeName = 'CompuLabAgent.exe'
# Windows accounts in this local group get the lock screen at sign-in;
# everyone else (administrators, IT staff) does not.
$script:StudentGroupName = 'CompuLab Students'
$script:UsersGroupSid = 'S-1-5-32-545'           # BUILTIN\Users: every account (older installs)
$script:AdministratorsGroupSid = 'S-1-5-32-544'
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
    if ($script:RejectedSecrets -contains $secret) { $problems += 'secret is missing or still a placeholder: download the PC''s Agent config from CompuLab (PC power status > Agent config).' }
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
    foreach ($spec in Get-AgentFirewallRuleSpecs $serverIps $AgentPort) { New-NetFirewallRule @spec | Out-Null }
    Write-Ok "Port $AgentPort and ping accept the CompuLab server ($($serverIps -join ', ')) only"
}

function New-AgentTaskDefinition([string]$InstallDir, [string]$GroupSid) {
    # The parts of the "CompuLab Agent" task, without registering anything
    # (installer\tests\test-installer-logic.ps1 checks them without admin rights).
    # Starts the lock screen when a member of $GroupSid signs in to Windows
    # (also after a restart): normally the "CompuLab Students" group, so
    # administrators and IT staff are never locked; S-1-5-32-545 (Users) =
    # every account (installations from before the group existed).
    # A logon task, not a service: the lock screen must run in the signed-in
    # user's desktop. A logon trigger cannot "restart the program when it
    # exits", so the trigger repeats every minute while the user is signed in:
    # with MultipleInstances IgnoreNew a repeat does nothing while the agent
    # runs, and brings it back within about a minute if it was closed or crashed.
    $launch = Get-AgentLaunch $InstallDir
    $action = if ($launch.Args) { New-ScheduledTaskAction -Execute $launch.Exe -Argument $launch.Args -WorkingDirectory $InstallDir }
              else { New-ScheduledTaskAction -Execute $launch.Exe -WorkingDirectory $InstallDir }
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $taskPrincipal = New-ScheduledTaskPrincipal -GroupId $GroupSid -RunLevel Limited
    # No duration = repeat for as long as the user is signed in.
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)).Repetition
    $trigger.Repetition.StopAtDurationEnd = $false
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    return @{ Action = $action; Trigger = $trigger; Principal = $taskPrincipal; Settings = $taskSettings }
}

function Register-AgentTask([string]$InstallDir, [string]$GroupSid) {
    $definition = New-AgentTaskDefinition $InstallDir $GroupSid
    Register-ScheduledTask -TaskName $script:AgentTaskName @definition -Force | Out-Null
}

# ---------------------------------------------------------------- who gets the lock screen
function ConvertTo-AccountList([string[]]$Text) {
    # "student1, LAB\student2; student3" -> 'student1', 'LAB\student2', 'student3'
    # (a plain list: callers wrap it in @() - nothing for an empty list).
    $Text | ForEach-Object { "$_" -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
}

function Get-ExistingAgentScope {
    # How the installed "CompuLab Agent" task decides who is locked:
    # @{ Kind = 'StudentGroup' | 'AllUsers' | 'SingleUser' | 'None'; Account }.
    $task = Get-ScheduledTask -TaskName $script:AgentTaskName -ErrorAction SilentlyContinue
    if (-not $task) { return @{ Kind = 'None'; Account = '' } }
    $p = $task.Principal
    if ($p.GroupId) {
        $sid = "$($p.GroupId)"
        try { if ($sid -notmatch '^S-1-') { $sid = (New-Object Security.Principal.NTAccount($p.GroupId)).Translate([Security.Principal.SecurityIdentifier]).Value } } catch { }
        if ($sid -eq $script:UsersGroupSid) { return @{ Kind = 'AllUsers'; Account = '' } }
        return @{ Kind = 'StudentGroup'; Account = "$($p.GroupId)" }
    }
    if ($p.UserId) { return @{ Kind = 'SingleUser'; Account = "$($p.UserId)" } }
    return @{ Kind = 'None'; Account = '' }
}

function Resolve-AgentScope([switch]$AllUsers, [string[]]$StudentAccounts, $Existing) {
    # Decides who gets the lock screen. Pure (tested):
    #   -AllUsers                     -> every Windows account (administrators too)
    #   student accounts given        -> the CompuLab Students group (those added)
    #   repair/update, nothing given  -> whatever the installed task does now,
    #                                    so an update never silently locks or
    #                                    unlocks different accounts
    #   new installation              -> the CompuLab Students group
    # Returns @{ Scope = 'StudentGroup' | 'AllUsers'; AddAccounts; Reason }.
    $accounts = @(ConvertTo-AccountList $StudentAccounts)
    if ($AllUsers) { return @{ Scope = 'AllUsers'; AddAccounts = @(); Reason = 'requested (-AllUsers): every Windows account, administrators included' } }
    if ($accounts.Count) { return @{ Scope = 'StudentGroup'; AddAccounts = $accounts; Reason = 'student accounts given' } }
    switch ("$($Existing.Kind)") {
        'StudentGroup' { return @{ Scope = 'StudentGroup'; AddAccounts = @(); Reason = 'kept from the installed agent' } }
        'AllUsers'     { return @{ Scope = 'AllUsers'; AddAccounts = @(); Reason = 'kept from the installed agent (older setting: every account, administrators included)' } }
        'SingleUser'   { return @{ Scope = 'StudentGroup'; AddAccounts = @($Existing.Account); Reason = "the installed agent's single student account $($Existing.Account) moves into the group" } }
    }
    return @{ Scope = 'StudentGroup'; AddAccounts = @(); Reason = 'new installation' }
}

function Get-StudentAccountProblems([string[]]$Accounts, [string[]]$KnownAccounts, [string[]]$AdminAccounts) {
    # What is wrong with the student accounts to add (empty = fine). Pure:
    # the caller passes the accounts that exist and the administrators'.
    # Names are compared without the computer/domain part when that part is
    # this computer.
    $short = { param($n) $n = "$n".Trim(); if ($n -match '^(\.|' + [regex]::Escape($env:COMPUTERNAME) + ')\\(.+)$') { $Matches[2] } else { $n } }
    $known = @($KnownAccounts | ForEach-Object { (& $short $_).ToLower() })
    $admins = @($AdminAccounts | ForEach-Object { (& $short $_).ToLower() })
    $problems = @()
    foreach ($a in $Accounts) {
        $n = (& $short $a).ToLower()
        if ($known -notcontains $n) { $problems += "Windows account '$a' does not exist on this PC (Settings > Accounts > Other users)." }
        elseif ($admins -contains $n) { $problems += "'$a' is an administrator account: students must use a standard account, and administrators are never given the lock screen." }
    }
    return ,$problems
}

# The three below return plain lists: callers wrap them in @().
function Get-LocalAccountNames {
    # Local accounts plus domain accounts already known to this PC's groups.
    $names = @(Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $names += @(Get-LocalGroupMember -SID $script:UsersGroupSid -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $names | Select-Object -Unique
}

function Get-AdministratorAccountNames {
    Get-LocalGroupMember -SID $script:AdministratorsGroupSid -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
}

function Get-StudentGroupMembers {
    if (-not (Get-LocalGroup -Name $script:StudentGroupName -ErrorAction SilentlyContinue)) { return }
    Get-LocalGroupMember -Group $script:StudentGroupName -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
}

function Initialize-StudentGroup([string[]]$Accounts) {
    # Creates the "CompuLab Students" group if needed, adds $Accounts, and
    # returns the group's SID (for the task) and its members.
    $group = Get-LocalGroup -Name $script:StudentGroupName -ErrorAction SilentlyContinue
    if (-not $group) {
        $group = New-LocalGroup -Name $script:StudentGroupName -Description 'Windows accounts that get the CompuLab lock screen at sign-in (CompuLab Agent). Never add administrators.'
        Write-Ok "Created the local group '$($script:StudentGroupName)'"
    }
    $members = @(Get-StudentGroupMembers)
    foreach ($a in $Accounts) {
        $already = @($members | Where-Object { $_ -ieq $a -or $_ -like "*\$a" }).Count -gt 0
        if (-not $already) { Add-LocalGroupMember -Group $script:StudentGroupName -Member $a; Write-Ok "Added $a to '$($script:StudentGroupName)'" }
    }
    return @{ Sid = $group.SID.Value; Members = @(Get-StudentGroupMembers) }
}

function Get-AgentFirewallRuleSpecs([string[]]$ServerIps, [int]$AgentPort = 5555) {
    # Parameters for New-NetFirewallRule (checked by the tests with -WhatIf).
    return @(
        @{ DisplayName = 'CompuLab Agent'; Direction = 'Inbound'; Protocol = 'TCP'; LocalPort = $AgentPort
           RemoteAddress = $ServerIps; Action = 'Allow'; Profile = 'Any' },
        @{ DisplayName = 'CompuLab ping'; Direction = 'Inbound'; Protocol = 'ICMPv4'; IcmpType = 8
           RemoteAddress = $ServerIps; Action = 'Allow'; Profile = 'Any' }
    )
}
