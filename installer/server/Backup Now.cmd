@echo off
rem Backs up the CompuLab database, uploads and settings now, to the same
rem folder as the nightly backups (COMPULAB_BACKUP_ROOT in .env). Writes
rem logs\backup-<time>.log and says where the backup went.
rem Asks Windows for administrator rights, then runs backup.ps1.
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo Asking for administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup.ps1" -Log
if errorlevel 1 (
  echo.
  echo The backup FAILED - the reason is shown above and in the newest logs\backup-*.log.
)
echo.
pause
