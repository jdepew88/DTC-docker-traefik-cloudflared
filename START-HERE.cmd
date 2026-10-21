@echo off
rem Deployment Manager (Traefik + Cloudflare) - double-click to start. No administrator rights needed.
rem Starts the local website and opens it in your browser. Keep the window open while you use it.
setlocal
cd /d "%~dp0"
title Deployment Manager

where powershell.exe >nul 2>nul
if errorlevel 1 (
  echo Windows PowerShell was not found. It is part of Windows 10 and 11; check that it has not been removed or blocked.
  goto :failed
)
if not exist "%~dp0Start-DeploymentManager.ps1" (
  echo Start-DeploymentManager.ps1 is missing. Extract the whole ZIP file first, then double-click START-HERE.cmd in the extracted folder.
  goto :failed
)

rem -ExecutionPolicy Bypass applies to this window only; it does not change your system settings.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DeploymentManager.ps1" %*
if errorlevel 1 goto :policy
exit /b 0

:policy
echo.
echo The Deployment Manager did not start (see the messages above).
rem If an organization policy enforces signed scripts, -ExecutionPolicy Bypass is ignored. Show the effective policies.
powershell.exe -NoProfile -Command "Get-ExecutionPolicy -List | Format-Table -AutoSize | Out-String" 2>nul
echo If MachinePolicy or UserPolicy shows AllSigned or Restricted, your administrator only allows signed scripts:
echo ask them, or use a signed release of this tool.

:failed
echo.
pause
exit /b 1
