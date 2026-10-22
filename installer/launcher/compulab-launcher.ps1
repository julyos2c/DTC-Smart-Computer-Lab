<#
.SYNOPSIS
  Opens CompuLab in the browser, using whichever server address works:
  the campus (LAN) address first, then the remote (VPN / Tailscale) one.

  Settings come from launcher.json next to this script:
    { "lan_url": "http://192.168.1.10:8000", "remote_url": "http://100.64.0.10:8000" }
#>
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
$settingsPath = Join-Path $PSScriptRoot 'launcher.json'
$settings = if (Test-Path $settingsPath) { Get-Content $settingsPath -Raw | ConvertFrom-Json } else { $null }
$candidates = @()
if ($settings.lan_url) { $candidates += @{ Url = $settings.lan_url.TrimEnd('/'); Label = 'campus network' } }
if ($settings.remote_url) { $candidates += @{ Url = $settings.remote_url.TrimEnd('/'); Label = 'remote (VPN)' } }
if (-not $candidates.Count) {
    [System.Windows.Forms.MessageBox]::Show('CompuLab launcher is not configured. Run install-launcher.ps1 again.', 'CompuLab') | Out-Null
    exit 1
}

foreach ($attempt in 1..3) {
    foreach ($c in $candidates) {
        try {
            $r = Invoke-WebRequest -Uri ($c.Url + '/healthz') -UseBasicParsing -TimeoutSec 4
            if ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'ok') {
                Start-Process $c.Url
                exit 0
            }
        } catch { }
    }
    Start-Sleep -Seconds (2 * $attempt)
}

$tried = ($candidates | ForEach-Object { "$($_.Url) ($($_.Label))" }) -join "`n"
[System.Windows.Forms.MessageBox]::Show(
    "The CompuLab server is not answering right now.`n`nTried:`n$tried`n`nOn campus: check this computer's network cable/Wi-Fi.`nOff campus: connect the VPN (Tailscale) first.`nIf it still fails, the server may be off - tell the Lab Administrator.",
    'CompuLab - server unavailable', 'OK', 'Warning') | Out-Null
exit 1
