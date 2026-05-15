@echo off
chcp 65001 >nul
title JumpRelay - Jump Server Clipboard Monitor
echo.
echo   JumpRelay - Monitor test\Victor\Temp for file changes
echo   New/updated files -> clipboard
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0JumpRelay.ps1"
pause
