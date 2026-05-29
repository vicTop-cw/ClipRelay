@echo off
title JumpRelay - Victor Monitor
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "JumpRelay.ps1" -SyncBack
pause
