#!/bin/sh
# AISPM host agent installer (Linux, macOS).
#
# Two modes, same script:
#   package   — run from the unzipped installer package; reads installer.conf + bootstrap.token
#               sitting next to this script.
#   one-liner — curl -fsSL <platform>/aispm/api/v1/agent/install.sh \
#                 | sudo sh -s -- --platform-url https://platform.example
#               With no --token/--token-file the token is asked for on the terminal, with echo off,
#               so the line an operator pastes carries no secret and the shell history keeps none.
#
# It detects the OS/arch, checks the prerequisites, lays out the install directory, downloads the
# binary and the configuration for the resolved release (SHA256 verified), gates on the agent's own
# preflight, enrols the host, and prints the exact command to run it.
#
# Exit codes. Below 10 the installer itself failed; 10 and above are the agent's frozen enrollment
# codes, passed through unchanged so the number an operator reports means one thing only
# (see docs/installer-distribution-plan.md §2c):
#   0  installed (and enrolled)
#   1  unexpected failure
#   2  usage error
#   3  this OS/arch is not supported, or no binary is published for it yet
#   4  a prerequisite is missing
#   5  not running as root
#   6  the platform is not reachable
#   7  download or checksum failure
#   8  the agent's preflight refused this host
#   9  reserved (frozen; it was "the agent does not support this OS yet" — no OS produces it now)
#   10 bootstrap token invalid, expired, revoked or already used
#   11 platform unreachable from the agent
#   12 agent configuration error
#   13 platform reachable but unable to enrol
set -eu

EX_OK=0; EX_FAIL=1; EX_USAGE=2; EX_UNSUPPORTED=3; EX_PREREQ=4
EX_PRIVILEGE=5; EX_PLATFORM=6; EX_DOWNLOAD=7; EX_PREFLIGHT=8; EX_OS_NOT_YET=9

# Defaults. --manifest-url (or installer.conf) overrides the whole resolution chain.
RELEASES_OWNER="${AISPM_RELEASES_OWNER:-illuminait-io}"
RELEASES_REPO="aispm-agent-releases"
DEFAULT_CHANNEL="stable"
INSTALL_ROOT_DEFAULT="/opt/IlluminaIT"
AGENT_BIN="aispm-agent"
# Linux service identity. The unit name is what systemctl and journalctl are called with, so it is
# also what every instruction prints; /etc/systemd/system is the admin-owned directory, which is
# where a locally-installed unit belongs (never /lib or /usr/lib, which packages own).
SYSTEMD_DIR="/etc/systemd/system"
SYSTEMD_UNIT="aispm-agent.service"

# macOS service identity. The label is the daemon's name to launchctl and the plist's basename;
# both are fixed so an upgrade replaces the existing daemon instead of adding a second one.
LAUNCHD_LABEL="io.illuminait.aispm-agent"
LAUNCHD_DIR="/Library/LaunchDaemons"
# Marker dropped before the first mutation and removed on success: a re-run knows it is resuming.
INCOMPLETE_MARKER=".install-incomplete"
PING_PATH="/aispm/api/v1/agent/ping"
# Free-space floor, in MiB. Same default as the agent's own preflight.min_free_disk_mb (2 GiB), so
# the installer refuses before downloading anything rather than letting the agent refuse after.
# AISPM_MIN_FREE_DISK_MB overrides both: it is applied here AND seeded into agent.yaml.
MIN_FREE_MB="${AISPM_MIN_FREE_DISK_MB:-2048}"

# LAUNCHD_BOOTOUT_WAIT bounds the wait for a previous daemon to finish tearing down before the new
# one is bootstrapped. Slightly above the plist's ExitTimeOut (30s), which is the longest launchd
# will let the outgoing agent drain before it SIGKILLs it: waiting less would reintroduce the race
# this exists to close, on exactly the busy host where losing the agent matters most.
LAUNCHD_BOOTOUT_WAIT=35

platform_url=""; token=""; token_file=""; version=""; channel=""; no_start=0; uninstall=0
manifest_url=""; install_dir=""; re_enroll=0

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { code="$1"; shift; printf 'error: %s\n' "$*" >&2; exit "$code"; }

usage() {
	cat <<'USAGE'
Usage: install.sh [options]

  --platform-url URL   AISPM platform base URL (https). Required unless installer.conf provides it.
  --token TOKEN        single-use bootstrap token. An argv token is visible in `ps` and in the
                       shell history: prefer --token-file, or give neither and type it at the
                       prompt (echo off) — the installer asks when it runs on a terminal.
  --token-file PATH    file holding the bootstrap token (default: ./bootstrap.token when present)
  --version X.Y.Z      install this exact agent version instead of the channel's current one
  --channel NAME       release channel to follow (default: stable)
  --manifest-url URL   resolve the release from this manifest, bypassing the channel
  --install-dir PATH   install root (default: /opt/IlluminaIT)
  --re-enroll          discard the stored credential and enrol again (needs a fresh token)
  --no-start           install, enrol and register the service, but do NOT start it. On macOS this
                       is what lets Full Disk Access be granted first: the grant is bound to the
                       BINARY's hash, and an agent started before it runs its whole session
                       degraded — polling instead of EndpointSecurity, unable to read another
                       user's command line. Either way this prints the command that starts it.
  --uninstall          stop the agent cleanly, remove its service and delete the install
                       directory. Needs no token and no --platform-url. Revoke the agent's key in
                       the console afterwards: the files are gone, the credential was valid.
  -h, --help           this help

Environment:
  AISPM_MIN_FREE_DISK_MB=<MiB>   override the free-space floor (default 2048)
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
	--platform-url) platform_url="${2:-}"; shift 2 ;;
	--token)        token="${2:-}"; shift 2 ;;
	--token-file)   token_file="${2:-}"; shift 2 ;;
	--version)      version="${2:-}"; shift 2 ;;
	--channel)      channel="${2:-}"; shift 2 ;;
	--manifest-url) manifest_url="${2:-}"; shift 2 ;;
	--install-dir)  install_dir="${2:-}"; shift 2 ;;
	--re-enroll)    re_enroll=1; shift ;;
	--no-start)     no_start=1; shift ;;
	--uninstall)    uninstall=1; shift ;;
	-h|--help)      usage; exit $EX_OK ;;
	*)              usage >&2; die $EX_USAGE "unknown option: $1" ;;
	esac
done

# ------------------------------------------------------------------- uninstall
# Deliberately before everything an install needs: no token, no --platform-url, no release
# resolution, no network. Removing an agent must work on a host whose platform is unreachable —
# that is often exactly why it is being removed.
if [ "$uninstall" -eq 1 ]; then
	[ -n "$install_dir" ] || install_dir="$INSTALL_ROOT_DEFAULT"
	[ "$(id -u)" -eq 0 ] || die $EX_PRIVILEGE "uninstalling needs root (the service definition and $install_dir are root-owned): re-run with sudo"

	uname_s=$(uname -s 2>/dev/null || echo unknown)
	case "$uname_s" in
	Linux)  os="linux" ;;
	Darwin) os="darwin" ;;
	*) die $EX_UNSUPPORTED "unsupported operating system '$uname_s' (this installer covers Linux and macOS; use install.ps1 on Windows)" ;;
	esac

	step "Stopping the agent"
	stopped=0
	if [ "$os" = "darwin" ] && [ -f "$LAUNCHD_DIR/$LAUNCHD_LABEL.plist" ]; then
		# bootout sends SIGTERM and waits; it is the same clean path an operator would use.
		if launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null; then
			say "  launchd daemon $LAUNCHD_LABEL stopped"
		else
			say "  launchd daemon $LAUNCHD_LABEL was not loaded"
		fi
		stopped=1
	fi
	if [ "$os" = "linux" ] && [ -f "$SYSTEMD_DIR/$SYSTEMD_UNIT" ]; then
		systemctl stop "$SYSTEMD_UNIT" 2>/dev/null && say "  $SYSTEMD_UNIT stopped" || say "  $SYSTEMD_UNIT was not running"
		systemctl disable "$SYSTEMD_UNIT" >/dev/null 2>&1 || true
		stopped=1
	fi
	if [ "$stopped" -eq 0 ]; then
		# No service: the agent was being run by hand. SIGTERM it and WAIT — a hard kill loses
		# whatever it had not reported, and on a host with instrumented applications it can take
		# them down with it.
		#
		# Matched on the install path, not on the process name: a host can hold a second install (a
		# staging copy, a developer build) and taking that one down would be acting on a process
		# nobody asked about.
		pids=$(pgrep -f "$install_dir/$AGENT_BIN" 2>/dev/null || true)
		if [ -n "$pids" ]; then
			say "  sending SIGTERM to $(echo "$pids" | tr '\n' ' ')"
			for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
			waited=0
			while [ "$waited" -lt 30 ]; do
				pgrep -f "$install_dir/$AGENT_BIN" >/dev/null 2>&1 || break
				sleep 1
				waited=$((waited + 1))
			done
			if pgrep -f "$install_dir/$AGENT_BIN" >/dev/null 2>&1; then
				# Never escalate to SIGKILL on its behalf: that is the kill this whole path exists
				# to avoid, and the operator has to decide it knowing what it costs.
				warn "the agent is still running after ${waited}s. Leave it to finish and re-run --uninstall; do NOT 'kill -9' while it has applications instrumented."
				exit $EX_FAIL
			fi
			say "  stopped after ${waited}s"
		else
			say "  no running agent found"
		fi
	fi

	step "Removing the service definition"
	if [ "$os" = "darwin" ]; then
		rm -f "$LAUNCHD_DIR/$LAUNCHD_LABEL.plist" && say "  $LAUNCHD_DIR/$LAUNCHD_LABEL.plist removed"
	else
		if [ -f "$SYSTEMD_DIR/$SYSTEMD_UNIT" ]; then
			rm -f "$SYSTEMD_DIR/$SYSTEMD_UNIT"
			systemctl daemon-reload 2>/dev/null || true
			say "  $SYSTEMD_DIR/$SYSTEMD_UNIT removed"
		else
			say "  no unit file to remove"
		fi
	fi

	step "Removing $install_dir"
	if [ -d "$install_dir" ]; then
		# Refuse a path that is obviously not an install root rather than recursing into it.
		case "$install_dir" in
		/|/usr|/etc|/var|/opt|/home|/root) die $EX_USAGE "--install-dir '$install_dir' is a system directory; refusing to delete it" ;;
		esac
		rm -rf "$install_dir"
		say "  removed"
	else
		say "  $install_dir does not exist"
	fi

	cat <<UNINSTALLED

==> Uninstalled: the agent is stopped and $install_dir is gone.

  ONE STEP IS LEFT, and it is not on this host: revoke this agent in the console
  (Agents Fleet -> the agent's row -> Revoke key, or Forget it to drop its history too).

  Deleting the files did NOT invalidate its credential. Until you revoke it, anything holding a
  copy of the credential.json that was in $install_dir/config can keep reporting as this host.

UNINSTALLED
	exit $EX_OK
fi

# ---------------------------------------------------------------- package mode
# installer.conf and bootstrap.token travel with the script in the zip. Anything passed on the
# command line wins, so the one-liner and the package share this code path.
script_dir() {
	# $0 is not a path when piped from curl; fall back to the working directory.
	case "${0:-}" in
	-|sh|bash|/dev/fd/*|"") printf '%s' "$PWD" ;;
	*) d=$(dirname -- "$0") 2>/dev/null || d="$PWD"; (cd -- "$d" 2>/dev/null && pwd) || printf '%s' "$PWD" ;;
	esac
}
HERE=$(script_dir)

if [ -f "$HERE/installer.conf" ]; then
	say "using $HERE/installer.conf"
	# Only known keys are read, and never with eval: the file is generated by the platform but
	# still travels on a user's disk.
	conf_get() { sed -n 's/^[[:space:]]*'"$1"'[[:space:]]*=[[:space:]]*//p' "$HERE/installer.conf" | tr -d '\r' | head -1; }
	[ -n "$platform_url" ] || platform_url=$(conf_get platformUrl)
	[ -n "$channel" ]      || channel=$(conf_get channel)
	[ -n "$version" ]      || version=$(conf_get agentVersion)
	[ -n "$manifest_url" ] || manifest_url=$(conf_get manifestUrl)
fi
if [ -z "$token" ] && [ -z "$token_file" ] && [ -f "$HERE/bootstrap.token" ]; then
	token_file="$HERE/bootstrap.token"
fi

# ----------------------------------------------------------------- token prompt
# No token on the command line and none beside the script: ask for it. This is what lets the
# one-liner carry no secret — the token is typed, not pasted into a command the shell history keeps.
# stdin is the curl pipe when piped, so the prompt goes through the controlling terminal; without
# one (cron, a CI runner, `setsid`) there is nobody to ask and that is a usage error, said as such.
prompt_token() {
	( : </dev/tty ) 2>/dev/null || die $EX_USAGE "no bootstrap token: pass --token or --token-file, or run from a terminal to be asked for it (no /dev/tty here)"
	printf 'Bootstrap token (from Agents Fleet -> Deploy agent, or POST /aispm/api/v1/agent/admin/bootstrap-tokens; input hidden): ' >/dev/tty
	echo_off=0
	if stty -echo </dev/tty 2>/dev/null; then
		echo_off=1
		# Restore the terminal whatever happens next: a Ctrl+C here must not leave the shell blind.
		trap 'stty echo </dev/tty 2>/dev/null' INT TERM EXIT
	else
		warn "cannot disable terminal echo (stty failed): the token will be visible as you type it"
	fi
	IFS= read -r token </dev/tty || token=""
	if [ "$echo_off" -eq 1 ]; then
		stty echo </dev/tty 2>/dev/null
		trap - INT TERM EXIT
	fi
	printf '\n' >/dev/tty
	token=$(printf '%s' "$token" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	[ -n "$token" ] || die $EX_USAGE "empty bootstrap token"
}
if [ -z "$token" ] && [ -z "$token_file" ]; then
	prompt_token
fi

[ -n "$channel" ] || channel="$DEFAULT_CHANNEL"
[ -n "$install_dir" ] || install_dir="$INSTALL_ROOT_DEFAULT"
[ -n "$platform_url" ] || { usage >&2; die $EX_USAGE "--platform-url is required (or provide installer.conf)"; }
case "$platform_url" in
https://*) ;;
*) die $EX_USAGE "--platform-url must be an https URL, got '$platform_url'" ;;
esac
platform_url=$(printf '%s' "$platform_url" | sed 's:/*$::')

# --------------------------------------------------------------- 1. os / arch
step "Detecting the operating system and architecture"
uname_s=$(uname -s); uname_m=$(uname -m)
case "$uname_s" in
Linux)  os="linux" ;;
Darwin) os="darwin" ;;
*) die $EX_UNSUPPORTED "unsupported operating system '$uname_s' (this installer covers Linux and macOS; use install.ps1 on Windows)" ;;
esac
case "$uname_m" in
x86_64|amd64) arch="amd64" ;;
aarch64|arm64) arch="arm64" ;;
*) die $EX_UNSUPPORTED "unsupported architecture '$uname_m' (the agent is published for amd64 and arm64)" ;;
esac
say "  $os/$arch"

# ----------------------------------------------------- 2. prerequisites, privileges
step "Checking the prerequisites"
need() { command -v "$1" >/dev/null 2>&1 || die $EX_PREREQ "'$1' is required but not installed ($2)"; }
need curl "install curl, or fetch the package on another machine and copy it over"
need tar  "install tar (GNU tar or bsdtar)"

# sha256: coreutils on Linux, shasum on macOS. The checksum is not optional — it is the only
# integrity check on a binary fetched over the public internet.
if command -v sha256sum >/dev/null 2>&1; then
	sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
	sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
	die $EX_PREREQ "no sha256 tool found (install coreutils for sha256sum, or use shasum)"
fi

# Root is required, not advisory: the agent's own preflight treats missing elevation as a FATAL
# check, so a non-root install would produce an agent that cannot start.
if [ "$(id -u)" -ne 0 ]; then
	die $EX_PRIVILEGE "this installer must run as root (the agent needs root to observe processes and traffic): re-run with 'sudo $0 $*'"
fi

parent_dir="$install_dir"
while [ ! -d "$parent_dir" ] && [ "$parent_dir" != "/" ]; do parent_dir=$(dirname -- "$parent_dir"); done
free_mb=$(df -Pm "$parent_dir" 2>/dev/null | awk 'NR==2 {print $4}' || echo "")
case "$free_mb" in
''|*[!0-9]*) warn "could not determine the free space on $parent_dir" ;;
*) [ "$free_mb" -ge "$MIN_FREE_MB" ] || die $EX_PREREQ "not enough free space on $parent_dir: $free_mb MiB available, $MIN_FREE_MB MiB required. The agent writes its unrotated log, its rotating transaction/connection logs and its credential here — free up space, choose another --install-dir, or lower the floor with AISPM_MIN_FREE_DISK_MB" ;;
esac
say "  root privileges, curl, tar, sha256, free space (>= ${MIN_FREE_MB} MiB): ok"

step "Checking that the platform is reachable"
# A strict 200 on the liveness endpoint. Any other answer means the URL reaches something that
# is not the agent API — typically a reverse proxy or load balancer that does not route
# /aispm/api/v1/agent/ — which is exactly the misconfiguration worth catching before enrolling.
# curl already writes 000 when it never got a response; do not append a second fallback, or the
# "unreachable" branch below stops matching and the operator gets the wrong guidance.
ping_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$platform_url$PING_PATH" 2>/dev/null) || true
[ -n "$ping_code" ] || ping_code="000"
if [ "$ping_code" = "200" ]; then
	say "  $platform_url$PING_PATH -> 200"
elif [ "$ping_code" = "000" ]; then
	die $EX_PLATFORM "cannot reach $platform_url: check the URL, DNS, egress rules and TLS trust from this host (set HTTPS_PROXY if this host needs a proxy)"
else
	die $EX_PLATFORM "$platform_url$PING_PATH answered HTTP $ping_code, not 200: the URL does not reach the agent API (wrong host, or a proxy that does not route /aispm/api/v1/agent/)"
fi

# ------------------------------------------------- 2b. what this agent covers on this OS
# Everything above genuinely validates the host — architecture, elevation, tooling, disk space,
# and that the platform is reachable from here.
#
# What follows is what the agent can actually SEE on this OS. The authority is the coverage table
# in internal/capture/coverage.go; this notice mirrors it so an operator reads, before anything is
# downloaded, what the host will and will not report. The agent DECLARES the same coverage to the
# platform, on enrollment and on every heartbeat (docs/agent-coverage-declaration.md), so a partial
# host is never reported as a complete one — which is what makes installing it honest.
#
#   macOS  processes: full | connections: partial | communications: none    | containers: none
#   Linux  processes: full | connections: partial | communications: partial | containers: full
#          Processes come from an event source on both (EndpointSecurity, netlink proc-connector),
#          falling back to a sweep — and the agent then DECLARES partial, so the fallback is visible.
#          Connections are polled on both: one that opens and closes between two ticks leaves no
#          trace, and there are no byte volumes.
case "$os" in
darwin)
	cat <<PARTIAL

==> macOS: partial coverage, declared to the platform

  Captured:     processes — lifecycle, command lines, owners, and their qualification
                (MCP servers, inference engines, AI desktop clients), plus the ports they
                listen on, and a poll of their live connections.
  NOT captured: communications (no TLS decode — nothing about what an application sends), and
                any connection that opens and closes between two polls.
                A server is visible here; what it says to whom is not.

  This agent reports its own coverage to the platform, so this host appears as partially
  covered rather than as a fully monitored host that happened to find nothing.

  Full coverage is Windows (install.ps1 or install.cmd from the same package).

PARTIAL
	;;
linux)
	cat <<PARTIAL

==> Linux: partial coverage, declared to the platform

  Captured:     processes — exec and exit from the kernel's netlink connector, with their
                command lines, owners and qualification (MCP servers, inference engines, AI
                desktop clients); the TCP ports they listen on; and a poll of their
                established TCP connections.
  Also captured: the PLAINTEXT of what applications send, through eBPF uprobes on OpenSSL
                (SSL_write/SSL_read) — no injection into the target; and container attribution,
                enriched from the runtime.
  NOT captured: byte volumes, UDP flows, any connection that opens and closes between two polls,
                and TLS from a stack with no C function to probe (Go crypto/tls, Rust rustls,
                Java JSSE do their record layer in their own language).

  The communications layer needs BTF, CAP_BPF and a readable libssl. Without any of them it
  degrades to none — nothing about WHAT an application sends — and the agent declares that, so
  this host shows up with no communications rather than with none found. The preflight's
  ebpf-support check answers it before anything is installed.

  If the netlink connector cannot be subscribed to (no CAP_NET_ADMIN, no CONFIG_CONNECTOR), the
  agent falls back to sweeping /proc, says so in its log, and DECLARES the lower coverage — a
  process shorter than two sweeps is then missed.

  This agent reports its own coverage to the platform, so this host appears as partially
  covered rather than as a fully monitored host that happened to find nothing.

  Full coverage is Windows (install.ps1 or install.cmd from the same package).

PARTIAL
	;;
esac

# ------------------------------------------------------------- 3. release resolution
# Minimal JSON readers. The manifest and channel files are produced by our own release CI, and
# these only ever read string fields, one level deep — enough to avoid requiring jq on a host
# that may have nothing installed.
# '|' is the substitution delimiter on purpose: keys include "linux/amd64", and a '/' delimiter
# would turn the platform key into a broken sed expression (and then into a misleading
# "not published for this platform" error).
json_string() { # <json> <key>
	printf '%s' "$1" | tr -d '\n\t' | sed -n 's|.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*|\1|p' | head -1
}
json_object() { # <json> <key> -> the {...} value of that key
	printf '%s' "$1" | tr -d '\n\t' | sed -n 's|.*"'"$2"'"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*|\1|p' | head -1
}

fetch() { # <url> -> body on stdout
	# Retried: the channel file is served through a CDN that can briefly 404 or serve a stale copy
	# right after a release is cut (observed). One transient 404 must not be reported to the
	# operator as "this release channel does not exist".
	i=1
	while [ "$i" -le 3 ]; do
		if [ "$i" -lt 3 ]; then
			# Quiet on the attempts that will be retried: three "curl: (56) 404" lines ahead of
			# the real message only obscures it.
			curl -fsSL --max-time 60 "$1" 2>/dev/null && return 0
			sleep $((i * 3))
		else
			curl -fsSL --max-time 60 "$1" && return 0
		fi
		i=$((i + 1))
	done
	return 1
}

step "Resolving the release"
if [ -z "$manifest_url" ]; then
	if [ -n "$version" ]; then
		manifest_url="https://github.com/$RELEASES_OWNER/$RELEASES_REPO/releases/download/v$version/manifest.json"
	else
		# One flat file per channel on the distribution repo's main branch: channel.json for
		# stable, channel-<name>.json for any other. AISPM_CHANNEL_URL overrides it for internal
		# mirrors and for testing this script.
		if [ "$channel" = "$DEFAULT_CHANNEL" ]; then channel_file="channel.json"; else channel_file="channel-$channel.json"; fi
		channel_url="${AISPM_CHANNEL_URL:-https://raw.githubusercontent.com/$RELEASES_OWNER/$RELEASES_REPO/main/$channel_file}"
		say "  channel '$channel' via $channel_url"
		channel_json=$(fetch "$channel_url") || die $EX_UNSUPPORTED "no such release channel '$channel': $channel_url is not published"
		version=$(json_string "$channel_json" version)
		manifest_url=$(json_string "$channel_json" manifestUrl)
		# A bootstrapped channel file carries nulls until the first release is cut; nulls are not
		# quoted strings, so both reads come back empty.
		[ -n "$manifest_url" ] || die $EX_FAIL "release channel '$channel' has no published release yet (no manifest in $channel_url) — pin a version with --version, or wait for the first release"
	fi
fi

manifest=$(fetch "$manifest_url") || die $EX_DOWNLOAD "cannot fetch the manifest $manifest_url"
man_version=$(json_string "$manifest" version)
[ -n "$man_version" ] || die $EX_FAIL "the manifest at $manifest_url has no version field"
[ -z "$version" ] || [ "$version" = "$man_version" ] || warn "requested version $version, manifest describes $man_version"
version="$man_version"
say "  agent $version (channel ${channel})"

# Fail before downloading anything if this platform was never published: the manifest is the
# authority on what exists, which is the whole reason resolution goes through it.
artifact=$(json_object "$manifest" "$os/$arch")
[ -n "$artifact" ] || die $EX_UNSUPPORTED "no agent binary published for $os/$arch in release $version — the manifest lists no such artifact (ask for this platform, or install on a supported one)"
bin_url=$(json_string "{$artifact}" url); bin_sha=$(json_string "{$artifact}" sha256)
[ -n "$bin_url" ] && [ -n "$bin_sha" ] || die $EX_FAIL "the manifest entry for $os/$arch is missing its url or sha256"

# The configuration is NOT optional: the agent has no compiled-in catalogues, so an empty
# config/ yields an agent that starts, warns, and classifies nothing.
config_artifact=$(json_object "$manifest" config)
[ -n "$config_artifact" ] || die $EX_FAIL "release $version publishes no configuration bundle; the agent cannot classify anything without it"
cfg_url=$(json_string "{$config_artifact}" url); cfg_sha=$(json_string "{$config_artifact}" sha256)
[ -n "$cfg_url" ] && [ -n "$cfg_sha" ] || die $EX_FAIL "the manifest's config entry is missing its url or sha256"

# ------------------------------------------------------------ 4. directory layout
step "Preparing $install_dir"
config_dir="$install_dir/config"
logs_dir="$install_dir/logs"
mkdir -p "$install_dir" "$config_dir" "$logs_dir" || die $EX_FAIL "cannot create $install_dir"
[ -w "$install_dir" ] || die $EX_FAIL "$install_dir is not writable"
# The config dir stays writable for the agent itself: credential.json, host.json, the identity
# salt and the keylog cache all live there.
# 0750 on the logs, not 0755: http.jsonl and the agent log carry decoded traffic, and a
# credential passed in a query string lands there in clear (the agent redacts it since 0.10.13,
# but older files remain and a body can still carry one). The config dir is 0700 below for the
# same reason - it holds credential.json, the agent's API key to the platform.
chmod 0755 "$install_dir"
chmod 0750 "$logs_dir"
chmod 0700 "$config_dir"
: > "$config_dir/$INCOMPLETE_MARKER"
say "  $install_dir/$AGENT_BIN, $config_dir, $logs_dir"

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t aispm-install)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

verify() { # <file> <expected sha256> <label>
	got=$(sha256_of "$1")
	[ "$got" = "$2" ] || die $EX_DOWNLOAD "$3 failed its checksum: expected $2, got $got (corrupted download, or a tampered artifact — do not run it)"
}

# --------------------------------------------------------------- 5. binary + config
step "Downloading the agent"
say "  $bin_url"
# The Windows agent is ~190 MB, so a flat deadline would fail a perfectly healthy download on a
# slow link. Abort on a STALLED transfer instead (under 10 KB/s for a minute), with a generous
# overall ceiling.
curl -fsSL --speed-limit 10240 --speed-time 60 --max-time 3600 -o "$tmp/$AGENT_BIN" "$bin_url" || die $EX_DOWNLOAD "cannot download the agent binary from $bin_url (interrupted or stalled)"
verify "$tmp/$AGENT_BIN" "$bin_sha" "the agent binary"
chmod 0755 "$tmp/$AGENT_BIN"
mv -f "$tmp/$AGENT_BIN" "$install_dir/$AGENT_BIN"
say "  installed $install_dir/$AGENT_BIN (sha256 verified)"

# The catalogues in effect are retained BEFORE they are overwritten, and the ordering is the whole
# point: the loop below rewrites every *.default.yaml in place, so after it runs the catalogue this
# host was actually using no longer exists anywhere. An identity comparison needs both sides, which
# makes it impossible to write after the fact rather than merely unwritten.
#
# The binary installed above is what takes the snapshot, so this needs no shell knowledge of the
# managed/ layout. It never fails the install: a diagnostic snapshot is not worth a working agent.
step "Retaining the catalogues currently in effect"
set +e
"$install_dir/$AGENT_BIN" -retain-catalogues -config "$config_dir"
set -e

step "Installing the configuration"
say "  $cfg_url"
curl -fsSL --speed-limit 10240 --speed-time 60 --max-time 600 -o "$tmp/config.tar.gz" "$cfg_url" || die $EX_DOWNLOAD "cannot download the configuration bundle from $cfg_url (interrupted or stalled)"
verify "$tmp/config.tar.gz" "$cfg_sha" "the configuration bundle"
mkdir -p "$tmp/config"
tar -xzf "$tmp/config.tar.gz" -C "$tmp/config" || die $EX_FAIL "cannot unpack the configuration bundle"
# Default catalogues are versioned with the binary and always refreshed; anything an operator
# may have edited (agent.yaml, *.custom.yaml) is installed only when absent.
for f in "$tmp"/config/*; do
	[ -f "$f" ] || continue
	base=$(basename -- "$f")
	# Skip AppleDouble side files: a bundle ever packed on macOS carries ._* siblings, and
	# copying them into config/ leaves junk the agent would scan (deploy-windows.ps1 filters
	# them for the same reason).
	case "$base" in ._*) continue ;; esac
	case "$base" in
	*.default.yaml) cp -f "$f" "$config_dir/$base" ;;
	# A bundled agent.yaml is installed as a REFERENCE only: the live one is written below with
	# this platform's URL and token path, and letting the bundle land on agent.yaml would make
	# that step think an operator had already configured the agent.
	agent.yaml|agent.yaml.example) cp -f "$f" "$config_dir/agent.yaml.example" ;;
	*) [ -f "$config_dir/$base" ] || cp "$f" "$config_dir/$base" ;;
	esac
done
say "  catalogues installed in $config_dir"

# ------------------------------------------------------------------- 6. token
token_path="$config_dir/bootstrap.token"
if [ -n "$token_file" ]; then
	[ -f "$token_file" ] || die $EX_USAGE "--token-file '$token_file' does not exist"
	cp "$token_file" "$token_path"
elif [ -n "$token" ]; then
	printf '%s\n' "$token" > "$token_path"
fi
[ ! -f "$token_path" ] || chmod 0600 "$token_path"

# agent.yaml carries the two settings the agent needs to enrol. Written only when absent, so a
# re-run never clobbers an operator's edits.
if [ ! -f "$config_dir/agent.yaml" ]; then
	# The logging settings are seeded, not left to the run command: it makes the preflight below
	# exercise the FATAL log-writable check (which only exists when logging.output is a file), so an
	# unwritable log directory is caught here instead of at the operator's first launch. It also
	# keeps truncate off — the default empties the log at every start.
	cat > "$config_dir/agent.yaml" <<YAML
# Written by install.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) — agent $version
platform:
  url: $platform_url
  bootstrap_token_file: $token_path
logging:
  output: $logs_dir/agent.log
  truncate: false
  max_size_mb: 50
YAML
	# Only written when it differs from the agent's own default, so agent.yaml does not carry a
	# redundant setting — but a floor the operator chose here also governs every later start.
	if [ "$MIN_FREE_MB" != "2048" ]; then
		printf 'preflight:\n  min_free_disk_mb: %s\n' "$MIN_FREE_MB" >> "$config_dir/agent.yaml"
	fi
	chmod 0640 "$config_dir/agent.yaml"
	say "  wrote $config_dir/agent.yaml"
else
	say "  kept the existing $config_dir/agent.yaml"
	grep -q "$platform_url" "$config_dir/agent.yaml" 2>/dev/null || \
		warn "the existing agent.yaml does not mention $platform_url — check platform.url and platform.bootstrap_token_file"
fi

# --------------------------------------------------------------- 7. preflight + enroll
if [ "$re_enroll" -eq 1 ] && [ -f "$config_dir/credential.json" ]; then
	say "  --re-enroll: discarding the stored credential (the platform revokes its key on the next enrollment)"
	rm -f "$config_dir/credential.json"
fi

step "Running the agent's preflight"
# -preflight-save also persists host.json, which the enrollment below reads to record the cloud
# environment. Without it every agent would enrol as on-premise.
set +e
"$install_dir/$AGENT_BIN" -preflight-save -config "$config_dir"
pf_code=$?
set -e
[ "$pf_code" -eq 0 ] || die $EX_PREFLIGHT "the agent's preflight refused this host (see the failed checks and their remediation above)"

step "Enrolling agent $version with $platform_url"
set +e
"$install_dir/$AGENT_BIN" -enroll-only -config "$config_dir"
enroll_code=$?
set -e
if [ "$enroll_code" -ne 0 ]; then
	case "$enroll_code" in
	10) say ""; say "The bootstrap token was rejected. Issue a new one from Agents Fleet -> Deploy agent"
	    say "(or POST $platform_url/aispm/api/v1/agent/admin/bootstrap-tokens with a tenant API key"
	    say "carrying agent:manage) and re-run this installer; tokens are single-use and short-lived." ;;
	11) say ""; say "The agent could not reach $platform_url even though this installer could."
	    say "Check egress rules and TLS trust for the agent's own process, and HTTPS_PROXY if this host needs a proxy." ;;
	12) say ""; say "The agent rejected its configuration. Check platform.url and platform.bootstrap_token_file"
	    say "in $config_dir/agent.yaml." ;;
	13) say ""; say "The platform answered but cannot enrol this host — usually its agent signing keys"
	    say "are not provisioned yet. Ask the platform administrator, then re-run this installer." ;;
	esac
	exit "$enroll_code"
fi

# ---------------------------------------------------- 7c. fetch the published configuration
# The catalogues this installer shipped are a FLOOR, not the answer: the platform is the authority on
# which applications are known and how they are identified, and a host installed today would otherwise
# run last release's catalogue until its own pull loop came round. Fetching here closes that window, and
# it is the one moment where putting a configuration into effect costs nothing — no agent is running, so
# nothing is swapped out from under a reader.
#
# Deliberately NEVER fatal. Every failure leaves the installer's catalogues in effect, which is a
# supported way to run, and the agent retries on its own. Only a REFUSED manifest (22) and a
# configuration fault (12) are worth a word to the operator.
step "Fetching the configuration the platform publishes"
set +e
"$install_dir/$AGENT_BIN" -config-fetch-only -config "$config_dir"
cfg_code=$?
set -e
case "$cfg_code" in
0)  ;;
20) say "  nothing is published for this agent yet — the catalogues this installer shipped are in effect" ;;
21) say "  the platform did not answer — the catalogues this installer shipped are in effect;"
    say "  the agent fetches again on its own once it is running" ;;
22) warn "the platform published a configuration this agent REFUSED (see the reason above)."
    warn "The catalogues this installer shipped are in effect. This is a fault in what was published,"
    warn "not on this host: report it to the platform administrator." ;;
*)  warn "the configuration fetch reported code $cfg_code; the catalogues this installer shipped are in effect" ;;
esac

rm -f "$config_dir/$INCOMPLETE_MARKER"

# ------------------------------------------------- 7b. run at boot (Linux: systemd unit)
# Without this the agent only runs while someone keeps a terminal open, which is not an install —
# and on Linux the usual workaround is worse than no service: an agent started over SSH dies with
# the session, unsupervised, and its death can take the applications it had instrumented with it.
linux_service=0
if [ "$os" = "linux" ] && [ -d /run/systemd/system ]; then
	linux_service=1
	step "Registering the systemd service"
	unit="$SYSTEMD_DIR/$SYSTEMD_UNIT"

	# Notes on the choices below, because each one has a failure mode if changed:
	#
	#  Restart=on-failure   restart the agent when it CRASHES, but leave it stopped after a clean
	#                       exit — so `systemctl stop` actually stops it instead of being fought by
	#                       systemd. Same reasoning as launchd's SuccessfulExit=false on macOS.
	#  TimeoutStopSec=30    systemd SIGKILLs 90s after SIGTERM by default, which sounds generous
	#                       until a shutdown is waiting on a slow flush; 30s is stated rather than
	#                       inherited so the value is reviewable. KillSignal stays the default
	#                       SIGTERM, which is what the agent's signal handler shuts down on.
	#  no sandboxing        deliberate. ProtectSystem/PrivateTmp/ProtectProc and friends would each
	#                       break something this agent must do: read every process's /proc entry,
	#                       open a netlink connector socket, and write its own logs and credential.
	#                       A hardened unit here produces an agent that starts and sees nothing.
	#  no CPUQuota/Nice     also deliberate, and for the macOS reason: a throttled agent that cannot
	#                       drain its kernel event stream fast enough loses events. The agent
	#                       measures and reports its own footprint instead (see `health`).
	#  journal output       stdout/stderr go to the journal (journalctl -u), a catch-all for panics
	#                       and for failures before the agent's own logging is up. The real log is
	#                       agent.log, configured in agent.yaml.
	cat > "$unit" <<UNIT
[Unit]
Description=AISPM host agent
Documentation=https://github.com/${RELEASES_OWNER}/${RELEASES_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$install_dir/$AGENT_BIN -config $config_dir
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT
	chmod 0644 "$unit"
	systemctl daemon-reload || die $EX_FAIL "systemctl daemon-reload failed — $unit is written but systemd has not read it"
	systemctl enable "$SYSTEMD_UNIT" >/dev/null 2>&1 || die $EX_FAIL "systemctl enable failed — the agent is installed but will NOT start at boot; enable it with: systemctl enable $SYSTEMD_UNIT"
	say "  $unit written and enabled (starts at boot)"
	if [ "$no_start" -eq 1 ]; then
		say "  NOT started (--no-start)"
	else
		# RESTART, not start. `start` is a no-op on a unit that is already running, and an UPGRADE is
		# exactly that case: a re-run of this installer replaces the binary on disk and the OLD one
		# keeps executing, while the installer prints "started". Measured consequence: a host reports
		# the previous version indefinitely and nobody can tell from here.
		#
		# restart is also correct on a fresh install (it starts a stopped unit), so there is one path
		# rather than a conditional. It sends SIGTERM and honours TimeoutStopSec=30, which is the same
		# clean shutdown `systemctl stop` gives — never a hard kill.
		# `if`, not `cmd && var=1`: this script runs under `set -e`, and whether a failing left-hand
		# side of && aborts it is exactly the kind of shell subtlety not worth depending on. `if` is
		# unambiguously exempt, and an inactive unit is the NORMAL case on a fresh install.
		was_active=0
		if systemctl is-active --quiet "$SYSTEMD_UNIT"; then was_active=1; fi
		systemctl restart "$SYSTEMD_UNIT" || die $EX_FAIL "systemctl restart failed — see: systemctl status $SYSTEMD_UNIT and journalctl -u $SYSTEMD_UNIT"
		systemctl is-active --quiet "$SYSTEMD_UNIT" || die $EX_FAIL "$SYSTEMD_UNIT did not stay active — see: journalctl -u $SYSTEMD_UNIT"
		if [ "$was_active" -eq 1 ]; then
			say "  restarted (it was already running: this is an upgrade, and the new binary is now the one executing)"
		else
			say "  started"
		fi
	fi
elif [ "$os" = "linux" ]; then
	# Said, not silent: on a host without systemd there is no service to install, and the operator
	# needs to know the agent will only run for as long as they keep something running it.
	warn "no systemd on this host (/run/systemd/system is absent): no service was installed, and the agent will NOT start at boot. Run it from a supervisor of your own, or by hand with the command below."
fi

# ------------------------------------------------- 7b. run at boot (macOS: launchd daemon)
if [ "$os" = "darwin" ]; then
	step "Registering the launchd daemon"
	plist="$LAUNCHD_DIR/$LAUNCHD_LABEL.plist"

	# Notes on the choices below, because each one has a failure mode if changed:
	#
	#  KeepAlive/SuccessfulExit=false  restart the agent when it CRASHES, but leave it stopped
	#                                  after a clean exit — so `launchctl bootout` actually stops
	#                                  it instead of being fought by launchd.
	#  ExitTimeOut 30                  launchd SIGKILLs 20s after SIGTERM by default. A hard kill
	#                                  loses whatever the agent had not yet reported, so it is
	#                                  given room to shut down cleanly.
	#  no ProcessType                  the default (Standard) is deliberate: the Background type
	#                                  throttles CPU and I/O, and a throttled agent that cannot
	#                                  drain its EndpointSecurity stream fast enough is
	#                                  DISCONNECTED by the kernel. Do not "optimise" this.
	#  Standard{Out,Error}Path         a catch-all for panics and for failures that happen before
	#                                  the agent's own logging is up; the real log is agent.log.
	cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LAUNCHD_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$install_dir/$AGENT_BIN</string>
		<string>-config</string>
		<string>$config_dir</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ExitTimeOut</key>
	<integer>30</integer>
	<key>StandardOutPath</key>
	<string>$logs_dir/agent.launchd.out.log</string>
	<key>StandardErrorPath</key>
	<string>$logs_dir/agent.launchd.err.log</string>
</dict>
</plist>
PLIST
	# launchd refuses a plist that is group- or world-writable, and does so quietly.
	chown root:wheel "$plist" || die $EX_FAIL "cannot set ownership on $plist"
	chmod 0644 "$plist"

	# bootout first so a re-run replaces the daemon instead of failing on "service already loaded".
	# It fails when nothing is loaded, which is the normal first-install case.
	launchctl bootout "system/$LAUNCHD_LABEL" >/dev/null 2>&1 || true

	# bootout RETURNS BEFORE THE SERVICE IS GONE, and a bootstrap issued while the old job is still
	# tearing down fails with "Bootstrap failed: 5: Input/output error" — which reads as a broken
	# plist and is not one. The window is as long as the running agent takes to drain, bounded by
	# the ExitTimeOut above. Measured on a real upgrade: the agent logged "agent stopping" and
	# "agent stopped" 469 ms apart and the install failed inside those 469 ms, leaving a host with
	# a correctly installed, correctly enrolled agent that would never start.
	#
	# So wait for the label to actually leave the domain. Polling `print` is the only reliable
	# signal: bootout's exit status says it was ACCEPTED, not that it finished.
	waited=0
	while launchctl print "system/$LAUNCHD_LABEL" >/dev/null 2>&1; do
		if [ "$waited" -ge "$LAUNCHD_BOOTOUT_WAIT" ]; then
			die $EX_FAIL "the previous $LAUNCHD_LABEL daemon is still shutting down after ${LAUNCHD_BOOTOUT_WAIT}s — it may be stuck draining. Check $logs_dir/agent.log, then re-run this installer"
		fi
		sleep 1
		waited=$((waited + 1))
	done

	if [ "$no_start" -eq 1 ]; then
		# The plist is written but NOT loaded, so the agent is neither running nor set to start at
		# boot until somebody loads it. That is the point: on macOS the TCC grant is bound to the
		# binary's hash, and an agent that starts before the grant runs its whole session degraded.
		# The note at the end of this script has always said to grant it AFTER installing — this is
		# the option that makes that possible.
		say "  $plist written, NOT loaded (--no-start)"
		say ""
		say "  Grant Full Disk Access to $install_dir/$AGENT_BIN, then either:"
		say "    sudo launchctl bootstrap system $plist          # the daemon, starts at boot"
		say "    sudo $install_dir/$AGENT_BIN -config $config_dir -ttl 5m   # one bounded session"
	else
	launchctl bootstrap system "$plist" || die $EX_FAIL "launchctl could not load $plist — the agent is installed and enrolled but will NOT start at boot; load it manually with: sudo launchctl bootstrap system $plist"
	launchctl print "system/$LAUNCHD_LABEL" >/dev/null 2>&1 || die $EX_FAIL "the launchd daemon $LAUNCHD_LABEL did not come up — check $logs_dir/agent.launchd.err.log"
	say "  $plist loaded ($LAUNCHD_LABEL), starts at boot"
	fi
fi

# ------------------------------------------------------------------ 8. how to run
if [ "$os" = "darwin" ]; then
# Said, not assumed: with --no-start nothing is loaded, and a closing line claiming "it is running
# now" is the kind of sentence an operator believes instead of checking.
if [ "$no_start" -eq 1 ]; then
	run_state="It is NOT loaded and NOT running: --no-start was given, so grant Full Disk Access first (see above)."
else
	run_state="It is running now."
fi
cat <<FINAL_MAC

==> Installed: aispm-agent $version in $install_dir

The agent runs as a launchd daemon ($LAUNCHD_LABEL) and starts at boot. $run_state

Stop it CLEANLY:

  sudo launchctl bootout system/$LAUNCHD_LABEL

  That sends SIGTERM and lets the agent shut down. NEVER 'kill -9': a hard kill loses whatever
  it had not yet reported.

Start it again:

  sudo launchctl bootstrap system $LAUNCHD_DIR/$LAUNCHD_LABEL.plist

Status:     sudo launchctl print system/$LAUNCHD_LABEL
Uninstall:  sudo $0 --uninstall
Logs:       $logs_dir   (agent.log; agent.launchd.err.log for startup failures)
Config:     $config_dir   (agent.yaml, catalogues, credential.json)

Coverage on this host: processes and listening ports. Connection flows and communications are
not captured on macOS by this build, and the platform is told so — see the notice above.
FINAL_MAC
else
if [ "$linux_service" -eq 1 ]; then
if [ "$no_start" -eq 1 ]; then
	run_state="It is enabled but NOT running: --no-start was given."
else
	run_state="It is running now."
fi
cat <<FINAL_SYSTEMD

==> Installed: aispm-agent $version in $install_dir

The agent runs as a systemd service ($SYSTEMD_UNIT) and starts at boot. $run_state

Stop it CLEANLY:

  sudo systemctl stop $SYSTEMD_UNIT

  That sends SIGTERM and gives the agent 30s to shut down. NEVER 'kill -9': a hard kill can
  crash or freeze the applications the agent was monitoring, and loses whatever it had not yet
  reported.

Start it again:  sudo systemctl start $SYSTEMD_UNIT
Status:          systemctl status $SYSTEMD_UNIT
Service log:     journalctl -u $SYSTEMD_UNIT        (startup failures and panics)
Agent log:       $logs_dir/agent.log                (what it observed; rotated at 50 MiB)
Config:          $config_dir   (agent.yaml, catalogues, credential.json)

Uninstall:       sudo $0 --uninstall

Coverage on this host: processes from the kernel's netlink connector (falling back to sweeping
/proc, which the agent declares), listening ports and established TCP connections polled, the
plaintext of TLS that goes through OpenSSL, and container attribution. No byte volumes — and
whatever this host cannot do, the platform is told; see the notice above.
FINAL_SYSTEMD
else
cat <<FINAL

==> Installed: aispm-agent $version in $install_dir

No service was installed (no systemd on this host). Start the agent:

  sudo $install_dir/$AGENT_BIN -config $config_dir

  It runs in the foreground and stops when that command does, so start it from something that
  outlives your session — never over SSH, where it dies with the connection, unsupervised, and
  can take the applications it had instrumented with it.

  (The log destination is already set in $config_dir/agent.yaml — $logs_dir/agent.log,
   appended to rather than truncated, and size-bounded by rotation (logging.max_size_mb,
   50 MiB; the current file plus one agent.log.1, so ~2x that on disk).)

Stop it CLEANLY — Ctrl+C, or:

  sudo kill -TERM \$(pgrep -f '$AGENT_BIN -config')

  NEVER 'kill -9'. A hard kill can crash or freeze the applications the agent was monitoring,
  and loses whatever it had not yet reported. Always let it shut down.

Logs:       $logs_dir
Config:     $config_dir   (agent.yaml, catalogues, credential.json)

Uninstall:  sudo $0 --uninstall

Coverage on this host: processes from the kernel's netlink connector (falling back to sweeping
/proc, which the agent declares), listening ports and established TCP connections polled, the
plaintext of TLS that goes through OpenSSL, and container attribution. No byte volumes — and
whatever this host cannot do, the platform is told; see the notice above.
FINAL
fi
fi
exit $EX_OK
