@echo off
chcp 65001 >nul
title ClipRelay - Local
echo.
echo   ====================================
echo     ClipRelay - Local Workstation
echo     Relay: D:\work\Clip\yyyyMMdd
echo   ====================================
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0ClipRelay.ps1" -Role local
pause
