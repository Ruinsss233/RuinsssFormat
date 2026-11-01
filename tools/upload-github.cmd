@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0.."
title RuinsssFormat - Upload Source
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0upload-github.ps1" %*
set "CODE=%ERRORLEVEL%"
echo.
if not "%CODE%"=="0" (
  echo Upload failed. See the message above.
) else (
  echo Upload finished.
)
echo.
pause
exit /b %CODE%
