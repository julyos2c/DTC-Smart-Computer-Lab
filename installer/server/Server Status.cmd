@echo off
rem Shows whether every part of the CompuLab server works. Changes nothing.
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server-status.ps1"
echo.
pause
