<#
.SYNOPSIS
  AISPM host agent installer (Windows).

.DESCRIPTION
  Two modes, same script:
    package   - run from the unzipped installer package; reads installer.conf + bootstrap.token
                sitting next to this script.
    one-liner - iwr <platform>/aispm/api/v1/agent/install.ps1 | iex, then call with -PlatformUrl
                and -Token (see the package README for the exact snippet).

  It detects the architecture, checks the prerequisites, lays out the install directory, downloads
  the binary and the configuration for the resolved release (SHA256 verified), gates on the agent's
  own preflight, enrols the host, and prints the exact command to run it.

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
	[switch]$ReEnroll
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
$IncompleteMarker = '.install-incomplete'
$PingPath = '/aispm/api/v1/agent/ping'
$MinFreeBytes = 256MB

function Say  { param([string]$m) Write-Host "  $m" }
function Step { param([string]$m) Write-Host ""; Write-Host "==> $m" }
function Warn { param([string]$m) Write-Warning $m }
function Die  { param([int]$code, [string]$m) Write-Host "error: $m" -ForegroundColor Red; exit $code }

# TLS 1.2 floor: PS 5.1 still defaults to SSL3/TLS1 on older images, which no platform accepts.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

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

if (-not $Channel) { $Channel = $DefaultChannel }
if (-not $InstallDir) { $InstallDir = $InstallRootDefault }
if (-not $PlatformUrl) { Die $EX_USAGE "-PlatformUrl is required (or provide installer.conf next to this script)" }
if ($PlatformUrl -notmatch '^https://') { Die $EX_USAGE "-PlatformUrl must be an https URL, got '$PlatformUrl'" }
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
	if ($free -lt $MinFreeBytes) {
		Die $EX_PREREQ "not enough free space on $driveRoot : $([int]($free/1MB)) MiB available, $([int]($MinFreeBytes/1MB)) MiB required"
	}
} catch { Warn "could not determine the free space on $driveRoot" }
Say "Administrator, tar.exe, free space: ok"

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
	try { return (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60).Content | ConvertFrom-Json }
	catch { Die $EX_DOWNLOAD "cannot fetch $url ($($_.Exception.Message))" }
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
# The config dir stays writable for the agent itself: credential.json, host.json, the identity
# salt and the keylog cache all live there.
New-Item -ItemType File -Force -Path (Join-Path $configDir $IncompleteMarker) | Out-Null
Say "$InstallDir\$AgentBin, $configDir, $logsDir"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aispm-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
	function Get-Verified { param([string]$url, [string]$sha256, [string]$dest, [string]$label)
		Say $url
		try { Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $dest -TimeoutSec 600 }
		catch { Die $EX_DOWNLOAD "cannot download $label from $url ($($_.Exception.Message))" }
		$got = (Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLower()
		if ($got -ne $sha256.ToLower()) {
			Die $EX_DOWNLOAD "$label failed its checksum: expected $($sha256.ToLower()), got $got (corrupted download, or a tampered artifact - do not run it)"
		}
	}

	# --------------------------------------------------------------- 5. binary + config
	Step "Downloading the agent"
	$binTmp = Join-Path $tmp $AgentBin
	Get-Verified $artifact.url $artifact.sha256 $binTmp "the agent binary"
	Move-Item -Force -LiteralPath $binTmp -Destination (Join-Path $InstallDir $AgentBin)
	Say "installed $InstallDir\$AgentBin (sha256 verified)"

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
		@(
			"# Written by install.ps1 $stamp - agent $Version",
			"platform:",
			"  url: $PlatformUrl",
			"  bootstrap_token_file: $($tokenPath -replace '\\','\\')"
		) | Set-Content -LiteralPath (Join-Path $configDir 'agent.yaml') -Encoding ASCII
		Say "wrote $configDir\agent.yaml"
	} else {
		Say "kept the existing $configDir\agent.yaml"
	}

	# --------------------------------------------------------------- 7. preflight + enroll
	$credPath = Join-Path $configDir 'credential.json'
	if ($ReEnroll -and (Test-Path -LiteralPath $credPath)) {
		Say "-ReEnroll: discarding the stored credential (the platform revokes its key on the next enrollment)"
		Remove-Item -Force -LiteralPath $credPath
	}

	Step "Running the agent's preflight"
	# -preflight-save also persists host.json, which the enrollment below reads to record the
	# cloud environment. Without it every agent would enrol as on-premise.
	& (Join-Path $InstallDir $AgentBin) -preflight-save -config $configDir
	if ($LASTEXITCODE -ne 0) {
		Die $EX_PREFLIGHT "the agent's preflight refused this host (see the failed checks and their remediation above)"
	}

	Step "Enrolling with $PlatformUrl"
	& (Join-Path $InstallDir $AgentBin) -enroll-only -config $configDir
	$enrollCode = $LASTEXITCODE
	if ($enrollCode -ne 0) {
		switch ($enrollCode) {
			10 { Write-Host "`nThe bootstrap token was rejected. Issue a new one from Agents Fleet -> Deploy agent and re-run this installer; tokens are single-use and short-lived." }
			11 { Write-Host "`nThe agent could not reach $PlatformUrl even though this installer could. Check egress rules and TLS trust for the agent's own process, and HTTPS_PROXY if this host needs a proxy." }
			12 { Write-Host "`nThe agent rejected its configuration. Check platform.url and platform.bootstrap_token_file in $configDir\agent.yaml." }
			13 { Write-Host "`nThe platform answered but cannot enrol this host - usually its agent signing keys are not provisioned yet. Ask the platform administrator, then re-run this installer." }
		}
		exit $enrollCode
	}

	Remove-Item -Force -LiteralPath (Join-Path $configDir $IncompleteMarker) -ErrorAction SilentlyContinue

	# ------------------------------------------------------------------ 8. how to run
	Write-Host ""
	Write-Host "==> Installed: aispm-agent $Version in $InstallDir"
	Write-Host ""
	Write-Host "Start the agent (elevated PowerShell):"
	Write-Host ""
	Write-Host "  & '$InstallDir\$AgentBin' -config '$configDir' ``"
	Write-Host "      -logging-output '$logsDir\agent.log' -logging-truncate=false"
	Write-Host ""
	Write-Host "  (-logging-truncate=false keeps the log across restarts; the default empties it at startup."
	Write-Host "   The agent log is not rotated - watch $logsDir.)"
	Write-Host ""
	Write-Host "Stop it CLEANLY - Ctrl+C in its console, or:"
	Write-Host ""
	Write-Host "  .\stop-agent-graceful.ps1 -ProcessId <pid>"
	Write-Host ""
	Write-Host "  NEVER 'Stop-Process -Force' / taskkill /F. The agent must make its in-target hooks inert"
	Write-Host "  before exiting; killing it hard can crash or freeze the applications it was watching."
	Write-Host "  The graceful stop needs the agent to OWN A CONSOLE: start it from a console or with"
	Write-Host "  Start-Process, never through WMI Win32_Process.Create."
	Write-Host ""
	Write-Host "Logs:   $logsDir"
	Write-Host "Config: $configDir   (agent.yaml, catalogues, credential.json)"
	exit $EX_OK
} finally {
	Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
