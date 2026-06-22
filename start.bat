@echo off
cd /d "%~dp0"
echo.
echo  npm Package Manager
echo  ===================
echo.
echo  Starte Server...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
pause
