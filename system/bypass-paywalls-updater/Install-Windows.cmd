@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows.ps1"
set "UpdaterExitCode=%ERRORLEVEL%"
echo.
pause
exit /b %UpdaterExitCode%
