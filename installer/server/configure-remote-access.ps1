<#
.SYNOPSIS
  Sets up (or removes) remote access to CompuLab through Tailscale.

.DESCRIPTION
  Optional. Lets authorized staff open CompuLab from home through the
  college's private Tailscale network (tailnet). Nothing is opened to the
  public internet and no router port forwarding is used. The campus (LAN)
  address keeps working exactly as before, with or without this.

  Before running it (manual steps - see installer\REMOTE_ACCESS.md):
    1. Install Tailscale on this server (tailscale.com/download/windows).
    2. Sign in to the college's tailnet from the Tailscale tray icon, and
       turn on "Run unattended" so it connects before anyone signs in to
       Windows.
    3. For -Mode Serve (HTTPS, recommended): in the Tailscale admin console
       (login.tailscale.com/admin/dns) enable MagicDNS and "HTTPS Certificates".

  Modes:
    Serve   (default) https://<server>.<tailnet>.ts.net  - Tailscale itself
            receives HTTPS with a valid certificate and passes requests to
            CompuLab on this computer (tailscale serve). Only tailnet
            members can reach it (this is not Tailscale Funnel).
    Direct  http://<100.x.y.z>:<port> - browsers connect to CompuLab's port
            over the tailnet. Traffic is still encrypted by Tailscale, but
            browsers show "Not secure". A firewall rule allows the port from
            Tailscale addresses (100.64.0.0/10) only.
    Disable removes the remote address (and the serve / firewall config).

  The script never signs in to Tailscale for you and reports exactly what
  did and did not work.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File installer\server\configure-remote-access.ps1
  powershell -ExecutionPolicy Bypass -File installer\server\configure-remote-access.ps1 -Mode Direct
  powershell -ExecutionPolicy Bypass -File installer\server\configure-remote-access.ps1 -Mode Disable
#>
[CmdletBinding()]
param(
    [ValidateSet('Serve', 'Direct', 'Disable')]
    [string]$Mode = 'Serve',
    [int]$Port = 0
)

. "$PSScriptRoot\common.ps1"
Assert-Admin
if ($Port -le 0) { $Port = Get-SitePort }
$ruleName = 'CompuLab Web (Tailscale)'

$tailscale = Find-Tailscale
if ($Mode -eq 'Disable') {
    Write-Step 'Removing remote access'
    if ($tailscale) {
        & $tailscale serve reset 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'Tailscale serve configuration removed' }
    }
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Set-DotEnvValue 'COMPULAB_REMOTE_URL' ''
    Stop-CompuLabServices
    Start-CompuLabServices
    Write-Ok 'Remote address cleared. The campus address works as before.'
    return
}

# ---------------------------------------------------------------- 1. Tailscale present and signed in
Write-Step 'Checking Tailscale on this server'
if (-not $tailscale) {
    Write-Note 'Tailscale is not installed. Install it from tailscale.com/download/windows, sign in to the college tailnet,'
    Write-Note 'turn on "Run unattended" in the tray menu, then run this script again. Nothing was changed.'
    exit 1
}
$self = Get-TailscaleSelf $tailscale
if (-not $self -or $self.State -ne 'Running') {
    $state = if ($self) { $self.State } else { 'unknown' }
    Write-Note "Tailscale is installed but not connected (state: $state)."
    Write-Note 'Open the Tailscale tray icon and sign in (or run "tailscale up"), then run this script again. Nothing was changed.'
    exit 1
}
Write-Ok "Connected to the tailnet as $($self.DnsName) ($($self.IPv4))"

# ---------------------------------------------------------------- 2. CompuLab answers locally
if (-not (Wait-Healthy "http://127.0.0.1:$Port/healthz" 10)) {
    Write-Note "CompuLab does not answer on http://127.0.0.1:$Port right now. Start the CompuLab Web service first (server-status.ps1). Nothing was changed."
    exit 1
}

# ---------------------------------------------------------------- 3. expose on the tailnet
if ($Mode -eq 'Serve') {
    Write-Step 'Publishing CompuLab on the tailnet with HTTPS (tailscale serve)'
    if (-not $self.DnsName) {
        Write-Note 'This machine has no MagicDNS name. Enable MagicDNS in the Tailscale admin console, or use -Mode Direct. Nothing was changed.'
        exit 1
    }
    & $tailscale serve --bg --https=443 "http://127.0.0.1:$Port"
    if ($LASTEXITCODE -ne 0) {
        Write-Note '"tailscale serve" failed. Usually HTTPS certificates are not enabled for the tailnet:'
        Write-Note 'Tailscale admin console > DNS > enable MagicDNS and HTTPS Certificates, then run this again.'
        Write-Note 'Or use -Mode Direct (plain http over the encrypted tailnet). Nothing else was changed.'
        exit 1
    }
    $remoteUrl = "https://$($self.DnsName)"
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Ok "Tailscale serves $remoteUrl -> http://127.0.0.1:$Port (no extra firewall rule is needed)"
} else {
    Write-Step 'Allowing the CompuLab port from Tailscale addresses only'
    if (-not $self.IPv4) { Write-Note 'This machine has no Tailscale IPv4 address. Nothing was changed.'; exit 1 }
    & $tailscale serve reset 2>$null | Out-Null
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port `
        -RemoteAddress '100.64.0.0/10' -Action Allow -Profile Any | Out-Null
    $remoteUrl = "http://$($self.IPv4):$Port"
    Write-Ok "Port $Port allowed from 100.64.0.0/10 (Tailscale) only"
}

# ---------------------------------------------------------------- 4. tell CompuLab
Write-Step 'Saving the remote address'
Set-DotEnvValue 'COMPULAB_REMOTE_URL' $remoteUrl
Write-Ok "COMPULAB_REMOTE_URL=$remoteUrl (CompuLab accepts this address; the campus address is unchanged)"
Stop-CompuLabServices
Start-CompuLabServices

# ---------------------------------------------------------------- 5. verify from this server
Write-Step 'Checking the remote address from this server'
if (Wait-Healthy "$remoteUrl/healthz" 60) {
    Write-Ok "$remoteUrl answers."
} else {
    Write-Note "$remoteUrl did not answer from this server yet. Check again in a minute with:"
    Write-Note "  Invoke-WebRequest $remoteUrl/healthz -UseBasicParsing"
    Write-Note 'If it keeps failing, see "Troubleshooting" in installer\REMOTE_ACCESS.md.'
}

Write-Host "`nRemote address: $remoteUrl" -ForegroundColor Green
Write-Host '  It works only from devices signed in to the college tailnet, while this server is on and has internet.'
Write-Host '  Give access in the Tailscale admin console (invite the person, then an access rule to this server only).'
Write-Host "  Staff shortcut: installer\launcher\install-launcher.ps1 -LanUrl <campus address> -RemoteUrl $remoteUrl"
Write-Host '  Not verified by this script: access from an outside device. Test it from a laptop on another network.'
