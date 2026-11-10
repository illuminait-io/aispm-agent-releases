<#
.SYNOPSIS
  AISPM host agent installer (Windows).

.DESCRIPTION
  Two modes, same script:
    package   - run from the unzipped installer package; reads installer.conf + bootstrap.token
                sitting next to this script.
    one-liner - one line, from an elevated cmd.exe or PowerShell, nothing written to disk:
                  powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((iwr -UseBasicParsing '<platform>/aispm/api/v1/agent/install.ps1').Content)) -PlatformUrl '<platform>'"
                With no -Token/-TokenFile the token is asked for in the console, hidden, so the
                line an operator pastes carries no secret; add -Token '...' to run unattended.
                The CHILD powershell is not optional: this script ends with `exit <code>`, and a
                scriptblock run directly in your own console (iex, or & on it) has no script scope
                for `exit` to end — it closes the console instead, taking the error with it. The
                child exits with the code below and leaves it in $LASTEXITCODE / %ERRORLEVEL%.

  It detects the architecture, checks the prerequisites, lays out the install directory, downloads
  the binary and the configuration for the resolved release (SHA256 verified), gates on the agent's
  own preflight, enrols the host, and prints the exact command to run it.

  A WINDOWS SERVICE IS THE DEFAULT, and -Console is how you ask for the other thing.

  The default is the arrangement a real host needs, so it is the one you get without choosing: the
  service starts at boot, the SCM restarts it after a failure, and Stop-Service is a clean stop the
  agent handles itself (it implements the service control handler, so the SCM's Stop reaches its
  shutdown path and its in-target hooks are released properly — which a Scheduled Task cannot do).
  A console agent does not survive a reboot and cannot be restarted after an automatic update, so it
  was never the right default: an installer whose easiest path leaves an agent that dies at the next
  reboot is an installer that produces dead hosts.

  -Console installs the files, enrols the host and prints the command to run, registering no service.
  For a laptop you are debugging on, a container, or a host where you want the agent in the
  foreground. On a host that already has the service, -Console REMOVES it rather than leaving both:
  only one agent may run at a time (two would stack hooks on the same target and crash it), so a
  service and a console command for the same host is not a choice, it is a trap.

  -Service and -NoService are still accepted, undocumented, so the one-liners and scripts already in
  the field keep working: -Service now asserts the default and -NoService means -Console. Prefer
  -Console in anything new.

  THE PREREQUISITES BLOCK A FIRST INSTALL AND NEVER BLOCK AN UPGRADE.

  On a host the platform does not know yet, a failed check stops the installation: nothing is
  deployed, an operator is reading the output, and the cheapest moment to refuse a host is before it
  holds a credential. -Force installs anyway and makes the listed consequences this host's.

  On a host that already runs an agent (an enrolled credential, or a registered service) a failed
  check NEVER stops the installation. Refusing would leave the OLD binary in place over a condition
  the new one handles by degrading — it narrows what it does, keeps reporting, and says `degraded` on
  every heartbeat — and on a host nobody is watching, a blocked upgrade is an invisible non-event.

  Either way the failed checks, their consequence and their remediation are printed AND written to
  logs\install-preflight.log, because the one outcome that must never happen is a host left in a
  state nobody can explain later.

  -Uninstall stops the agent gracefully and deletes the install directory, removing the service first
  if there is one. It needs no token and no -PlatformUrl. Revoke the agent's key in the console
  afterwards: the files are gone, the credential it held was still valid.

  Exit codes. Below 10 the installer itself failed; 10 and above are the agent's frozen enrollment
  codes, passed through unchanged (see docs/installer-distribution-plan.md section 2c):
    0  installed (and enrolled)      7  download or checksum failure
    1  unexpected failure            8  the agent's preflight refused this host
    2  usage error                   10 bootstrap token invalid/expired/revoked/used
    3  OS/arch not published         11 platform unreachable from the agent
    4  a prerequisite is missing     12 agent configuration error
    5  not running as Administrator  13 platform reachable but unable to enrol
    6  the platform is not reachable
#>
[CmdletBinding()]
param(
	[string]$PlatformUrl,
	[string]$Token,
	[string]$TokenFile,
	[string]$Version,
	[string]$Channel,
	[string]$ManifestUrl,
	[string]$InstallDir,
	[switch]$ReEnroll,
	[switch]$Uninstall,
	[switch]$Console,
	[switch]$Force,
	# Compatibility, deliberately undocumented: -Service asserts what is now the default and
	# -NoService is -Console. Kept because removing a switch does not deprecate it, it makes every
	# invocation that carries it die on "A parameter cannot be found" — which is exactly how a stale
	# vendored copy of this script broke `install.cmd -Service` in the field once already.
	[switch]$Service,
	[switch]$NoService
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Invoke-WebRequest's progress bar makes large downloads an order of magnitude slower on PS 5.1.
$ProgressPreference = 'SilentlyContinue'

$EX_OK = 0; $EX_FAIL = 1; $EX_USAGE = 2; $EX_UNSUPPORTED = 3; $EX_PREREQ = 4
$EX_PRIVILEGE = 5; $EX_PLATFORM = 6; $EX_DOWNLOAD = 7; $EX_PREFLIGHT = 8

$ReleasesOwner = if ($env:AISPM_RELEASES_OWNER) { $env:AISPM_RELEASES_OWNER } else { 'illuminait-io' }
$ReleasesRepo = 'aispm-agent-releases'
$DefaultChannel = 'stable'
$InstallRootDefault = 'C:\IlluminaIT'
$AgentBin = 'aispm-agent.exe'
# StopScriptName is both the manifest's tools key and the file's name on the host: the closing
# instructions print its installed path, so the two must be the same string.
$StopScriptName = 'stop-agent-graceful.ps1'
$IncompleteMarker = '.install-incomplete'
$PingPath = '/aispm/api/v1/agent/ping'
# Free-space floor. Same default as the agent's own preflight.min_free_disk_mb (2 GiB), so the
# installer refuses before downloading rather than letting the agent refuse after.
# AISPM_MIN_FREE_DISK_MB overrides both: applied here AND seeded into agent.yaml.
$MinFreeDiskMB = if ($env:AISPM_MIN_FREE_DISK_MB) { [int]$env:AISPM_MIN_FREE_DISK_MB } else { 2048 }

function Say  { param([string]$m) Write-Host "  $m" }
function Step { param([string]$m) Write-Host ""; Write-Host "==> $m" }
function Warn { param([string]$m) Write-Warning $m }
function Die  { param([int]$code, [string]$m) Write-Host "error: $m" -ForegroundColor Red; exit $code }

# ---------------------------------------------------------------- Windows service helpers
#
# The agent implements the service control handler (cmd/aispm-agent/service_windows.go), which is
# what makes a service viable here at all. The older note in docs/backlog.md said the SCM's stop
# "is not delivered to a Go process" — true of a console binary the SCM merely launches, and false
# of one that answers the SCM. A Scheduled Task remains unusable for a different, measured reason:
# a SYSTEM task runs in session 0 and its console cannot be attached from an interactive session,
# so CTRL_C_EVENT can never reach it.

$ServiceName = 'aispm-agent'

function Get-AgentService {
	Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
}

# Stop-AgentService waits for the service to reach Stopped, and waits LONG.
#
# The agent's clean stop releases its in-target hooks with a two-minute budget of its own, because a
# hook left live when the process disappears is reverted by Frida's teardown inside somebody else's
# application and crashes it. So a stop that takes minutes is the system working, not hanging, and
# anything here that gave up early and escalated would be the exact hard kill this whole arrangement
# exists to avoid.
function Stop-AgentService {
	param([int]$TimeoutSeconds = 300)
	$svc = Get-AgentService
	if (-not $svc) { return $true }
	if ($svc.Status -eq 'Stopped') { return $true }
	Say "stopping the $ServiceName service (this takes minutes: it is releasing its in-target hooks)"
	try { Stop-Service -Name $ServiceName -ErrorAction Stop } catch {
		Warn "Stop-Service reported: $($_.Exception.Message)"
	}
	$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
	while ((Get-Date) -lt $deadline) {
		$svc = Get-AgentService
		if (-not $svc -or $svc.Status -eq 'Stopped') { Say "stopped"; return $true }
		Start-Sleep -Seconds 2
	}
	return $false
}

function Register-AgentService {
	param([string]$BinPath, [string]$ConfigDir)
	$existing = Get-AgentService
	$binLine = '"{0}" -config "{1}"' -f $BinPath, $ConfigDir
	if ($existing) {
		Say "the $ServiceName service already exists; pointing it at this install"
		# sc.exe rather than Set-Service: binPath= is not settable through Set-Service on PS 5.1.
		& sc.exe config $ServiceName binPath= $binLine start= auto | Out-Null
		if ($LASTEXITCODE -ne 0) { Die $EX_FAIL "could not reconfigure the $ServiceName service (sc config exited $LASTEXITCODE)" }
	} else {
		Say "registering the $ServiceName service (automatic start)"
		& sc.exe create $ServiceName binPath= $binLine start= auto DisplayName= "AISPM host agent" | Out-Null
		if ($LASTEXITCODE -ne 0) { Die $EX_FAIL "could not create the $ServiceName service (sc create exited $LASTEXITCODE)" }
		& sc.exe description $ServiceName "Discovers AI usage on this host and reports it to the AISPM platform." | Out-Null
	}

	# Restart after a failure, with BACKOFF: 5 seconds, then 30, then every 5 minutes, counter reset
	# after a day. Must stay identical to ensureServiceRecovery in cmd/aispm-agent/service_windows.go,
	# which re-applies it at every service start — two different policies here would mean the host
	# behaved differently before and after its first successful start.
	#
	# It was three restarts five seconds apart, which capped nothing: the SCM repeats the LAST action
	# for every subsequent failure inside the reset period, so a host that could not start restarted
	# 10 965 times in nineteen hours and wrote ~85 MB of log onto the volume whose fullness was the
	# problem. Backoff and not a cap, because a supervisor that gives up leaves a host with no agent
	# and no way to say so.
	& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/30000/restart/300000 | Out-Null
	if ($LASTEXITCODE -ne 0) { Warn "could not set the service recovery actions (sc failure exited $LASTEXITCODE)" }

	# AND make those actions apply to a NON-CRASH failure. Without this flag Windows treats an
	# orderly stop with a non-zero exit code as a stop rather than a failure — so the agent's
	# restart-after-update exit would be honoured by systemd and launchd and silently ignored here,
	# leaving the host with a new binary and nothing running it. The agent also sets this itself at
	# every service start, because a service somebody created by hand will not have it.
	& sc.exe failureflag $ServiceName 1 | Out-Null
	if ($LASTEXITCODE -ne 0) { Warn "could not make the recovery actions apply to a non-crash failure (sc failureflag exited $LASTEXITCODE): an automatic update may leave this host without a running agent" }
}

function Unregister-AgentService {
	if (-not (Get-AgentService)) { return }
	if (-not (Stop-AgentService)) {
		Die $EX_FAIL "the $ServiceName service did not stop. Leave it to finish and re-run -Uninstall; do NOT kill it while it has applications instrumented."
	}
	Say "removing the $ServiceName service"
	& sc.exe delete $ServiceName | Out-Null
	if ($LASTEXITCODE -ne 0) { Warn "could not delete the $ServiceName service (sc delete exited $LASTEXITCODE); remove it with 'sc.exe delete $ServiceName'" }
}

# Read-BootstrapToken asks for the token in the console, hidden. It is what lets the one-liner
# carry no secret: the token is typed, not pasted into a command the shell history keeps. Under
# -NonInteractive, or in a host with no console, Read-Host throws — there is nobody to ask, and
# that is a usage error, said as such. The SecureString round trip is the PS 5.1-compatible way to
# hide input; ConvertFrom-SecureString -AsPlainText is 7+ only.
function Read-BootstrapToken {
	try {
		$secure = Read-Host -Prompt 'Bootstrap token (from Agents Fleet -> Deploy agent, or POST /aispm/api/v1/agent/admin/bootstrap-tokens; input hidden)' -AsSecureString
	} catch {
		Die $EX_USAGE "no bootstrap token: pass -Token or -TokenFile, or run from an interactive console to be asked for it ($($_.Exception.Message))"
	}
	$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
	try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
	finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
	if (-not $plain -or -not $plain.Trim()) { Die $EX_USAGE "empty bootstrap token" }
	return $plain.Trim()
}

# TLS 1.2 floor: PS 5.1 still defaults to SSL3/TLS1 on older images, which no platform accepts.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ------------------------------------------------------------------- uninstall
if ($Uninstall) {
	if (-not $InstallDir) { $InstallDir = $InstallRootDefault }
	$id = [Security.Principal.WindowsIdentity]::GetCurrent()
	if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
		Die $EX_PRIVILEGE "uninstalling needs Administrator ($InstallDir and its ACLs are not yours to remove otherwise): re-open PowerShell with 'Run as administrator'"
	}

	Step "Stopping the agent"
	# The service first, if there is one: it owns the process, so stopping the process without
	# removing the service would simply have it started again by the recovery action.
	Unregister-AgentService

	# Then any agent running from THIS install outside the service: matched by the executable it
	# runs from, not by its name.
	# A host can hold a second install (a staging copy, a developer build) and taking that one down
	# — or refusing to proceed because of it — would be acting on a process nobody asked about.
	$agentPath = Join-Path $InstallDir $AgentBin
	$agent = @(Get-Process -Name 'aispm-agent' -ErrorAction SilentlyContinue |
		Where-Object { $_.Path -and ($_.Path -ieq $agentPath) })
	if ($agent.Count -eq 0) {
		Say "no running agent found"
	} else {
		# Graceful only. A hard kill skips the pending-transaction flush AND can make Frida revert
		# hooks inside a still-hooked LIVE application, crashing it — so this never escalates on the
		# operator's behalf. If the graceful path is unavailable, it says so and stops.
		$stopper = Join-Path $InstallDir $StopScriptName
		if (Test-Path -LiteralPath $stopper) {
			foreach ($p in $agent) {
				Say "signalling pid $($p.Id) through $StopScriptName"
				& powershell -NoProfile -ExecutionPolicy Bypass -File $stopper -ProcessId $p.Id
			}
		} else {
			Die $EX_FAIL ("the agent is running (pid " + ($agent.Id -join ', ') + ") and $stopper is not here to stop it gracefully. Press Ctrl+C in the agent's own console, then re-run -Uninstall. Do NOT 'Stop-Process -Force' while it has applications instrumented.")
		}
		Start-Sleep -Seconds 2
		$still = @(Get-Process -Name 'aispm-agent' -ErrorAction SilentlyContinue |
			Where-Object { $_.Path -and ($_.Path -ieq $agentPath) })
		if ($still.Count -gt 0) {
			Die $EX_FAIL ("the agent is still running (pid " + ($still.Id -join ', ') + "). Leave it to finish and re-run -Uninstall.")
		}
		Say "stopped"
	}

	Step "Removing $InstallDir"
	if (Test-Path -LiteralPath $InstallDir) {
		# Refuse a path that is obviously not an install root rather than recursing into it.
		$resolved = (Resolve-Path -LiteralPath $InstallDir).Path.TrimEnd('\')
		$guarded = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
			$env:SystemDrive + '\', $env:SystemDrive + '\Users') | Where-Object { $_ }
		foreach ($g in $guarded) {
			if ($resolved -eq $g.TrimEnd('\')) { Die $EX_USAGE "-InstallDir '$InstallDir' is a system directory; refusing to delete it" }
		}
		# The injector staging directory can outlive the agent, and that is not a fault.
		#
		# Frida stages the library it asks each target to load under the install root, and the target
		# keeps it MAPPED for its own lifetime — hooks are eternalised rather than reverted, because
		# reverting one inside a live application crashes it. So while an instrumented application is
		# still running, frida-agent.dll cannot be deleted and `Remove-Item -Recurse` fails partway,
		# leaving the install root half gone with no explanation.
		#
		# Everything else is removed, and what is left is named along with the reason and the remedy:
		# it disappears on its own when those applications exit or the host reboots.
		Remove-Item -Recurse -Force -LiteralPath $InstallDir -ErrorAction SilentlyContinue
		if (Test-Path -LiteralPath $InstallDir) {
			$stuck = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -File -ErrorAction SilentlyContinue)
			$dll = @($stuck | Where-Object { $_.Name -like 'frida-agent*' })
			if ($dll.Count -gt 0) {
				Say "removed, except the injected library still mapped by instrumented applications:"
				foreach ($f in $dll) { Say "  $($f.FullName)" }
				Say "that is expected: those applications keep it loaded until they exit. It goes on its own"
				Say "when they do, or at the next reboot. Nothing needs to be done about it."
			} else {
				Warn "$InstallDir could not be fully removed; what is left:"
				foreach ($f in $stuck | Select-Object -First 10) { Warn "  $($f.FullName)" }
			}
		} else {
			Say "removed"
		}
	} else {
		Say "$InstallDir does not exist"
	}

	Write-Host ""
	Write-Host "==> Uninstalled: the agent is stopped and $InstallDir is gone."
	Write-Host ""
	Write-Host "  ONE STEP IS LEFT, and it is not on this host: revoke this agent in the console"
	Write-Host "  (Agents Fleet -> the agent's row -> Revoke key, or Forget it to drop its history too)."
	Write-Host ""
	Write-Host "  Deleting the files did NOT invalidate its credential. Until you revoke it, anything"
	Write-Host "  holding a copy of the credential.json that was in $InstallDir\config can keep"
	Write-Host "  reporting as this host."
	Write-Host ""
	exit $EX_OK
}

# ---------------------------------------------------------------- package mode
$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$confPath = Join-Path $here 'installer.conf'
if (Test-Path -LiteralPath $confPath) {
	Say "using $confPath"
	$conf = @{}
	foreach ($line in Get-Content -LiteralPath $confPath) {
		if ($line -match '^\s*([A-Za-z][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$') { $conf[$Matches[1]] = $Matches[2] }
	}
	if (-not $PlatformUrl -and $conf.ContainsKey('platformUrl')) { $PlatformUrl = $conf['platformUrl'] }
	if (-not $Channel     -and $conf.ContainsKey('channel'))     { $Channel = $conf['channel'] }
	if (-not $Version     -and $conf.ContainsKey('agentVersion')) { $Version = $conf['agentVersion'] }
	if (-not $ManifestUrl -and $conf.ContainsKey('manifestUrl')) { $ManifestUrl = $conf['manifestUrl'] }
}
$packagedToken = Join-Path $here 'bootstrap.token'
if (-not $Token -and -not $TokenFile -and (Test-Path -LiteralPath $packagedToken)) { $TokenFile = $packagedToken }
if (-not $Token -and -not $TokenFile) { $Token = Read-BootstrapToken }

if (-not $Channel) { $Channel = $DefaultChannel }
if (-not $InstallDir) { $InstallDir = $InstallRootDefault }
if (-not $PlatformUrl) { Die $EX_USAGE "-PlatformUrl is required (or provide installer.conf next to this script)" }
if ($PlatformUrl -notmatch '^https://') { Die $EX_USAGE "-PlatformUrl must be an https URL, got '$PlatformUrl'" }

# Contradictory switches are refused HERE, with the other argument validation, and not where the
# arrangement is decided: that happens at step 8, after ~190 MB has been downloaded and the host has
# enrolled. Spending all of that to then reject the command line is the wrong order, and the longer
# the switch list grows the likelier somebody is to find out the slow way.
if ($Service -and ($Console -or $NoService)) {
	Die $EX_USAGE "-Service contradicts -Console: a service is the default, so pass neither to get one"
}
$PlatformUrl = $PlatformUrl.TrimEnd('/')

# --------------------------------------------------------------- 1. os / arch
Step "Detecting the architecture"
switch ($env:PROCESSOR_ARCHITECTURE) {
	'AMD64' { $arch = 'amd64' }
	'ARM64' { $arch = 'arm64' }
	'x86'   { Die $EX_UNSUPPORTED "32-bit Windows is not supported (the agent is published for amd64 and arm64)" }
	default { Die $EX_UNSUPPORTED "unsupported architecture '$($env:PROCESSOR_ARCHITECTURE)'" }
}
$os = 'windows'
Say "$os/$arch"

# ----------------------------------------------------- 2. prerequisites, privileges
Step "Checking the prerequisites"
# Administrator is required, not advisory: the agent's own preflight treats missing elevation as a
# FATAL check, so a non-elevated install would produce an agent that cannot start.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	Die $EX_PRIVILEGE "this installer must run as Administrator (the agent needs it to observe processes and traffic): re-open PowerShell with 'Run as administrator' and re-run"
}
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
	Die $EX_PREREQ "tar.exe is required to unpack the configuration bundle (it ships with Windows 10 1803+ and Server 2019+)"
}

$driveRoot = [IO.Path]::GetPathRoot($InstallDir)
try {
	$free = (Get-PSDrive -Name $driveRoot.TrimEnd(':\') -ErrorAction Stop).Free
	if ($free -lt ($MinFreeDiskMB * 1MB)) {
		Die $EX_PREREQ ("not enough free space on {0}: {1} MiB available, {2} MiB required. The agent writes its rotating agent log, its rotating transaction/connection logs and its credential here - free up space, choose another -InstallDir, or lower the floor with AISPM_MIN_FREE_DISK_MB" -f $driveRoot, [int]($free/1MB), $MinFreeDiskMB)
	}
} catch { Warn "could not determine the free space on $driveRoot" }
Say "Administrator, tar.exe, free space (>= $MinFreeDiskMB MiB): ok"

Step "Checking that the platform is reachable"
# A strict 200 on the liveness endpoint. Any other answer means the URL reaches something that is
# not the agent API - typically a reverse proxy or load balancer that does not route
# /aispm/api/v1/agent/ - which is exactly the misconfiguration worth catching before enrolling.
$pingUrl = "$PlatformUrl$PingPath"
$pingCode = 0
try {
	$resp = Invoke-WebRequest -Uri $pingUrl -UseBasicParsing -Method Get -TimeoutSec 15
	$pingCode = [int]$resp.StatusCode
} catch {
	if ($_.Exception.Response) { $pingCode = [int]$_.Exception.Response.StatusCode } else { $pingCode = 0 }
}
if ($pingCode -eq 200) {
	Say "$pingUrl -> 200"
} elseif ($pingCode -eq 0) {
	Die $EX_PLATFORM "cannot reach $PlatformUrl : check the URL, DNS, egress rules and TLS trust from this host (set HTTPS_PROXY if this host needs a proxy)"
} else {
	Die $EX_PLATFORM "$pingUrl answered HTTP $pingCode, not 200: the URL does not reach the agent API (wrong host, or a proxy that does not route /aispm/api/v1/agent/)"
}

# ------------------------------------------------------------- 3. release resolution
Step "Resolving the release"
function Fetch-Json { param([string]$url)
	# Retried: the channel file is served through a CDN that can briefly 404 or serve a stale copy
	# right after a release is cut (observed). One transient 404 must not be reported to the
	# operator as "this release channel does not exist".
	$lastErr = $null
	for ($i = 1; $i -le 3; $i++) {
		try {
			# GitHub serves release assets as application/octet-stream, so under Windows
			# PowerShell 5.1 .Content is a Byte[] (not a string) and Byte[] | ConvertFrom-Json
			# silently yields $null — the manifest would parse to nothing and the installer would
			# report "no version field". Decode to UTF-8 text before parsing.
			$content = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60).Content
			if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
			$parsed = $content | ConvertFrom-Json
			if (-not $parsed) { throw "empty or unparseable JSON" }
			return $parsed
		} catch {
			$lastErr = $_.Exception.Message
			if ($i -lt 3) { Start-Sleep -Seconds ($i * 3) }
		}
	}
	Die $EX_DOWNLOAD "cannot fetch $url ($lastErr)"
}
if (-not $ManifestUrl) {
	if ($Version) {
		$ManifestUrl = "https://github.com/$ReleasesOwner/$ReleasesRepo/releases/download/v$Version/manifest.json"
	} else {
		# One flat file per channel on the distribution repo's main branch: channel.json for
		# stable, channel-<name>.json for any other. AISPM_CHANNEL_URL overrides it for internal
		# mirrors and for testing this script.
		$channelFile = if ($Channel -eq $DefaultChannel) { 'channel.json' } else { "channel-$Channel.json" }
		$channelUrl = if ($env:AISPM_CHANNEL_URL) { $env:AISPM_CHANNEL_URL } else { "https://raw.githubusercontent.com/$ReleasesOwner/$ReleasesRepo/main/$channelFile" }
		Say "channel '$Channel' via $channelUrl"
		$channelDoc = Fetch-Json $channelUrl
		$Version = $channelDoc.version
		$ManifestUrl = $channelDoc.manifestUrl
		# A bootstrapped channel file carries nulls until the first release is cut.
		if (-not $ManifestUrl) { Die $EX_FAIL "release channel '$Channel' has no published release yet (no manifest in $channelUrl) - pin a version with -Version, or wait for the first release" }
	}
}
$manifest = Fetch-Json $ManifestUrl
if (-not $manifest.version) { Die $EX_FAIL "the manifest at $ManifestUrl has no version field" }
if ($Version -and $Version -ne $manifest.version) { Warn "requested version $Version, manifest describes $($manifest.version)" }
$Version = $manifest.version
Say "agent $Version (channel $Channel)"

# Fail before downloading anything if this platform was never published: the manifest is the
# authority on what exists, which is the whole reason resolution goes through it.
$key = "$os/$arch"
if (-not $manifest.artifacts.PSObject.Properties[$key]) {
	Die $EX_UNSUPPORTED "no agent binary published for $key in release $Version - the manifest lists no such artifact (ask for this platform, or install on a supported one)"
}
$artifact = $manifest.artifacts.$key
if (-not $artifact.url -or -not $artifact.sha256) { Die $EX_FAIL "the manifest entry for $key is missing its url or sha256" }

# The configuration is NOT optional: the agent has no compiled-in catalogues, so an empty config\
# yields an agent that starts, warns, and classifies nothing.
if (-not $manifest.PSObject.Properties['config'] -or -not $manifest.config) {
	Die $EX_FAIL "release $Version publishes no configuration bundle; the agent cannot classify anything without it"
}
if (-not $manifest.config.url -or -not $manifest.config.sha256) { Die $EX_FAIL "the manifest's config entry is missing its url or sha256" }

# ------------------------------------------------------------ 4. directory layout
Step "Preparing $InstallDir"
$configDir = Join-Path $InstallDir 'config'
$logsDir = Join-Path $InstallDir 'logs'
foreach ($d in @($InstallDir, $configDir, $logsDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# Lock the install tree down to Administrators and SYSTEM, and stop inheriting from the drive.
#
# Measured on a fleet host 2026-10-21: agent.yaml, config\credential.json AND logs\http.jsonl were
# all readable by BUILTIN\Users and NT AUTHORITY\Authenticated Users, because the directories
# inherited C:\'s ACL. credential.json holds the agent's API key to the platform, and http.jsonl
# held thousands of third-party session tokens in clear - 8 079 lines on that host alone. Any
# local user could read both.
#
# Well-known SIDs, not names: "BUILTIN\Administrators" is localised (Administrateurs, Administratoren)
# and a name-based rule silently matches nothing on a non-English Windows - which would leave the
# tree wide open while the installer reported success.
$acl = Get-Acl -Path $InstallDir
$acl.SetAccessRuleProtection($true, $false)   # break inheritance, drop the inherited entries
foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {   # Administrators, LOCAL SYSTEM
	$id = New-Object System.Security.Principal.SecurityIdentifier($sid)
	$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
		$id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
}
try {
	Set-Acl -Path $InstallDir -AclObject $acl
	Say "restricted $InstallDir to Administrators and SYSTEM"
} catch {
	# Not fatal: the agent runs and captures. But it must be said, because the failure is
	# invisible otherwise and leaves credentials readable by every local user.
	Warn "could not restrict the permissions of ${InstallDir}: $($_.Exception.Message) - the agent's credential and logs stay readable by local users"
}
# The config dir stays writable for the agent itself: credential.json, host.json, the identity
# salt and the keylog cache all live there.
New-Item -ItemType File -Force -Path (Join-Path $configDir $IncompleteMarker) | Out-Null
Say "$InstallDir\$AgentBin, $configDir, $logsDir"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aispm-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
	function Get-Verified { param([string]$url, [string]$sha256, [string]$dest, [string]$label)
		Say $url
		# The agent is ~190 MB: TimeoutSec here bounds the whole transfer, so it has to allow for a
		# slow link rather than a fast one.
		try { Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $dest -TimeoutSec 3600 }
		catch { Die $EX_DOWNLOAD "cannot download $label from $url ($($_.Exception.Message))" }
		$got = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLower()
		if ($got -ne $sha256.ToLower()) {
			Die $EX_DOWNLOAD "$label failed its checksum: expected $($sha256.ToLower()), got $got (corrupted download, or a tampered artifact - do not run it)"
		}
	}

	# --------------------------------------------------------------- 5. binary + config
	# An UPGRADE is a re-run of this installer on a host that already has an agent, and on Windows a
	# running .exe cannot be replaced. Measured on WIN11 (.106, 2026-10-12) against a process proven
	# to be holding the image: `Move-Item -Force` fails with "Cannot create a file when that file
	# already exists" — it deletes then renames, and the delete is what the running image refuses, so
	# the error names the leftover destination rather than the sharing violation underneath. Caught
	# here, BEFORE the download, so a re-run on a live host fails in two seconds with something to act
	# on rather than after ~190 MB.
	#
	# Renaming the old .exe ASIDE does work (measured in the same run), and it would let the install
	# complete. It is deliberately not done: the running agent would keep executing the old image with
	# nothing saying so, which is the failure this same change fixed on Linux, where `systemctl start`
	# was a no-op on a live unit while the installer printed "started". A host silently reporting its
	# previous version is worse than an install that stops and says why. It would also leave a ~190 MB
	# stale binary behind on every upgrade.
	#
	# It refuses instead of stopping the agent, for the reason -Uninstall refuses: the graceful stop
	# needs the agent's own console, this installer does not have it, and a hard kill can crash the
	# applications the agent had instrumented. Whoever owns that console decides.
	#
	# A SERVICE changes this, and it is the main practical gain of the service mode: the SCM has a
	# clean stop this installer can ask for and wait on, so an upgrade stops the service, replaces
	# the binary and starts it again. The refusal below now applies only to a console agent, whose
	# graceful stop needs its own console — which this installer does not have.
	$existingService = Get-AgentService
	$svcWasRunning = $false
	if ($existingService -and $existingService.Status -ne 'Stopped') {
		$svcWasRunning = $true
		Step "Stopping the $ServiceName service to replace its binary"
		if (-not (Stop-AgentService)) {
			Die $EX_FAIL "the $ServiceName service did not stop, so its .exe cannot be replaced. Leave it to finish and re-run this installer; do NOT kill it while it has applications instrumented."
		}
	}

	$runningHere = @(Get-Process -Name 'aispm-agent' -ErrorAction SilentlyContinue |
		Where-Object { $_.Path -and ($_.Path -ieq (Join-Path $InstallDir $AgentBin)) })
	if ($runningHere.Count -gt 0) {
		$stopHint = Join-Path $InstallDir $StopScriptName
		$how = if (Test-Path -LiteralPath $stopHint) { "powershell -ExecutionPolicy Bypass -File '$stopHint'" } else { "Ctrl+C in its console" }
		Die $EX_FAIL ("an agent from $InstallDir is already running (pid " + ($runningHere.Id -join ', ') +
			"), and Windows will not let its .exe be replaced while it runs. Stop it CLEANLY first ($how), " +
			"then re-run this installer. Never 'Stop-Process -Force': it can crash the applications it instrumented.")
	}

	Step "Downloading the agent"
	$binTmp = Join-Path $tmp $AgentBin
	Get-Verified $artifact.url $artifact.sha256 $binTmp "the agent binary"
	Move-Item -Force -LiteralPath $binTmp -Destination (Join-Path $InstallDir $AgentBin)
	Say "installed $InstallDir\$AgentBin (sha256 verified)"

	# The graceful stop belongs on the host: the closing instructions name it, and a hard kill is not
	# an acceptable substitute — it skips the pending-transaction flush AND can make Frida revert
	# hooks in a still-hooked LIVE target, crashing it (docs/frida-detach-crash.md). Never fatal: a
	# release published before tools existed still installs, and the fallback (Ctrl+C in the agent's
	# own console) is printed at the end either way.
	$stopScriptPath = $null
	if ($manifest.PSObject.Properties['tools'] -and $manifest.tools -and
			$manifest.tools.PSObject.Properties[$StopScriptName]) {
		$tool = $manifest.tools.$StopScriptName
		if ($tool.url -and $tool.sha256) {
			Step "Installing the graceful-stop script"
			$toolTmp = Join-Path $tmp $StopScriptName
			Get-Verified $tool.url $tool.sha256 $toolTmp "the graceful-stop script"
			$stopScriptPath = Join-Path $InstallDir $StopScriptName
			Move-Item -Force -LiteralPath $toolTmp -Destination $stopScriptPath
			Say "installed $stopScriptPath (sha256 verified)"
		} else {
			Warn "release $Version lists $StopScriptName without a url or sha256; stopping the agent will rely on Ctrl+C in its own console"
		}
	} else {
		Warn "release $Version publishes no $StopScriptName; stopping the agent will rely on Ctrl+C in its own console"
	}

	Step "Installing the configuration"
	$cfgTmp = Join-Path $tmp 'config.tar.gz'
	Get-Verified $manifest.config.url $manifest.config.sha256 $cfgTmp "the configuration bundle"
	$cfgExtract = Join-Path $tmp 'config'
	New-Item -ItemType Directory -Force -Path $cfgExtract | Out-Null
	& tar.exe -xzf $cfgTmp -C $cfgExtract
	if ($LASTEXITCODE -ne 0) { Die $EX_FAIL "cannot unpack the configuration bundle" }
	# Default catalogues are versioned with the binary and always refreshed; anything an operator
	# may have edited (agent.yaml, *.custom.yaml) is installed only when absent. A bundled
	# agent.yaml lands as a REFERENCE only - the live one is written below with this platform's
	# URL and token path.
	foreach ($f in Get-ChildItem -LiteralPath $cfgExtract -File) {
		# Skip AppleDouble side files: a bundle ever packed on macOS carries ._* siblings, and
		# copying them into config\ leaves junk the agent would scan (deploy-windows.ps1 filters
		# them for the same reason).
		if ($f.Name -like '._*') { continue }
		$target = Join-Path $configDir $f.Name
		if ($f.Name -like '*.default.yaml') {
			Copy-Item -Force -LiteralPath $f.FullName -Destination $target
		} elseif ($f.Name -eq 'agent.yaml' -or $f.Name -eq 'agent.yaml.example') {
			Copy-Item -Force -LiteralPath $f.FullName -Destination (Join-Path $configDir 'agent.yaml.example')
		} elseif (-not (Test-Path -LiteralPath $target)) {
			Copy-Item -LiteralPath $f.FullName -Destination $target
		}
	}
	Say "catalogues installed in $configDir"

	# ------------------------------------------------------------------- 6. token
	$tokenPath = Join-Path $configDir 'bootstrap.token'
	if ($TokenFile) {
		if (-not (Test-Path -LiteralPath $TokenFile)) { Die $EX_USAGE "-TokenFile '$TokenFile' does not exist" }
		Copy-Item -Force -LiteralPath $TokenFile -Destination $tokenPath
	} elseif ($Token) {
		Set-Content -LiteralPath $tokenPath -Value $Token -Encoding ASCII
	}
	if (Test-Path -LiteralPath $tokenPath) {
		# The token is a credential: drop inheritance and leave only SYSTEM and Administrators.
		# There is no umask on Windows, so this is the equivalent of the 0600 used elsewhere.
		& icacls.exe $tokenPath /inheritance:r /grant:r "*S-1-5-18:(F)" "*S-1-5-32-544:(F)" | Out-Null
		if ($LASTEXITCODE -ne 0) { Warn "could not restrict the ACL on $tokenPath - check it manually" }
	}

	if (-not (Test-Path -LiteralPath (Join-Path $configDir 'agent.yaml'))) {
		$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
		# The logging settings are seeded, not left to the run command: it makes the preflight
		# below exercise the FATAL log-writable check (which only exists when logging.output is a
		# file), so an unwritable log directory is caught here instead of at the operator's first
		# launch. It also keeps truncate off - the default empties the log at every start.
		@(
			"# Written by install.ps1 $stamp - agent $Version",
			"platform:",
			"  url: $PlatformUrl",
			"  bootstrap_token_file: $tokenPath",
			"logging:",
			"  output: $logsDir\agent.log",
			"  truncate: false",
			"  max_size_mb: 50"
		) | Set-Content -LiteralPath (Join-Path $configDir 'agent.yaml') -Encoding ASCII
		# Only written when it differs from the agent's own default, so agent.yaml does not carry a
		# redundant setting — but a floor the operator chose here also governs every later start.
		if ($MinFreeDiskMB -ne 2048) {
			@("preflight:", "  min_free_disk_mb: $MinFreeDiskMB") |
				Add-Content -LiteralPath (Join-Path $configDir 'agent.yaml') -Encoding ASCII
		}
		Say "wrote $configDir\agent.yaml"
	} else {
		Say "kept the existing $configDir\agent.yaml"
	}

	# --------------------------------------------------------------- 7. preflight + enroll
	$credPath = Join-Path $configDir 'credential.json'

	# IS THIS A FIRST INSTALL OR AN UPGRADE? The question decides whether a failed prerequisite
	# blocks, so it is answered BEFORE -ReEnroll discards the credential below — otherwise
	# re-enrolling a long-deployed host would make it look brand new and could block an upgrade.
	#
	# An enrolled credential, or a registered service, means the platform already knows this host.
	$isUpgrade = (Test-Path -LiteralPath $credPath) -or [bool]$existingService

	if ($ReEnroll -and (Test-Path -LiteralPath $credPath)) {
		Say "-ReEnroll: discarding the stored credential (the platform revokes its key on the next enrollment)"
		Remove-Item -Force -LiteralPath $credPath
	}

	Step "Running the agent's preflight"
	# -preflight-save also persists host.json, which the enrollment below reads to record the
	# cloud environment. Without it every agent would enrol as on-premise.
	#
	# DISPLAYED AND LOGGED, both, always — whatever the verdict and whatever happens next. The
	# checks carry their own consequence and remediation, and the one thing that must never happen
	# is for a host to be left in a state nobody can explain afterwards. The console copy is for the
	# operator standing here; the file is for whoever reads this host in a month.
	$preflightLog = Join-Path $logsDir 'install-preflight.log'
	# Appended, with a header, so an upgrade does not erase the verdict of the install before it:
	# "this host was already short of disk when it was first deployed" is the kind of thing only a
	# kept record can say. Installs are rare, so the file stays small.
	$stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
	$kind = 'first install'
	$gate = 'a failed check BLOCKS'
	if ($isUpgrade) {
		$kind = 'upgrade'
		$gate = 'a failed check does NOT block'
	}
	if ($Force) { $gate = '-Force: a failed check does NOT block' }
	Add-Content -LiteralPath $preflightLog -Encoding UTF8 -Value ""
	Add-Content -LiteralPath $preflightLog -Encoding UTF8 -Value "=== $stamp - $kind of $Version - $gate ==="
	$prevEap = $ErrorActionPreference
	$ErrorActionPreference = 'Continue' # a native non-zero exit throws under Stop from PS 7.4
	& (Join-Path $InstallDir $AgentBin) -preflight-save -config $configDir 2>&1 |
		Tee-Object -FilePath $preflightLog -Append
	$preflightCode = $LASTEXITCODE
	$ErrorActionPreference = $prevEap
	Say "the preflight verdict was written to $preflightLog"

	if ($preflightCode -ne 0) {
		# WHO BLOCKS AND WHO DOES NOT, and the asymmetry is the whole point.
		#
		#   first install   BLOCKS. Nothing is deployed yet, an operator is reading this output, and
		#                   the cheapest moment to refuse a host is before it holds a credential.
		#   upgrade         NEVER BLOCKS. The host already runs an agent; refusing the new binary
		#                   would leave the old one in place over a condition the new one handles by
		#                   degrading (see internal/agent/degraded.go) — and on a host nobody is
		#                   watching, a blocked upgrade is an invisible non-event.
		#   -Force          BLOCKS NOTHING, on an operator's explicit say-so.
		#
		# In every branch the failed checks have already been shown and written above.
		if ($isUpgrade) {
			Warn "the agent's preflight did not pass, and this is an UPGRADE, so the installation continues: the host already runs an agent, and the new one reports a degraded state rather than refusing to start. Fix the conditions above - see $preflightLog."
		}
		elseif ($Force) {
			Warn "the agent's preflight did not pass, and -Force was given, so the installation continues. The consequences listed above are now this host's: an agent may run degraded, or not at all. See $preflightLog."
		}
		else {
			Write-Host ""
			Write-Host "The checks above did not pass, and this is a FIRST installation on this host." -ForegroundColor Yellow
			Write-Host "Fix the conditions listed with each failed check, then re-run this installer." -ForegroundColor Yellow
			Write-Host "To install anyway and accept the consequences above, add -Force." -ForegroundColor Yellow
			Die $EX_PREFLIGHT "the agent's preflight refused this host (verdict in $preflightLog)"
		}
	}

	Step "Enrolling agent $Version with $PlatformUrl"
	# Same reason as the configuration fetch below: from PowerShell 7.4 a non-zero native exit throws
	# while the preference is Stop. A throw here would replace the exit code and its remediation text
	# with a PowerShell error, so the operator would learn that something failed but not which of the
	# four enrollment faults it was.
	$prevEap = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	& (Join-Path $InstallDir $AgentBin) -enroll-only -config $configDir
	$enrollCode = $LASTEXITCODE
	$ErrorActionPreference = $prevEap
	if ($enrollCode -ne 0) {
		switch ($enrollCode) {
			10 { Write-Host "`nThe bootstrap token was rejected. Issue a new one from Agents Fleet -> Deploy agent (or POST $PlatformUrl/aispm/api/v1/agent/admin/bootstrap-tokens with a tenant API key carrying agent:manage) and re-run this installer; tokens are single-use and short-lived." }
			11 { Write-Host "`nThe agent could not reach $PlatformUrl even though this installer could. Check egress rules and TLS trust for the agent's own process, and HTTPS_PROXY if this host needs a proxy." }
			12 { Write-Host "`nThe agent rejected its configuration. Check platform.url and platform.bootstrap_token_file in $configDir\agent.yaml." }
			13 { Write-Host "`nThe platform answered but cannot enrol this host - usually its agent signing keys are not provisioned yet. Ask the platform administrator, then re-run this installer." }
		}
		exit $enrollCode
	}

	# ------------------------------------------------ 7c. fetch the published configuration
	# The catalogues this installer shipped are a FLOOR, not the answer: the platform is the authority
	# on which applications are known and how they are identified, and a host installed today would
	# otherwise run last release's catalogue until its own pull loop came round. Fetching here closes
	# that window, and it is the one moment where putting a configuration into effect costs nothing -
	# no agent is running, so nothing is swapped out from under a reader.
	#
	# Deliberately NEVER fatal. Every failure leaves the installer's catalogues in effect, which is a
	# supported way to run, and the agent retries on its own. Only a REFUSED manifest (22) and a
	# configuration fault (12) are worth a word to the operator.
	Step "Fetching the configuration the platform publishes"
	# ErrorActionPreference is lifted around the call, and must stay lifted. From PowerShell 7.4 a
	# native command exiting non-zero THROWS while the preference is Stop, and here a non-zero exit is
	# the ordinary case - "nothing is published yet" is code 20 - so leaving it in place would abort a
	# perfectly good installation on the most common outcome of all.
	$prevEap = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	& (Join-Path $InstallDir $AgentBin) -config-fetch-only -config $configDir
	$cfgCode = $LASTEXITCODE
	$ErrorActionPreference = $prevEap
	switch ($cfgCode) {
		0  { }
		20 { Say "nothing is published for this agent yet - the catalogues this installer shipped are in effect" }
		21 { Say "the platform did not answer - the catalogues this installer shipped are in effect; the agent fetches again on its own once it is running" }
		22 { Warn "the platform published a configuration this agent REFUSED (see the reason above). The catalogues this installer shipped are in effect. This is a fault in what was published, not on this host: report it to the platform administrator." }
		default { Warn "the configuration fetch reported code $cfgCode; the catalogues this installer shipped are in effect" }
	}

	Remove-Item -Force -LiteralPath (Join-Path $configDir $IncompleteMarker) -ErrorAction SilentlyContinue

	# ------------------------------------------------------------------ 8. service, or how to run
	#
	# Which arrangement. A SERVICE IS THE DEFAULT: it is what a host nobody logs into again needs,
	# and the old default (a console command unless -Service was passed) made the easiest path the
	# one that leaves an agent dead at the next reboot.
	#
	# -Console is how you ask for the foreground agent; -NoService is its older spelling and -Service
	# now asserts the default. The no-flag case needs no protection against demoting a supervised
	# host, which the previous logic had to carry: the default IS the service.
	# Already refused at argument-validation time, far above, before anything was downloaded.
	$useService = -not ($Console -or $NoService)

	# Say it when the arrangement CHANGES under an operator who did not ask for a change. Both
	# directions are deliberate and neither may be silent: an upgrade promoting a console host is
	# the point of this default, and a demotion must remove the service rather than leave both — only
	# one agent may run at a time, and two would stack hooks on the same target and crash it.
	if ($useService -and -not $existingService) {
		Say "this host will run the agent as a service (the default); pass -Console for a foreground agent instead"
	}
	if (-not $useService -and $existingService) {
		Step "Removing the service, because -Console asks for a foreground agent"
		Say "a service AND a console command for one host is not a choice: only one agent may run at a time"
		# Unregister-AgentService stops it first and refuses to delete a service that would not
		# stop, so it is the whole gesture. Calling Stop-AgentService here too would also push its
		# boolean return into the output stream.
		Unregister-AgentService
		$existingService = $null
	}

	$agentPathFinal = Join-Path $InstallDir $AgentBin
	if ($useService) {
		Step "Registering the service"
		Register-AgentService -BinPath $agentPathFinal -ConfigDir $configDir
		Say "starting the $ServiceName service"
		try { Start-Service -Name $ServiceName -ErrorAction Stop } catch {
			Die $EX_FAIL "the $ServiceName service was registered but would not start: $($_.Exception.Message). Check $logsDir\agent.log."
		}
		# Started is not running: the agent reports StartPending while it reads its configuration and
		# identifies the host, and Running once it is actually up — which is worth waiting for.
		#
		# IT NO LONGER PROVES THE PREFLIGHT PASSED, and that used to be this comment's claim. The
		# agent now DEGRADES on an unmet prerequisite instead of refusing to start (see
		# internal/agent/degraded.go), so a host short of disk reaches Running and reports `degraded`
		# on every beat. That is the intended outcome — an agent that reports is repairable, one that
		# refused to start was invisible — and it is also why the installer gates on `-preflight-save`
		# above rather than on this wait: that mode still exits non-zero on a failed check, which is
		# where fail-fast belongs, with an operator reading the output.
		$deadline = (Get-Date).AddSeconds(90)
		$ok = $false
		while ((Get-Date) -lt $deadline) {
			$svc = Get-AgentService
			if ($svc -and $svc.Status -eq 'Running') { $ok = $true; break }
			if ($svc -and $svc.Status -eq 'Stopped') { break }
			Start-Sleep -Seconds 2
		}
		if ($ok) { Say "the service is running" }
		else { Warn "the $ServiceName service did not report Running within 90s - check $logsDir\agent.log and 'Get-Service $ServiceName'" }
	} elseif ($svcWasRunning) {
		# The service existed, was stopped to replace the binary, and a console agent was asked for.
		# Starting it again would contradict the request; leaving it registered and stopped would
		# leave a host that looks supervised and is not. Said out loud rather than decided quietly.
		Warn "the $ServiceName service is registered but was NOT restarted, because -Console was passed. Either start it (Start-Service $ServiceName) or remove it (sc.exe delete $ServiceName)."
	}

	Write-Host ""
	Write-Host "==> Installed: aispm-agent $Version in $InstallDir"
	Write-Host ""

	# THE UNMET CONDITION IS REPEATED HERE, at the end, and that is the point of saying it twice.
	# The failed checks scrolled past several steps ago, between a download and an enrollment; an
	# operator who reads only the last screen would otherwise take "Installed" for "healthy". The
	# agent runs, and it runs narrowed - both halves belong in the verdict.
	if ($preflightCode -ne 0) {
		Write-Host "  DEGRADED: a host prerequisite was not met, so this agent will run with less than" -ForegroundColor Yellow
		Write-Host "  its full function and will report 'degraded' on every heartbeat. It re-tests the" -ForegroundColor Yellow
		Write-Host "  condition every 5 minutes and recovers on its own once it is fixed - no reinstall." -ForegroundColor Yellow
		Write-Host "  What failed, with its consequence and remedy: $preflightLog" -ForegroundColor Yellow
		Write-Host ""
	}

	if ($useService) {
		Write-Host "It runs as the Windows service '$ServiceName', starts automatically at boot, and is"
		Write-Host "restarted by Windows if it fails - which is also what lets it install its own updates."
		Write-Host ""
		Write-Host "  Status:  Get-Service $ServiceName"
		Write-Host "  Stop:    Stop-Service $ServiceName      (takes MINUTES: it releases its in-target"
		Write-Host "                                           hooks first, and that is the system working)"
		Write-Host "  Start:   Start-Service $ServiceName"
		Write-Host ""
		Write-Host "  NEVER 'Stop-Process -Force' / taskkill /F on it. A hard kill can crash or freeze the"
		Write-Host "  applications the agent was monitoring. Stop-Service is the clean way and always works."
		Write-Host ""
		Write-Host "Logs:   $logsDir"
		Write-Host "Config: $configDir   (agent.yaml, catalogues, credential.json)"
		exit $EX_OK
	}
	Write-Host "Start the agent (elevated PowerShell):"
	Write-Host ""
	Write-Host "  & '$InstallDir\$AgentBin' -config '$configDir'"
	Write-Host ""
	Write-Host "  (Or re-run this installer WITHOUT -Console to have Windows start it at boot and keep"
	Write-Host "   it running - that is the default. A console agent does not survive a reboot and cannot"
	Write-Host "   install its own updates: nothing would restart it afterwards.)"
	Write-Host ""
	Write-Host "  (The log destination is already set in $configDir\agent.yaml - $logsDir\agent.log,"
	Write-Host "   appended to rather than truncated, and size-bounded by rotation (logging.max_size_mb,"
	Write-Host "   25 MiB; current file plus one rotated agent.log.1, so ~2x that on disk).)"
	Write-Host ""
	Write-Host "Stop it CLEANLY - Ctrl+C in its console, or:"
	Write-Host ""
	if ($stopScriptPath) {
		Write-Host "  powershell -ExecutionPolicy Bypass -File '$stopScriptPath'"
		Write-Host ""
		Write-Host "  (It finds the single running agent on its own; pass -ProcessId <pid> if several run.)"
	} else {
		Write-Host "  Ctrl+C is the only graceful stop on this host: this release published no"
		Write-Host "  $StopScriptName. Start the agent in a console you keep, so you have one."
	}
	Write-Host ""
	Write-Host "  NEVER 'Stop-Process -Force' / taskkill /F. A hard kill can crash or freeze the"
	Write-Host "  applications the agent was monitoring, and loses whatever it had not yet reported."
	Write-Host "  Always let it shut down."
	Write-Host ""
	Write-Host "  The graceful stop needs the agent to OWN A CONSOLE: start it from a console or with"
	Write-Host "  Start-Process, never through WMI Win32_Process.Create."
	Write-Host ""
	Write-Host "Logs:   $logsDir"
	Write-Host "Config: $configDir   (agent.yaml, catalogues, credential.json)"
	exit $EX_OK
} finally {
	Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
