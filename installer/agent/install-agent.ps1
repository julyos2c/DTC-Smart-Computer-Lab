<#
.SYNOPSIS
  Installs, updates or repairs the CompuLab lock-screen agent on one lab PC.

.DESCRIPTION
  Easiest: run CompuLab-Agent-Setup.exe on the PC (it contains everything,
  no Python needed). From a CompuLab folder copy (USB stick or share),
  double-click "Install CompuLab Agent.cmd", or as Administrator:

      powershell -ExecutionPolicy Bypass -File installer\agent\install-agent.ps1 -ConfigFile E:\agent_config.local.json

  Get -ConfigFile from CompuLab: PC power status > (this PC's row) > "Agent config"
  (it contains the server address, the agent secret and this PC's name).
  Without it, the script asks for the server address and secret. -ServerUrl
  overrides the address in either case. Safe to run again (repair/update):
  the settings and the queued events are kept.

  What it does:
    1. Checks Windows, the settings (before changing anything) and - only
       for a plain folder copy - Python 3.11+.
    2. Copies the agent to C:\Program Files\CompuLab Agent (the packaged
       CompuLabAgent.exe, or agent.py with its own Python environment).
    3. Writes agent_config.local.json (Administrators may change it; the lab
       user account can only read it).
    4. Creates C:\ProgramData\CompuLab Agent for queued events and the
       last-contact status, kept across updates and uninstalls.
    5. Checks that the CompuLab server answers. If it does not, the install
       continues with a warning: the agent keeps trying by itself.
    6. Opens port 5555 (and ping) for the CompuLab server's IP address only.
    7. Starts the agent when a STUDENT account signs in to Windows (so also
       after a restart) and brings it back within about a minute if it stops.
       Student accounts are the members of the local group "CompuLab
       Students" (created here; -StudentAccounts adds accounts to it).
       Administrators are never added, so their sessions are not locked.
       A repair/update keeps whatever the installed agent did; -AllUsers
       locks every account (administrators too: the old behaviour).
    8. Runs the installed agent's self-test.
  Everything shown is also written to C:\ProgramData\CompuLab Agent\install-<time>.log.

  There is no automatic server discovery: the address comes from the
  Agent config file or -ServerUrl and must be the server's fixed address.
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = '',
    [string]$ServerUrl = '',
    [string]$InstallDir = "$env:ProgramFiles\CompuLab Agent",
    # The running agent always uses C:\ProgramData\CompuLab Agent; change
    # -DataDir / -InstallDir only for isolated tests (installer\tests).
    [string]$DataDir = "$env:ProgramData\CompuLab Agent",
    [string]$SourceDir = '',
    # Windows account(s) students sign in with, comma-separated (local or
    # DOMAIN\name); added to the "CompuLab Students" group. Never administrators.
    [string]$StudentAccounts = '',
    [string]$LabUser = '',           # older name for a single -StudentAccounts entry
    # Lock every Windows account, administrators included (old behaviour).
    [switch]$AllUsers,
    [int]$AgentPort = 0,
    [switch]$NonInteractive,
    # Keep the window open at the end (used by CompuLab-Agent-Setup.exe).
    [switch]$PauseAtEnd,
    [switch]$SkipFirewall,
    [switch]$SkipTask
)

. "$PSScriptRoot\agent-common.ps1"
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
$logPath = Join-Path $DataDir ("install-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
try { Start-Transcript -Path $logPath -Force | Out-Null } catch { $logPath = $null }
$exitCode = 0
try {
    if (-not ($SkipFirewall -and $SkipTask)) { Assert-Admin }

    # ------------------------------------------------------------ 1. checks
    Write-Step 'Checking Windows and the agent files'
    if ([Environment]::OSVersion.Version.Major -lt 10) { throw 'Windows 10 or 11 is required.' }
    if (-not $SourceDir) {
        $bundle = Join-Path $PSScriptRoot '..\..\agent-bundle'
        $SourceDir = if (Test-Path (Join-Path $bundle $script:AgentExeName)) { $bundle } else { Join-Path $PSScriptRoot '..\..\lab_pc_agent' }
    }
    $SourceDir = (Resolve-Path $SourceDir).Path
    $packaged = Test-Path (Join-Path $SourceDir $script:AgentExeName)
    if (-not $packaged -and -not (Test-Path (Join-Path $SourceDir 'agent.py'))) { throw "No agent found in $SourceDir (expected CompuLabAgent.exe or agent.py)." }
    Write-Ok $(if ($packaged) { "Packaged agent (no Python needed): $SourceDir" } else { "Agent source folder: $SourceDir" })

    $python = $null
    if (-not $packaged) {
        foreach ($candidate in @(@('py', '-3.13'), @('py', '-3.12'), @('py', '-3.11'), @('python'))) {
            try {
                # No double quotes in -c code: Windows PowerShell 5.1 drops them.
                $v = Invoke-Quiet $candidate[0] (@($candidate | Select-Object -Skip 1) + @('-c', 'import sys, tkinter; print(*sys.version_info[:2], sep=chr(46))'))
                if ($LASTEXITCODE -eq 0 -and $v -match '^\d+\.\d+$' -and [version]$v -ge [version]'3.11') { $python = $candidate; break }
            } catch { }
        }
        if (-not $python) { throw 'Python 3.11+ (with tkinter, the default) was not found. Install it from python.org for all users, or use CompuLab-Agent-Setup.exe, which needs no Python.' }
        Write-Ok "Python $v"
    }

    # ------------------------------------------------------------ 2. settings (validated before any change)
    Write-Step 'Checking this PC''s agent settings'
    $localConfig = Join-Path $InstallDir 'agent_config.local.json'
    $config = $null
    if ($ConfigFile) { $config = Read-AgentConfig $ConfigFile }
    elseif (Test-Path $localConfig) { $config = Read-AgentConfig $localConfig; Write-Ok 'Keeping the settings already on this PC' }
    elseif ($NonInteractive) { throw 'No settings: pass -ConfigFile (PC power status > Agent config in CompuLab).' }
    else {
        if (-not $ServerUrl) { $ServerUrl = Read-Host 'CompuLab server campus address (e.g. http://192.168.1.10:8000)' }
        $secretSecure = Read-Host -AsSecureString 'Agent secret (PC_AGENT_SHARED_SECRET from the server''s .env)'
        $secret = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSecure))
        $config = [pscustomobject]@{ secret = $secret; server_url = ''; port = 5555 }
        $secret = $null
    }
    if ($ServerUrl) {
        $url = Test-ServerUrlFormat $ServerUrl
        if ($config.PSObject.Properties.Name -contains 'server_url') { $config.server_url = $url } else { $config | Add-Member -NotePropertyName server_url -NotePropertyValue $url }
    }
    if ($config.PSObject.Properties.Name -contains 'server_url') { $config.server_url = ([string]$config.server_url).TrimEnd('/') }
    if ($AgentPort -gt 0) {
        if ($config.PSObject.Properties.Name -contains 'port') { $config.port = $AgentPort } else { $config | Add-Member -NotePropertyName port -NotePropertyValue $AgentPort }
    }
    $problems = Get-AgentConfigProblems $config
    if ($problems.Count) { throw ("The agent settings are not usable:`n      - " + ($problems -join "`n      - ")) }
    $port = if ($config.port) { [int]$config.port } else { 5555 }
    Write-Ok "Server: $($config.server_url), agent port $port"

    # Who gets the lock screen - decided and checked before anything changes.
    $scope = $null
    if (-not $SkipTask) {
        Write-Step 'Checking which Windows accounts get the lock screen'
        $scope = Resolve-AgentScope -AllUsers:$AllUsers -StudentAccounts @($StudentAccounts, $LabUser) -Existing (Get-ExistingAgentScope)
        if ($scope.Scope -eq 'StudentGroup') {
            $known = @(Get-LocalAccountNames)
            $admins = @(Get-AdministratorAccountNames)
            $current = @(Get-StudentGroupMembers)
            if (-not $current.Count -and -not $scope.AddAccounts.Count) {
                if ($NonInteractive) {
                    throw ("No student account given: the lock screen would start for nobody. Enter the Windows account(s) students sign in with " +
                           "(setup: 'Student Windows accounts', or -StudentAccounts student1,student2), or add them to the local group '$($script:StudentGroupName)'.")
                }
                $candidates = @(Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.Enabled } | ForEach-Object { $_.Name } |
                    Where-Object { (Get-StudentAccountProblems @($_) $known $admins).Count -eq 0 })
                Write-Host "    Standard (non-administrator) accounts on this PC: $(if ($candidates.Count) { $candidates -join ', ' } else { '(none - create one first: Settings > Accounts > Other users)' })"
                $scope.AddAccounts = @(ConvertTo-AccountList (Read-Host '    Windows account(s) students sign in with (comma-separated)'))
                if (-not $scope.AddAccounts.Count) { throw 'No student account given: the lock screen would start for nobody.' }
            }
            $accountProblems = Get-StudentAccountProblems $scope.AddAccounts $known $admins
            if ($accountProblems.Count) { throw ("The student accounts are not usable:`n      - " + ($accountProblems -join "`n      - ")) }
            $memberProblems = Get-StudentAccountProblems $current $known $admins
            $adminMembers = @($memberProblems | Where-Object { $_ -match 'administrator account' })
            foreach ($m in $adminMembers) { Write-Note "In the group '$($script:StudentGroupName)': $m Remove it from the group (Computer Management > Local Users and Groups)." }
            Write-Ok "Lock screen for the members of '$($script:StudentGroupName)' ($($scope.Reason)); administrators are not locked"
        } else {
            Write-Note "Lock screen for EVERY Windows account on this PC, administrators included ($($scope.Reason))."
            Write-Note "To lock only students: run the setup again with the student account(s) (setup field 'Student Windows accounts', or -StudentAccounts)."
        }
    }

    # ------------------------------------------------------------ 3. files
    Write-Step "Installing the agent in $InstallDir"
    Stop-Agent $InstallDir
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    if ((Resolve-Path $InstallDir).Path -ne $SourceDir) {
        if ($packaged) { Remove-Item (Join-Path $InstallDir '_internal') -Recurse -Force -ErrorAction SilentlyContinue }
        Get-ChildItem $SourceDir -Exclude 'agent_config.local.json', 'pending_callbacks.json*', 'agent_status.json*', '__pycache__', 'test_url.py', 'tests', 'venv' |
            Copy-Item -Destination $InstallDir -Recurse -Force
    }
    $toolsDir = Join-Path $InstallDir 'tools'
    New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
    Get-ChildItem (Join-Path $PSScriptRoot '*') -Include '*.ps1', '*.cmd' | Copy-Item -Destination $toolsDir -Force
    if (-not $packaged) {
        if (-not (Test-Path "$InstallDir\venv\Scripts\pythonw.exe")) {
            & $python[0] @($python | Select-Object -Skip 1) -m venv "$InstallDir\venv"
            if ($LASTEXITCODE -ne 0) { throw 'Could not create the agent''s Python environment.' }
        }
        Invoke-Quiet "$InstallDir\venv\Scripts\python.exe" @('-m', 'pip', 'install', '--disable-pip-version-check', '--no-warn-script-location', '--quiet', '-r', "$InstallDir\requirements.txt") | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Note 'Optional packages (Pillow, uiautomation) did not install (no internet?): the agent still works, with a plainer lock screen.' }
    }
    Write-AgentConfig $localConfig $config
    Protect-AgentConfig $localConfig
    Write-Ok 'Agent files and settings installed'

    # ------------------------------------------------------------ 4. data folder
    Write-Step 'Preparing the agent data folder'
    # Every Windows user on this PC may write here (the lock screen runs as
    # whoever signs in); nothing secret is stored in it.
    & icacls $DataDir /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
    Write-Ok "$DataDir ($(Get-QueuedEventCount $DataDir) queued event(s) kept)"

    # ------------------------------------------------------------ 5. server check
    Write-Step 'Checking the CompuLab server'
    $check = Test-CompuLabServer $config.server_url
    if ($check.Ok) { Write-Ok "Server answers at $($config.server_url)" }
    else {
        Write-Note "Could not reach $($config.server_url) right now: $($check.Detail)"
        Write-Note 'Installation continues. The agent keeps trying by itself; check later with tools\agent-status.ps1.'
    }

    # ------------------------------------------------------------ 6. firewall
    if (-not $SkipFirewall) {
        Write-Step 'Firewall'
        Set-AgentFirewall $config.server_url $port
    }

    # ------------------------------------------------------------ 7. auto-start
    if (-not $SkipTask) {
        Write-Step 'Starting the agent when a student signs in'
        if ($scope.Scope -eq 'StudentGroup') {
            $group = Initialize-StudentGroup $scope.AddAccounts
            Register-AgentTask $InstallDir $group.Sid
            Write-Ok "Scheduled task `"$($script:AgentTaskName)`" registered for '$($script:StudentGroupName)': $($group.Members -join ', ') (starts at sign-in, also after a restart; back within about a minute if closed)"
            Write-Note 'Accounts added just now get the lock screen from their next sign-in.'
        } else {
            Register-AgentTask $InstallDir $script:UsersGroupSid
            Write-Ok "Scheduled task `"$($script:AgentTaskName)`" registered for every Windows account (starts at sign-in, also after a restart)"
        }
    }

    # ------------------------------------------------------------ 8. self-test
    Write-Step 'Testing the installed agent'
    $report = Invoke-AgentSelfTest $InstallDir $DataDir
    if (-not $report.ok) { throw "The installed agent's self-test failed: $($report.config_error) (data folder writable: $($report.data_dir_writable))" }
    Write-Ok "Agent $($report.agent_version) starts, reads its settings and can write its queue; server: $($report.server_detail)"

    Write-Host "`nThe CompuLab agent is installed." -ForegroundColor Green
    if ($scope -and $scope.Scope -eq 'StudentGroup') {
        Write-Host "  It starts the next time a student account ($($script:StudentGroupName)) signs in to Windows. Administrators are not locked."
    } else {
        Write-Host '  It starts the next time a user signs in to Windows (sign out and back in now to start it).'
    }
    Write-Host "  Check it any time:         powershell -ExecutionPolicy Bypass -File `"$toolsDir\agent-status.ps1`""
    Write-Host "  Change the server address: powershell -ExecutionPolicy Bypass -File `"$toolsDir\set-agent-server.ps1`" -ServerUrl http://<server>:8000"
    Write-Host '  In CompuLab, this PC must have its IP address set (Manage labs > PC > Edit):'
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        ForEach-Object { Write-Host "     $($_.IPAddress)  ($($_.InterfaceAlias))" }
    Write-Host '  Use a standard (non-administrator) Windows account for students.'
    if ($logPath) { Write-Host "  Install log: $logPath" }
} catch {
    $exitCode = 1
    Write-Host "`nInstallation stopped: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Fix the problem above and run the installer again (it continues safely).' -ForegroundColor Red
    if ($logPath) { Write-Host "  Full log: $logPath" -ForegroundColor Red }
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}
if ($PauseAtEnd) { Read-Host "`nPress Enter to close this window" | Out-Null }
exit $exitCode
