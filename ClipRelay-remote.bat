@echo off
chcp 65001 >nul
title ClipRelay - Remote
echo.
echo   ====================================
echo     ClipRelay - Jump Server
echo     Relay: C:\FTP\test\Victor\Temp
echo   ====================================
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0ClipRelay.ps1" -Role remote
pause
