@echo off
rem Daily AgentRouter check-in entry (called by scheduled task).
rem The Python script writes checkin.log itself; stdout/stderr go to console.log.
setlocal
cd /d "%~dp0"
rem Clear inherited proxy env vars: httpx trust_env misparses NO_PROXY IPv6 entries ([::1]) and errors.
set NO_PROXY=
set no_proxy=
set HTTP_PROXY=
set http_proxy=
set HTTPS_PROXY=
set https_proxy=
set ALL_PROXY=
set all_proxy=
".venv\Scripts\python.exe" login_checkin.py >> "%~dp0console.log" 2>&1
exit /b %errorlevel%
