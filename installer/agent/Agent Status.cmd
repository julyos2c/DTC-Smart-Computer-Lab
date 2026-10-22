@echo off
rem Shows the CompuLab agents server address, last contact and queued events. Changes nothing.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent-status.ps1"
echo.
pause
