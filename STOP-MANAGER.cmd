@echo off
rem Stops a running Deployment Manager website (your deployments and their containers keep running).
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DeploymentManager.ps1" -Stop
timeout /t 3 >nul
