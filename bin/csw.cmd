@echo off
setlocal

set "SCRIPT=%~dp0..\ccswitch-windows.ps1"

if not exist "%SCRIPT%" (
    echo [ERR]  csw is installed but missing: %SCRIPT%
    echo        Reinstall with:
    echo        powershell -ExecutionPolicy Bypass -File install-windows.ps1
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
