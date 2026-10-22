@echo off
rem Installs, updates or repairs the CompuLab server on this computer.
rem Asks Windows for administrator rights, then runs installer\server\install-server.ps1.
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo Asking for administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\server\install-server.ps1"
echo.
pause
