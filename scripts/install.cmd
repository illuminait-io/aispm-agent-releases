@echo off
rem AISPM host agent installer - double-click this file.
rem
rem It wraps install.ps1 and does the three things a double-click needs and PowerShell will not do
rem on its own:
rem
rem  1. BYPASSES THE EXECUTION POLICY for this invocation only (-ExecutionPolicy Bypass). It does not
rem     change the machine's policy, which is why install.ps1 is not double-clickable itself: a
rem     double-clicked .ps1 opens in an editor or is refused outright.
rem  2. ASKS FOR ADMINISTRATOR RIGHTS instead of dead-ending on advice. The agent's preflight treats
rem     missing elevation as a fatal check, so a non-elevated install produces an agent that cannot
rem     start - and telling somebody who just double-clicked to go and right-click instead is a
rem     needless second attempt.
rem  3. KEEPS THE WINDOW OPEN at the end, with the verdict, until a key is pressed or 60 seconds
rem     pass. A double-clicked window closes the instant the script ends, taking the result with it.
rem
rem Every argument is forwarded, so
rem   install.cmd -InstallDir D:\IlluminaIT -ReEnroll
rem works exactly like the PowerShell call.

setlocal EnableExtensions

rem ------------------------------------------------------------------- elevation
rem `net session` is the cheapest reliable probe: it needs administrative rights and nothing else.
net session >nul 2>&1
if not errorlevel 1 goto :run

rem Not elevated. The sentinel stops an elevation that silently fails from looping for ever.
if /i "%~1"=="--elevated" (
	echo error: still not running as Administrator after elevation was granted.
	echo        Right-click install.cmd and choose "Run as administrator".
	set RC=5
	goto :verdict
)

rem ARGUMENTS ARE NOT FORWARDED THROUGH UAC, deliberately. Re-launching means passing the command
rem line through Start-Process -ArgumentList as one string, where an operator's quoted path
rem (-InstallDir "D:\My Dir") breaks the quoting and arrives mangled or not at all. Dropping an
rem argument silently is worse than not elevating, so a call WITH arguments is refused and a plain
rem double-click - which carries none - is elevated.
if not "%~1"=="" (
	echo error: this installer must run as Administrator.
	echo        Right-click install.cmd and choose "Run as administrator", or run it from an
	echo        elevated prompt. Arguments are not carried through the elevation prompt, so a
	echo        call with arguments is never re-launched behind your back.
	set RC=5
	goto :verdict
)

echo Administrator rights are required. Asking Windows for them...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -ArgumentList '--elevated' -Verb RunAs -WorkingDirectory '%~dp0' -ErrorAction Stop } catch { exit 1 }"
if errorlevel 1 (
	echo.
	echo error: elevation was refused or cancelled - nothing was installed.
	set RC=5
	goto :verdict
)
rem The elevated copy owns the window the operator now watches, and does its own waiting. This one
rem must not wait too: two windows asking for a key is how somebody closes the wrong one.
endlocal
exit /b 0

rem ------------------------------------------------------------------------ run
:run
rem The sentinel is ours and install.ps1 does not know it, so it is never forwarded. It is only ever
rem the whole command line (see above), which is why dropping it needs no argument surgery.
if /i "%~1"=="--elevated" (
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
) else (
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
)
set RC=%ERRORLEVEL%

rem -------------------------------------------------------------------- verdict
rem The exit code in words. The detail scrolled past; this is the line somebody reads.
rem
rem Flat `set` lines and ONE echo, rather than a nested if/else chain: in cmd every `>` inside a
rem parenthesised echo is a redirection unless escaped, so a chain needs the escape right thirteen
rem times and silently writes a file named "INSTALLED." the once it is wrong.
:verdict
set "MSG=exited with code %RC% - see the output above."
if "%RC%"=="0"  set "MSG=INSTALLED. The agent is deployed and enrolled."
if "%RC%"=="1"  set "MSG=FAILED: unexpected error - see the output above."
if "%RC%"=="2"  set "MSG=NOT INSTALLED: usage error in the command line."
if "%RC%"=="3"  set "MSG=NOT INSTALLED: no release is published for this OS/CPU."
if "%RC%"=="4"  set "MSG=NOT INSTALLED: a host prerequisite is missing."
if "%RC%"=="5"  set "MSG=NOT INSTALLED: Administrator rights are required."
if "%RC%"=="6"  set "MSG=NOT INSTALLED: the platform is not reachable from here."
if "%RC%"=="7"  set "MSG=NOT INSTALLED: download or checksum failure."
if "%RC%"=="8"  set "MSG=NOT INSTALLED: the host failed a required check. Add -Force to install anyway."
if "%RC%"=="10" set "MSG=NOT ENROLLED: the bootstrap token was invalid, expired, revoked or already used."
if "%RC%"=="11" set "MSG=NOT ENROLLED: the agent could not reach the platform."
if "%RC%"=="12" set "MSG=NOT ENROLLED: agent configuration error."
if "%RC%"=="13" set "MSG=NOT ENROLLED: the platform answered but refused the enrollment."
echo.
echo ==^> %MSG%
echo.

rem ----------------------------------------------------------------------- wait
rem Wait for a key, or 60 seconds, whichever comes first - so a double-clicked window stays long
rem enough to be read and an unattended one still ends.
rem
rem `timeout` is the only built-in that does BOTH, and it refuses a stdin that is not a console
rem (errorlevel 1 over SSH, in CI, or under any redirection). That is exactly where nobody is
rem waiting anyway, so the fallback is to close immediately rather than to block for ever - a
rem `pause` there would hang an automated install until it was killed.
if defined CI goto :end
if defined AISPM_NO_WAIT goto :end
echo Press any key to close this window - it closes on its own after 60 seconds...
timeout /t 60 >nul 2>&1
if errorlevel 1 echo (no console to wait on - closing)

:end
endlocal & exit /b %RC%
