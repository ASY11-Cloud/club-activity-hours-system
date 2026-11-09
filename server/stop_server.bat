@echo off
setlocal
echo.
echo   Stopping club-system server (server.exe) ...
echo.
taskkill /F /IM server.exe >nul 2>&1
if errorlevel 1 (
  echo   [info] server.exe is not running.
) else (
  echo   [done] server.exe stopped, port 8000 released.
)
echo.
pause
