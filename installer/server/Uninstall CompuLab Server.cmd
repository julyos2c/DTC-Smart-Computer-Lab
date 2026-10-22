@echo off
rem Removes the CompuLab services, firewall rules and backup task. Keeps all data.
rem Asks Windows for administrator rights, then runs uninstall-server.ps1.
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo Asking for administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall-server.ps1"
echo.
pause
