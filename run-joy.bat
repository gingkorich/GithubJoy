@echo off
setlocal
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
  echo [joy] PowerShell not found.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\read.ps1" %*
set RC=%errorlevel%
if not "%RC%"=="0" (
  echo.
  echo [joy] read exited with code %RC%
  pause
)
exit /b %RC%