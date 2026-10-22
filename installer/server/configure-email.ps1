<#
.SYNOPSIS
  Sets (or removes) the outgoing email account CompuLab uses.

.DESCRIPTION
  Email is optional: without it CompuLab works fully on the campus network,
  and emails are only written to the log. With it, verification links,
  reservation codes and alerts are delivered whenever the internet is up
  (they wait in the Email outbox while it is down).

  Gmail: use an App Password (myaccount.google.com/apppasswords, needs
  2-Step Verification), host smtp.gmail.com, port 587, TLS.
  cPanel mailbox: host mail.<domain>, port 465, SSL.
#>
[CmdletBinding()]
param([switch]$Disable)

. "$PSScriptRoot\common.ps1"
Assert-Admin

if ($Disable) {
    Set-DotEnvValue 'EMAIL_HOST_USER' ''
    Set-DotEnvValue 'EMAIL_HOST_PASSWORD' ''
    Write-Ok 'Email turned off (messages are written to the log only).'
} else {
    $user = Read-Host 'Sending email address (e.g. compulab.noreply@gmail.com)'
    $password = Read-Host -AsSecureString 'Its password (Gmail: the 16-letter App Password)'
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))
    $gmail = $user -like '*@gmail.com'
    $defaultHost = if ($gmail) { 'smtp.gmail.com' } else { 'mail.' + ($user.Split('@')[-1]) }
    $mailHost = Read-Host "Mail server [$defaultHost]"
    if (-not $mailHost) { $mailHost = $defaultHost }
    $useSsl = if ($gmail) { 'n' } else { Read-Host 'Use SSL on port 465? (y = SSL/465, n = TLS/587) [y]' }
    if ($useSsl -eq '' ) { $useSsl = 'y' }
    if ($useSsl -match '^[yY]') {
        Set-DotEnvValue 'EMAIL_PORT' '465'; Set-DotEnvValue 'EMAIL_USE_SSL' 'True'; Set-DotEnvValue 'EMAIL_USE_TLS' 'False'
    } else {
        Set-DotEnvValue 'EMAIL_PORT' '587'; Set-DotEnvValue 'EMAIL_USE_SSL' 'False'; Set-DotEnvValue 'EMAIL_USE_TLS' 'True'
    }
    Set-DotEnvValue 'EMAIL_BACKEND' 'django.core.mail.backends.smtp.EmailBackend'
    Set-DotEnvValue 'EMAIL_HOST' $mailHost
    Set-DotEnvValue 'EMAIL_HOST_USER' $user
    Set-DotEnvValue 'EMAIL_HOST_PASSWORD' $plain
    Set-DotEnvValue 'DEFAULT_FROM_EMAIL' "CompuLab <$user>"
    Set-DotEnvValue 'SERVER_EMAIL' $user
    $plain = $null
    Protect-EnvFile
    Write-Ok "Email will be sent from $user via $mailHost."
}

Write-Step 'Restarting CompuLab to apply'
Stop-CompuLabServices
Start-CompuLabServices
Write-Note 'Check Admin > System status: "Email server (SMTP)" should show OK within a minute when the internet is up.'
