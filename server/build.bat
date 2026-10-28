@echo off
rem ============================================================
rem  社团活动报名与学时认定系统 - 服务端编译脚本(Windows)
rem  按顺序尝试多个 g++ 工具链, 首个编译成功的即采用
rem  注意: 编译前请先关闭正在运行的 server.exe, 否则文件被占用无法覆盖
rem  依赖: MySQL Server 8.0
rem ============================================================
setlocal enabledelayedexpansion

set MYSQL_HOME=C:\Program Files\MySQL\MySQL Server 8.0

if not exist "%MYSQL_HOME%\include\mysql.h" (
  echo [ERROR] 未找到 MySQL 8.0, 请修改本脚本中的 MYSQL_HOME
  exit /b 1
)

set FLAGS=-std=c++14 -O2 -Wall server.cpp -o server.exe -I "%MYSQL_HOME%\include" -L "%MYSQL_HOME%\lib" -lmysql -lws2_32
set BUILT=0
if exist build.log del /q build.log

echo [1/3] 编译 server.cpp ...

rem ---- 候选 1: Dev-C++ 自带 MinGW64, TDM 版支持 C++11 线程, 优先使用 ----
if exist "C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\g++.exe" (
  echo   尝试: Dev-C++ MinGW64 g++
  "C:\Program Files (x86)\Dev-Cpp\MinGW64\bin\g++.exe" %FLAGS% >build.log 2>&1
  if not errorlevel 1 set BUILT=1
)

rem ---- 候选 2: Dev-C++ 安装于 Program Files ----
if "!BUILT!"=="0" if exist "C:\Program Files\Dev-Cpp\MinGW64\bin\g++.exe" (
  echo   尝试: Dev-C++ MinGW64 g++
  "C:\Program Files\Dev-Cpp\MinGW64\bin\g++.exe" %FLAGS% >>build.log 2>&1
  if not errorlevel 1 set BUILT=1
)

rem ---- 候选 3: PATH 中的 g++ ----
rem   部分 MinGW 为 win32 线程模型, 不支持 std::thread / std::mutex, 编译会失败并自动跳过
if "!BUILT!"=="0" (
  where g++ >nul 2>nul
  if not errorlevel 1 (
    echo   尝试: PATH 中的 g++
    g++ %FLAGS% >>build.log 2>&1
    if not errorlevel 1 set BUILT=1
  )
)

if "!BUILT!"=="0" (
  echo.
  echo [ERROR] 编译失败: 未找到可用工具链, 或编译报错
  echo         1. 确认已安装 Dev-C++ 或 MinGW-w64, 且编译器支持 C++11 线程
  echo         2. 确认 server.exe 已关闭: 运行中的 exe 被占用会导致链接失败
  echo         3. 编译日志见 build.log
  exit /b 1
)

echo [2/3] 复制运行库 ...
copy /Y "%MYSQL_HOME%\lib\libmysql.dll" . >nul
copy /Y "%MYSQL_HOME%\bin\libssl-3-x64.dll" . >nul 2>nul
copy /Y "%MYSQL_HOME%\bin\libcrypto-3-x64.dll" . >nul 2>nul

echo [3/3] 完成, 产物: server.exe
echo 运行: server.exe [port] [db_user] [db_pass] [db_host]   (默认 8000 root 123456 127.0.0.1)
endlocal
