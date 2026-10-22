@echo off
rem Removes the CompuLab agent from this PC. Queued events are kept unless you run uninstall-agent.ps1 -RemoveData.
rem Asks Windows for administrator rights, then runs uninstall-agent.ps1.
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo Asking for administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-agent.ps1"
echo.
pause
