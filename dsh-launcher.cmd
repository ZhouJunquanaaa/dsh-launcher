@echo off
setlocal
chcp 65001 >nul
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"
start "" "%PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0dsh-launcher.ps1" %*
