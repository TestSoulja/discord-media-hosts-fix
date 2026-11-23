@echo off
rem One entry point for the Discord media fix.
rem Double-click this file: administrator rights are requested automatically.
rem License: MIT, Copyright (c) 2026 TestSoulja - see LICENSE in the repository.
rem Arguments are passed through, for example:
rem   fix-discord-media.bat -DryRun
rem   fix-discord-media.bat -Remove
setlocal
chcp 65001 >nul
cd /d "%~dp0"

if not exist "%~dp0fix-discord-media.ps1" (
    echo.
    echo fix-discord-media.ps1 is missing next to this file.
    echo Keep both files in the same folder and run this one again.
    echo Download both from https://github.com/TestSoulja/discord-media-hosts-fix
    echo.
    pause
    exit /b 1
)

rem Version needs no administrator rights.
if /i "%~1"=="-Version" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-discord-media.ps1" -Version
    pause
    exit /b 0
)

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

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-discord-media.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
    echo Finished with exit code %RC%.
)
pause
exit /b %RC%
