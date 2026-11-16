@echo off
rem Daily check-in entry: start service if down, then call /cron.
setlocal
cd /d "%~dp0"
for /f "usebackq tokens=1,* delims==" %%A in (`findstr /b "CRON_SECRET=" ".dev.vars"`) do set "SECRET=%%B"
if not defined SECRET for /f "usebackq tokens=1,* delims==" %%A in (`findstr /b "ADMIN_TOKEN=" ".dev.vars"`) do set "SECRET=%%B"
curl.exe -s -o nul --max-time 5 http://127.0.0.1:8787/oauth/probe >nul 2>&1
if errorlevel 1 wscript.exe "%~dp0start-hidden.vbs"
echo [%date% %time%] cron trigger >> "%~dp0cron.log"
curl.exe -s --retry 10 --retry-connrefused --retry-delay 3 --max-time 120 -X POST -H "X-Cron-Secret: %SECRET%" http://127.0.0.1:8787/cron >> "%~dp0cron.log" 2>&1
echo. >> "%~dp0cron.log"