@echo off
chcp 65001 >nul
setlocal EnableExtensions
title 安装「人格档案每日快照」计划任务
cd /d "%~dp0"

set "SCRIPT=%~dp0sync-memory.ps1"
if not exist "%SCRIPT%" (
  echo [x] 找不到 sync-memory.ps1
  pause
  exit /b 1
)

echo.
echo  这会在「任务计划程序」里建一个每天 03:00 运行的任务：
echo    qq-bridge-memory-sync
echo    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
echo.
echo  作用：每天把服务器上的人格档案（事实/日记/内核/档案留存）拉一份到
echo        E:\qq-bridge\.sync\memory-日期-时间\ ，只读快照，不覆盖本地 state。
echo  想删掉：schtasks /delete /tn "qq-bridge-memory-sync" /f
echo.
pause

schtasks /create /tn "qq-bridge-memory-sync" /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%SCRIPT%\"" /sc daily /st 03:00 /f
if errorlevel 1 (
  echo.
  echo [x] 创建失败。多半是权限：右键这个文件 - 「以管理员身份运行」再试一次。
  pause
  exit /b 1
)

echo.
echo [v] 已创建。现在立刻跑一次看看：
schtasks /run /tn "qq-bridge-memory-sync"
timeout /t 8 >nul
echo.
echo 快照目录：%USERPROFILE%\..\qq-bridge\.sync  ^(即仓库下的 .sync^)
dir /b "%~dp0..\.sync"
echo.
pause
