# Shared helpers for the lab PC agent scripts. Dot-source it:
#   . "$PSScriptRoot\agent-common.ps1"
# Works with Windows PowerShell 5.1 (built into Windows 10/11).

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$t) { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Write-Ok([string]$t) { Write-Host "    OK: $t" -ForegroundColor Green }
function Write-Note([string]$t) { Write-Host "    $t" -ForegroundColor Yellow }

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Please run this as Administrator (right-click PowerShell > Run as administrator).'
    }
}

function Stop-Agent([string]$InstallDir) {
    Get-ScheduledTask -TaskName 'CompuLab Agent' -ErrorAction SilentlyContinue | Stop-ScheduledTask -ErrorAction SilentlyContinue
    Get-Process pythonw, python -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$InstallDir*" } | Stop-Process -Force
}

function Test-ServerUrlFormat([string]$Url) {
    $Url = $Url.Trim().TrimEnd('/')
    if ($Url -notmatch '^https?://[^/\s]+$') {
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

function Set-AgentServerUrl([string]$Path, [string]$Url) {
    $config = Read-AgentConfig $Path
    if ($config.PSObject.Properties.Name -contains 'server_url') { $config.server_url = $Url }
    else { $config | Add-Member -NotePropertyName server_url -NotePropertyValue $Url }
    Write-AgentConfig $Path $config
}

function Protect-AgentConfig([string]$Path) {
    # Administrators and SYSTEM may change it; the lab users may only read it.
    & icacls $Path /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' '*S-1-5-32-545:R' | Out-Null
}

function Test-CompuLabServer([string]$Url) {
    # @{ Ok; Detail } - does CompuLab answer /healthz at this address?
    try {
        $r = Invoke-WebRequest -Uri ($Url.TrimEnd('/') + '/healthz') -UseBasicParsing -TimeoutSec 8
        if ($r.Content.Trim() -eq 'ok') { return @{ Ok = $true; Detail = 'answers' } }
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
