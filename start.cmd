@echo off
rem Foreground start (debug). Close window or Ctrl+C to stop.
cd /d "%~dp0"
set WRANGLER_SEND_METRICS=false
set CI=1
echo Starting check-in service at http://127.0.0.1:8787 (bound to 0.0.0.0:8787)
node "%~dp0node_modules\wrangler\bin\wrangler.js" dev --ip 0.0.0.0 --port 8787