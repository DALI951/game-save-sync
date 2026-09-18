@echo off
rem GameSaveSync launcher - double-click to sync saves between this PC and the USB
title GameSaveSync
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync.ps1" %*
echo.
pause