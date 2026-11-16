@echo off
rem Background service entry (used by start-hidden.vbs / scheduled task). Logs to service.log.
cd /d "%~dp0"
set WRANGLER_SEND_METRICS=false
set CI=1
node "%~dp0node_modules\wrangler\bin\wrangler.js" dev --ip 0.0.0.0 --port 8787 >> "%~dp0service.log" 2>&1