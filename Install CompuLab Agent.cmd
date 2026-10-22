@echo off
rem Installs or repairs the CompuLab lock-screen agent on this lab PC. Put the PCs agent_config.local.json next to this file (or it asks for the server address and secret).
rem Asks Windows for administrator rights, then runs installer\agent\install-agent.ps1.
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo Asking for administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
if exist "%~dp0agent_config.local.json" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\agent\install-agent.ps1" -ConfigFile "%~dp0agent_config.local.json"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\agent\install-agent.ps1"
)
echo.
pause
