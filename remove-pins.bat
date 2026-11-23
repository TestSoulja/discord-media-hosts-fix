@echo off
rem Undo: remove the discord-media-pin block from the hosts file.
rem Double-click. Administrator rights are requested automatically.
setlocal
chcp 65001 >nul
cd /d "%~dp0"

fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator rights...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    if errorlevel 1 (
        echo.
        echo Administrator rights were declined.
        echo Right-click this file and choose "Run as administrator".
        pause
    )
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-discord-media.ps1" -Remove
echo.
pause
