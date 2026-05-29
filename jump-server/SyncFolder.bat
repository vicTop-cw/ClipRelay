@echo off
title SyncFolder - File Monitor
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "SyncFolder.ps1"
pause
