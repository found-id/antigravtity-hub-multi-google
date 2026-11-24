@echo off
setlocal DisableDelayedExpansion
rem  Browser URL Opener for Antigravity Secondary User Sessions
rem  Safely passes full URLs (including & and = in OAuth links) to Host Hub

set "BASEDIR=D:\Device\Apps\Antigravity Multi-Profile"
set "URL=%~1"
if "%URL%"=="" exit /b 0

powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Add-Content -LiteralPath '%BASEDIR%\pending_urls.txt' -Value ('%USERNAME%|' + $args[0]) -Encoding UTF8" "%URL%"
