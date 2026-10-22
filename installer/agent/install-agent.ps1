<#
.SYNOPSIS
  Installs (or updates) the CompuLab lock-screen agent on one lab PC.

.DESCRIPTION
  Run on the lab PC, as Administrator, from a copy of the CompuLab folder
  (USB stick or network share):

      powershell -ExecutionPolicy Bypass -File installer\agent\install-agent.ps1 -ConfigFile E:\agent_config.local.json

  Get -ConfigFile from CompuLab: PC status > (this PC's row) > "Agent config"
  (an Admin downloads it; it already contains the server address, the agent
  secret and this PC's name). Without -ConfigFile the script asks for the
  server address and secret instead. -ServerUrl overrides the address in
  either case.

  What it does:
    1. Checks Windows and Python 3.11+ (install from python.org "for all users" first).
    2. Copies the agent to C:\Program Files\CompuLab Agent and creates its own
       Python environment there.
    3. Writes agent_config.local.json (readable by Administrators and SYSTEM;
       the lab user account cannot change it).
    4. Creates C:\ProgramData\CompuLab Agent, where the agent keeps events
       that are waiting to be sent and its last-contact status. It is kept
       across updates, reinstalls and uninstalls (unless -RemoveData).
    5. Checks that the CompuLab server answers. If it does not, the install
       continues with a warning: the agent keeps trying by itself.
    6. Opens port 5555 (and ping) for the CompuLab server's IP address only.
    7. Starts the agent automatically when a user signs in to Windows (the lock
       screen must run in the user's desktop session, so it is a logon task,
       not a service), and restarts it if it stops.

  There is no automatic server discovery: the server address is configured
  here (or with set-agent-server.ps1) and must be the server's fixed campus
  address.

  Each lab PC also needs a fixed IP address (DHCP reservation in the router)
  that matches its IP in CompuLab (Manage labs > PC > Edit).
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = '',
    [string]$ServerUrl = '',
    [string]$InstallDir = "$env:ProgramFiles\CompuLab Agent",
    [string]$DataDir = "$env:ProgramData\CompuLab Agent",
    [string]$LabUser = '',           # Windows account students use; default: any user who signs in
    [int]$AgentPort = 5555
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\agent-common.ps1"
Assert-Admin
$sourceDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..\lab_pc_agent')).Path

# ---------------------------------------------------------------- 1. Windows + Python
Write-Step 'Checking Windows and Python'
if ([Environment]::OSVersion.Version.Major -lt 10) { throw 'Windows 10 or 11 is required.' }
$python = $null
foreach ($candidate in @(@('py', '-3.13'), @('py', '-3.12'), @('py', '-3.11'), @('python'))) {
    try {
        $v = & $candidate[0] @($candidate | Select-Object -Skip 1) -c 'import sys, tkinter; print("%d.%d" % sys.version_info[:2])' 2>$null
        if ($LASTEXITCODE -eq 0 -and [version]$v -ge [version]'3.11') { $python = $candidate; break }
    } catch { }
}
if (-not $python) { throw 'Python 3.11+ (with tkinter, the default) was not found. Install it from python.org for all users, then run this again.' }
Write-Ok "Python $v"

# ---------------------------------------------------------------- 2. files + venv
Write-Step "Installing the agent in $InstallDir"
Stop-Agent $InstallDir
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Get-ChildItem $sourceDir -Exclude 'agent_config.local.json', 'pending_callbacks.json*', 'agent_status.json*', '__pycache__', 'test_url.py' |
    Copy-Item -Destination $InstallDir -Recurse -Force
# The status / server-address tools, for later use on this PC.
$toolsDir = Join-Path $InstallDir 'tools'
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot '*.ps1') $toolsDir -Force
if (-not (Test-Path "$InstallDir\venv\Scripts\pythonw.exe")) {
    & $python[0] @($python | Select-Object -Skip 1) -m venv "$InstallDir\venv"
}
& "$InstallDir\venv\Scripts\python.exe" -m pip install --disable-pip-version-check -r "$InstallDir\requirements.txt"
if ($LASTEXITCODE -ne 0) { Write-Note 'Optional packages (Pillow, uiautomation) did not install (no internet?): the agent still works, with a plainer lock screen.' }
Write-Ok 'Agent files installed'

# ---------------------------------------------------------------- 3. config
Write-Step 'Writing this PC''s agent settings'
$localConfig = Join-Path $InstallDir 'agent_config.local.json'
if ($ConfigFile) {
    Copy-Item $ConfigFile $localConfig -Force
} elseif (-not (Test-Path $localConfig)) {
    if (-not $ServerUrl) { $ServerUrl = Read-Host 'CompuLab server campus address (e.g. http://192.168.1.10:8000)' }
    $secretSecure = Read-Host -AsSecureString 'Agent secret (PC_AGENT_SHARED_SECRET from the server''s .env)'
    $secret = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSecure))
    Write-AgentConfig $localConfig @{ secret = $secret; server_url = ''; port = $AgentPort }
    $secret = $null
}
if ($ServerUrl) { Set-AgentServerUrl $localConfig (Test-ServerUrlFormat $ServerUrl) }
Protect-AgentConfig $localConfig
$config = Read-AgentConfig $localConfig
if (-not $config.server_url) { throw 'agent_config.local.json has no server_url. Run again with -ServerUrl http://<server>:8000.' }
if (-not $config.secret) { throw 'agent_config.local.json has no secret. Download the PC''s Agent config from CompuLab again.' }
Write-Ok "Server: $($config.server_url)"

# ---------------------------------------------------------------- 4. data folder
Write-Step 'Preparing the agent data folder'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
# Every Windows user on this PC may write here (the lock screen runs as
# whoever signs in); nothing secret is stored in it.
& icacls $DataDir /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
$queued = 0
$pendingFile = Join-Path $DataDir 'pending_callbacks.json'
if (Test-Path $pendingFile) { try { $queued = @(Get-Content $pendingFile -Raw | ConvertFrom-Json).Count } catch { } }
Write-Ok "$DataDir ($queued queued event(s) kept)"

# ---------------------------------------------------------------- 5. server check
Write-Step 'Checking the CompuLab server'
$check = Test-CompuLabServer $config.server_url
if ($check.Ok) { Write-Ok "Server answers at $($config.server_url)" }
else {
    Write-Note "Could not reach $($config.server_url) right now: $($check.Detail)"
    Write-Note 'Installation continues. The agent keeps trying by itself; check later with tools\agent-status.ps1.'
}

# ---------------------------------------------------------------- 6. firewall
Write-Step 'Firewall'
Set-AgentFirewall $config.server_url $AgentPort

# ---------------------------------------------------------------- 7. auto-start
Write-Step 'Starting the agent at every sign-in'
$action = New-ScheduledTaskAction -Execute "$InstallDir\venv\Scripts\pythonw.exe" -Argument "`"$InstallDir\agent.py`"" -WorkingDirectory $InstallDir
if ($LabUser) {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $LabUser
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $LabUser -LogonType Interactive -RunLevel Limited
} else {
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $taskPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited   # BUILTIN\Users
}
$taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'CompuLab Agent' -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $taskSettings -Force | Out-Null
Write-Ok 'Scheduled task "CompuLab Agent" registered (starts at every sign-in, also after a restart)'

Write-Host "`nThe CompuLab agent is installed." -ForegroundColor Green
Write-Host '  It starts the next time a user signs in to Windows (sign out and back in now to start it).'
Write-Host "  Check it any time:        powershell -ExecutionPolicy Bypass -File `"$toolsDir\agent-status.ps1`""
Write-Host "  Change the server address: powershell -ExecutionPolicy Bypass -File `"$toolsDir\set-agent-server.ps1`" -ServerUrl http://<server>:8000"
Write-Host '  In CompuLab, this PC must have its IP address set (Manage labs > PC > Edit):'
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    ForEach-Object { Write-Host "     $($_.IPAddress)  ($($_.InterfaceAlias))" }
Write-Host '  Use a standard (non-administrator) Windows account for students.'
