@echo off
rem Stop the local service.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop.ps1"
timeout.exe /t 2 /nobreak >nul