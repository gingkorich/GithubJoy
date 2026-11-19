@echo off
setlocal
cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 (
  echo [joy] Node.js not found. Install Node 18+ and retry.
  pause
  exit /b 4
)

node "service\server.js" %*
set RC=%errorlevel%
if not "%RC%"=="0" (
  echo.
  echo [joy] exited with code %RC%
  pause
)
exit /b %RC%