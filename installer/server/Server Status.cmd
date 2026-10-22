@echo off
rem Shows whether every part of the CompuLab server works. Changes nothing.
rem The full report needs administrator rights (settings file, firewall rule,
rem backup task). Without them it offers to ask Windows for them (the normal
rem UAC prompt) or to show a limited report that says what it skipped.
setlocal
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
  echo Without administrator rights some checks are skipped: settings file, firewall rule, backup task.
  choice /c FL /n /m "Press F for the full report (Windows asks for administrator rights) or L for the limited report: "
  if errorlevel 2 goto limited
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
:limited
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server-status.ps1"
echo.
pause
