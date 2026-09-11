@echo off
rem AISPM host agent installer - double-clickable wrapper around install.ps1.
rem
rem Exists so an operator can unzip the installer package and double-click, without touching the
rem PowerShell execution policy: -ExecutionPolicy Bypass applies to THIS invocation only and does
rem not change the machine's policy. Every argument is forwarded, so
rem   install.cmd -InstallDir D:\IlluminaIT -ReEnroll
rem works exactly like the PowerShell call.
rem
rem It must run elevated: the agent's preflight treats missing elevation as a fatal check, so a
rem non-elevated install produces an agent that cannot start.

setlocal
net session >nul 2>&1
if errorlevel 1 (
	echo error: this installer must run as Administrator.
	echo        Right-click install.cmd and choose "Run as administrator".
	echo.
	pause
	exit /b 5
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set RC=%ERRORLEVEL%

rem Keep the window open when double-clicked so the result and remediation stay readable.
echo.
echo Installer exited with code %RC%.
if not "%CI%"=="" goto :end
pause
:end
exit /b %RC%
