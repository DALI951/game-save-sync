@echo off
rem GameSync-App launcher - starts the web UI (or opens it if already running)
title GameSync-App
curl -s -m 2 http://127.0.0.1:8771/api/status >nul 2>&1
if errorlevel 1 (
  start "" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app.ps1"
  timeout /t 2 /nobreak >nul
)
start "" http://127.0.0.1:8771
exit