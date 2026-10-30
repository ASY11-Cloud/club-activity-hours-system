@echo off
chcp 936 >nul
cd /d "%~dp0"
echo ==========================================
echo  Club System Server  -  port 8000
echo ==========================================
echo.
echo [1/2] checking MySQL (127.0.0.1:3306) ...
netstat -ano | findstr ":3306" | findstr "LISTENING" >nul
if errorlevel 1 (
  echo   [WARN] MySQL is NOT listening on 3306.
  echo          Start MySQL service first, then rerun.
  echo.
  pause
  exit /b 1
)
echo   OK - MySQL is up.
echo.
echo [2/2] starting server.exe ...
echo   Keep this window OPEN while using the App.
echo   Press Ctrl+C or close the window to stop.
echo.
server.exe 8000
echo.
echo Server stopped.
pause
