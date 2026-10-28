@echo off
rem DTC Deployment Manager - one-time launcher setup for this Windows user. No administrator rights needed.
rem Builds launcher\DTC.exe, creates the desktop and Start menu shortcuts and saves your default deployment.
rem Add -Autostart to also start DTC silently when you sign in to Windows, e.g.:  Setup-Launcher.cmd -Autostart
rem Afterwards start DTC with the "DTC Deployment Manager" shortcut (no console window; it runs in the system tray).
setlocal
cd /d "%~dp0"
title DTC launcher setup
if not exist "%~dp0launcher\Install-Launcher.ps1" (
  echo launcher\Install-Launcher.ps1 is missing. Extract the whole ZIP file first, then run Setup-Launcher.cmd again.
  goto :failed
)
rem -ExecutionPolicy Bypass applies to this window only; it does not change your system settings.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\Install-Launcher.ps1" %*
if errorlevel 1 goto :failed
echo.
pause
exit /b 0

:failed
echo.
echo The launcher setup did not finish (see the messages above).
pause
exit /b 1
