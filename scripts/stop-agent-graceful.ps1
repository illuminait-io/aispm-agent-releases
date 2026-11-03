<#
.SYNOPSIS
  Stop the AISPM host agent GRACEFULLY (never a hard kill).

.DESCRIPTION
  A graceful stop lets the agent run its shutdown path: flush pending HTTP transactions to the
  JSONL log (tx.Close), then make its in-target hooks INERT and ETERNALIZE them (no Frida detach).
  This is critical: a hard kill (Stop-Process -Force / taskkill /F) skips the flush AND can make
  Frida revert the hooks in a still-hooked LIVE target, crashing/freezing it (e.g. Claude).

  Mechanism: attach to the agent's console and send it CTRL_C_EVENT, which Go delivers as
  os.Interrupt -> the agent's signal.NotifyContext cancels and it shuts down cleanly.

  A SERVICE needs none of that, and is tried FIRST. When the agent is installed as the Windows
  service "aispm-agent", the service control manager's Stop reaches the agent's own service control
  handler, which runs the same shutdown path -- so there is no console to attach to and nothing to
  signal. That is the whole reason the service mode exists: a clean stop that does not depend on
  owning an attachable console.

  REQUIREMENT for the CONSOLE path: the agent must have a CONSOLE. That is true when it was started
  from an interactive console or from Start-Process. It is NOT true for a process created via WMI
  Win32_Process.Create, nor for a SYSTEM Scheduled Task -- a SYSTEM task runs in session 0 and its
  console cannot be attached from an interactive session whatever the caller's privilege (measured;
  AttachConsole returns ERROR_ACCESS_DENIED). For those, use the service.

.PARAMETER ProcessId
  PID of the agent to stop. If omitted, the single running "aispm-agent" process is used. Passing it
  also skips the service path, which is what you want when a console agent runs beside a service.

.PARAMETER TimeoutSeconds
  How long to wait for the agent to exit after signalling (default 25; the freeze/flush paths are
  quick, but a long streaming flush can take a few seconds).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\stop-agent-graceful.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\stop-agent-graceful.ps1 -ProcessId 3300
#>
param(
    [int]$ProcessId = 0,
    [int]$TimeoutSeconds = 25
)

$ErrorActionPreference = 'Stop'

# The service path first, unless a specific pid was named. A running service is the clean case: its
# stop needs no console, honours the agent's own wait hint (four minutes, because releasing
# in-target hooks has a two-minute budget of its own), and cannot be confused by a second install.
if ($ProcessId -eq 0) {
    $svc = Get-Service -Name 'aispm-agent' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Host "The agent runs as the 'aispm-agent' service; stopping it through the service control manager."
        Write-Host "This takes MINUTES, and that is the system working: it is releasing its in-target hooks."
        try { Stop-Service -Name 'aispm-agent' -ErrorAction Stop } catch {
            Write-Warning "Stop-Service reported: $($_.Exception.Message)"
        }
        # Waited out rather than trusted: Stop-Service returns when the SCM accepts the request, not
        # when the service has stopped, and the difference here is minutes.
        $deadline = (Get-Date).AddSeconds(300)
        while ((Get-Date) -lt $deadline) {
            $svc = Get-Service -Name 'aispm-agent' -ErrorAction SilentlyContinue
            if (-not $svc -or $svc.Status -eq 'Stopped') { Write-Host 'Stopped.'; exit 0 }
            Start-Sleep -Seconds 2
        }
        Write-Host "The service has not stopped after 5 minutes. Leave it: do NOT kill it while it has"
        Write-Host "applications instrumented. Check its log, then 'Get-Service aispm-agent'."
        exit 1
    }
}

if ($ProcessId -eq 0) {
    $procs = @(Get-Process -Name 'aispm-agent' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { Write-Host 'No aispm-agent process is running.'; exit 0 }
    if ($procs.Count -gt 1) {
        Write-Host "Multiple aispm-agent processes found (PIDs: $($procs.Id -join ', ')). Re-run with -ProcessId <pid>."
        exit 1
    }
    $ProcessId = $procs[0].Id
}

if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
    Write-Host "No process with PID $ProcessId."; exit 1
}

Add-Type -Namespace Aispm -Name Ctrl -MemberDefinition @'
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint dwProcessId);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(IntPtr HandlerRoutine, bool Add);
    [DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);
'@

$CTRL_C_EVENT = 0

Write-Host "Sending graceful stop (CTRL_C) to aispm-agent PID $ProcessId ..."

# Detach our own console, then borrow the agent's so the console-control event reaches it.
[void][Aispm.Ctrl]::FreeConsole()
if (-not [Aispm.Ctrl]::AttachConsole([uint32]$ProcessId)) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Host ""
    Write-Host "AttachConsole failed (Win32 error $err) -- the agent has no console (likely started via WMI Win32_Process.Create)."
    Write-Host "Graceful fallbacks:"
    Write-Host "  1) Quit the hooked app (e.g. Claude) first -- that flushes its transactions (Release/flushConns)."
    Write-Host "     Only THEN is 'Stop-Process -Id $ProcessId' safe (no live target left to crash)."
    Write-Host "  2) Or relaunch the agent from a console / Start-Process / Scheduled Task so this script can signal it."
    exit 2
}

# Make THIS process ignore the Ctrl+C we are about to broadcast to the shared console.
[void][Aispm.Ctrl]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
$sent = [Aispm.Ctrl]::GenerateConsoleCtrlEvent($CTRL_C_EVENT, 0)
Start-Sleep -Milliseconds 300
# Restore our own console state.
[void][Aispm.Ctrl]::FreeConsole()
[void][Aispm.Ctrl]::SetConsoleCtrlHandler([IntPtr]::Zero, $false)

if (-not $sent) {
    Write-Host 'GenerateConsoleCtrlEvent failed. The agent may not have received the signal.'
    exit 3
}

# Wait for a clean exit.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
    Start-Sleep -Milliseconds 500
}

if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
    Write-Host "Agent PID $ProcessId still running after ${TimeoutSeconds}s. Do NOT hard-kill it while a target is hooked."
    Write-Host "Quit the hooked app first, then it is safe to Stop-Process."
    exit 4
}

Write-Host "Agent PID $ProcessId stopped gracefully (transactions flushed, hooks eternalized -- target not detached)."
exit 0
