@echo off
rem ============================================================
rem  社团活动报名与学时认定系统 - 服务端编译脚本(Windows)
rem  自动定位 g++(Dev-C++ 自带 MinGW 或 PATH 中的 g++)
rem  依赖: MySQL Server 8.0
rem ============================================================
setlocal enabledelayedexpansion

set MYSQL_HOME=C:\Program Files\MySQL\MySQL Server 8.0

if not exist "%MYSQL_HOME%\include\mysql.h" (
  echo [ERROR] 未找到 MySQL 8.0, 请修改本脚本中的 MYSQL_HOME
  exit /b 1
)

rem ---- 定位 g++ ----
set GXX=
where g++ >nul 2>nul
if not errorlevel 1 set GXX=g++
if "%GXX%"=="" (
  if exist "C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\g++.exe" set GXX=C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\g++.exe
)
if "%GXX%"=="" (
  if exist "C:\Program Files\Dev-Cpp\MinGW64\bin\g++.exe" set GXX=C:\Program Files\Dev-Cpp\MinGW64\bin\g++.exe
)
if "%GXX%"=="" (
  if exist "C:\Program Files\mingw64\bin\g++.exe" set GXX=C:\Program Files\mingw64\bin\g++.exe
)
if "%GXX%"=="" (
  echo [ERROR] 未找到 g++, 请安装 MinGW-w64 或 Dev-C++
  exit /b 1
)
echo [0/3] 使用编译器: %GXX%

echo [1/3] 编译 server.cpp ...
"%GXX%" -std=c++11 -O2 -Wall server.cpp -o server.exe ^
  -I "%MYSQL_HOME%\include" ^
  -L "%MYSQL_HOME%\lib" -lmysql -lws2_32
if errorlevel 1 (
  echo [ERROR] 编译失败
  exit /b 1
)

echo [2/3] 复制运行库 ...
copy /Y "%MYSQL_HOME%\lib\libmysql.dll" . >nul
copy /Y "%MYSQL_HOME%\bin\libssl-3-x64.dll" . >nul 2>nul
copy /Y "%MYSQL_HOME%\bin\libcrypto-3-x64.dll" . >nul 2>nul

echo [3/3] 完成, 产物: server.exe
echo 运行: server.exe [port] [db_user] [db_pass] [db_host]   (默认 8000 root 123456 127.0.0.1)
endlocal
