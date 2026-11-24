@echo off
rem  Antigravity IDE Launcher for Secondary User Sessions
rem  - Registers browser protocol handlers on first run
rem  - Applies window title tag ([U2: ...]) to user's settings.json
rem  - Sets BROWSER env var for Electron fallback
rem  - Launches Antigravity IDE

set "BASEDIR=D:\Device\Apps\Antigravity Multi-Profile"
set "CHROME=C:\Program Files\Google\Chrome\Application\chrome.exe"
set "EDGE=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
set "BROWSER_LAUNCHER=%BASEDIR%\open-url.cmd"

if exist "%CHROME%" (
    set "BROWSER_EXE=%CHROME%"
) else (
    set "BROWSER_EXE=%EDGE%"
)

rem Register http/https protocol handlers in this user's HKCU (idempotent, silent)
reg add "HKCU\Software\Classes\http" /ve /d "URL:HTTP Protocol" /f >nul 2>&1
reg add "HKCU\Software\Classes\http" /v "URL Protocol" /d "" /f >nul 2>&1
reg add "HKCU\Software\Classes\http\shell\open\command" /ve /d "\"%BROWSER_LAUNCHER%\" \"%%1\"" /f >nul 2>&1

reg add "HKCU\Software\Classes\https" /ve /d "URL:HTTPS Protocol" /f >nul 2>&1
reg add "HKCU\Software\Classes\https" /v "URL Protocol" /d "" /f >nul 2>&1
reg add "HKCU\Software\Classes\https\shell\open\command" /ve /d "\"%BROWSER_LAUNCHER%\" \"%%1\"" /f >nul 2>&1

rem Apply window title marker for this user
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%BASEDIR%\apply-window-tag.ps1" -BaseDir "%BASEDIR%" >nul 2>&1

rem Set BROWSER env var as Electron/Node fallback
set "BROWSER=%BROWSER_LAUNCHER%"

rem Launch Antigravity IDE
start "" "D:\Device\Apps\Antigravity IDE\Antigravity IDE.exe"
