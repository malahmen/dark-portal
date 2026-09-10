#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# dark-portal.sh — the gateway your clients step through onto a realm.
#
# A gum-free, flag-driven engine that provisions and launches one or more
# vanilla WoW (1.12.1) game clients under Wine, for multiboxing on a single
# Linux PC. Companion to the nordrassil server engine — this never touches the
# server, it only sets up the player-facing client(s) that connect to one.
# scomp-link ships a thin gum TUI (wow-dark-portal) that drives this by flags;
# nothing here needs gum.
#
# Wine runtime: Bottles (Flatpak, com.usebottles.bottles), not a host-layered
# wine/wine-core package. On immutable/atomic hosts (e.g. Bazzite) a layered
# wine-core needs a reboot before it's even usable, and its 'wineboot --init'
# has been observed to hang indefinitely on some builds. Bottles bundles its
# own known-good Wine runner (e.g. soda-9.x), needs no reboot, and — being a
# Flatpak — works the same way on any distro with Flatpak+Flathub, not just
# rpm-ostree hosts. Each instance below gets its own Bottles "bottle" (a real,
# independent Wine prefix under Bottles' own data dir) — the same
# one-prefix-per-instance isolation the multiboxing design already called for.
#
# Multiboxing requirements this addresses:
#   - Multiple independent client "instances" on the same machine, each with
#     its own Wine prefix / Bottles bottle (registry/DirectX state never
#     collides) and its own WTF/Cache/Logs (account state, saved vars, addon
#     cache never collide).
#   - Each instance launches WoW.exe directly (no Wine virtual desktop
#     wrapper) in ordinary decorated windowed mode, sized via Config.wtf's
#     gxWindow/gxResolution cvars ('launch' re-renders these every time, same
#     idempotent pattern as realmlist.wtf below). An earlier design wrapped
#     each instance in a named Wine virtual desktop (`wine explorer
#     /desktop=<name>,<WxH>`) specifically to get a stable window title, but
#     that virtual desktop container is *itself* a borderless window, which
#     triggered a common WM compatibility heuristic ("undecorated window ==
#     legacy fullscreen game") that force-fullscreened it regardless of the
#     requested size — confirmed on one KDE/KWin desktop, where neither Wine's
#     own "Managed=N" X11-driver registry key nor an external wmctrl/xdotool
#     state override could suppress it. (That registry key is NOT set here —
#     it makes the window override-redirect/unmanaged, which stopped it from
#     ever receiving keyboard focus at all once there was no virtual desktop
#     wrapper left for it to apply to instead.) A plain, undecorated-wrapper-
#     free window doesn't trip the fullscreen heuristic in the first place
#     (verified directly: identical launch, no /desktop=, rendered normally
#     sized and resizable, no _NET_WM_STATE fullscreen/maximized atoms at
#     all) and remains tileable by the WM/user like any other application
#     window — and keeps normal keyboard focus.
#   - Window title stability (for a key broadcaster to target by title,
#     regardless of what the game itself shows — login screen vs. character
#     name vs. realm name all vary at runtime) is instead handled by a small
#     background "title keeper" 'launch' spawns per instance. It can't match
#     the window by PID or WM_CLASS: Bottles' bundled runner has been
#     observed reporting a bogus _NET_WM_PID (likely a Flatpak-sandbox
#     PID-namespace artifact — the in-sandbox PID, not the host one) and a
#     generic WM_CLASS shared by every instance using the same runner (it's
#     Proton-derived), neither of which can tell simultaneously running
#     instances apart. Instead, 'launch' snapshots existing window IDs right
#     before starting the process, and the title keeper diffs against that
#     to find the one new window this launch created, then re-asserts its
#     title to the instance name every couple seconds for as long as the game
#     process is alive, then exits on its own. This needs xdotool and an
#     X11/XWayland-reachable session (WAYLAND_DISPLAY is still unset for
#     every Wine invocation to guarantee that, even though ordinary top-level
#     windows render fine either way — only xdotool/wmctrl's ability to find
#     and rename the window depends on it).
#   - LAN realm discovery: a best-effort TCP port scan of the local /24 for
#     open realm ports (default 3724). This is a port probe, not a full
#     AUTH_LOGON_CHALLENGE handshake — mangos-family forks differ enough at
#     the protocol level that a hand-rolled parser would be a second project;
#     an open realm port on a home LAN is already a strong signal, and the
#     result is always just a prefill you can override.
#
# Client file layout, two isolation modes (picked once in 'configure', a
# per-deployment tradeoff, not a per-instance one):
#   - full   — each instance gets a complete copy of CLIENT_SOURCE_DIR. Costs
#              disk (a full client is a few GB), but every file is a real,
#              independent copy — no shared inode contention. Prefer this at
#              higher instance counts on a single SSD, where many Wine
#              processes reading a symlink-shared Data/ concurrently causes
#              measurable read latency and client disconnects.
#   - shared — each instance symlinks CLIENT_SOURCE_DIR's large/static
#              directories (Data/, Fonts/, Interface/, the .exe, ...) and gets
#              real, private WTF/Cache/Logs/Errors/Screenshots directories.
#              Minimal disk cost, fine at low instance counts.
#
# Self-contained: no shared _common lib, no host package manager — Wine runs
# through the Bottles Flatpak (see below) and the log helpers are inlined.
#
# Bottles' Flatpak sandbox has no access to $HOME by default. 'install-deps'
# grants it read-write access to this script's own CONFIG_DIR (instance data
# lives there) and 'configure' grants read-only access to whatever
# CLIENT_SOURCE_DIR is pointed at, since that can be anywhere (e.g. an
# external drive).
#
# Config: ~/.config/dark-portal/dark-portal.conf (global)
#         ~/.config/dark-portal/instances/<name>/instance.conf (per-instance)
# Bottles' own data (bottles/runners, not managed by this script's config):
#         ~/.var/app/com.usebottles.bottles/data/bottles/
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Self-contained, gum-free log helpers (this is the engine; the scomp-link
# wow-dark-portal front-end owns all interactivity and drives this by flags).
# -----------------------------------------------------------------------------
if [[ -t 2 ]]; then C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_C=$'\033[0;36m'; C_N=$'\033[0m'
else C_G=""; C_Y=""; C_R=""; C_C=""; C_N=""; fi
info()       { printf '%s[info]%s  %s\n' "$C_C" "$C_N" "$*" >&2; }
success()    { printf '%s[ok]%s    %s\n' "$C_G" "$C_N" "$*" >&2; }
warn()       { printf '%s[warn]%s  %s\n' "$C_Y" "$C_N" "$*" >&2; }
error_exit() { printf '%s[error]%s %s\n' "$C_R" "$C_N" "$*" >&2; exit 1; }
header()     { printf '\n%s== %s ==%s\n' "$C_C" "$*" "$C_N" >&2; }

trap 'echo "" >&2; warn "Interrupted."; exit 130' INT TERM

# -----------------------------------------------------------------------------
# Constants / config
# -----------------------------------------------------------------------------

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dark-portal"
CONFIG_DIR="${CONFIG_DIR/#\~/$HOME}"
CONFIG_FILE="${CONFIG_DIR}/dark-portal.conf"
INSTANCES_DIR="${CONFIG_DIR}/instances"
# Per-window claim locks for _title_keeper — see its own comment for why a
# plain "is it already titled" check isn't enough on its own.
WINDOW_CLAIMS_DIR="${CONFIG_DIR}/window-claims"

mkdir -p "$CONFIG_DIR" "$INSTANCES_DIR" "$WINDOW_CLAIMS_DIR"

INSTANCE_NAME_RE='^[A-Za-z0-9_-]{1,32}$'
RESOLUTION_RE='^[0-9]+x[0-9]+$'

BOTTLES_APP_ID="com.usebottles.bottles"
BOTTLES_DATA_DIR="${HOME}/.var/app/${BOTTLES_APP_ID}/data/bottles"

# -----------------------------------------------------------------------------
# Config persistence — generic key=value get/set, parameterized by file so the
# same helpers serve both the global conf and each instance's own conf.
# -----------------------------------------------------------------------------

_cfg_get() {
    local file="$1" key="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/' || true
}
_cfg_set() {
    local file="$1" key="$2" val="$3" tmp
    touch "$file"
    # Rewrite without sed so value metacharacters (| & \) can't corrupt the line:
    # drop any existing entry for this key, then append the new KEY="value".
    tmp="$(mktemp "${file}.XXXXXX")"
    grep -vE "^${key}=" "$file" > "$tmp" 2>/dev/null || true
    printf '%s="%s"\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$file"
}
_cfg_default() {
    local file="$1" key="$2" default="$3" val
    val="$(_cfg_get "$file" "$key")"
    echo "${val:-$default}"
}

cfg_get()     { _cfg_get "$CONFIG_FILE" "$1"; }
cfg_set()     { _cfg_set "$CONFIG_FILE" "$1" "$2"; }
cfg_default() { _cfg_default "$CONFIG_FILE" "$1" "$2"; }

# -----------------------------------------------------------------------------
# Resolved settings (read fresh each invocation)
# -----------------------------------------------------------------------------

_settings() {
    CLIENT_SOURCE_DIR="$(cfg_default CLIENT_SOURCE_DIR "")"
    CLIENT_ISOLATION_MODE="$(cfg_default CLIENT_ISOLATION_MODE full)"   # full|shared
    WINE_ARCH="$(cfg_default WINE_ARCH win32)"                          # win32|win64
    BOTTLES_RUNNER="$(cfg_default BOTTLES_RUNNER "")"                   # e.g. soda-9.0-1
    DEFAULT_RESOLUTION="$(cfg_default DEFAULT_RESOLUTION 1024x768)"
    DEFAULT_REALM_ADDRESS="$(cfg_default DEFAULT_REALM_ADDRESS "")"
    DEFAULT_REALM_PORT="$(cfg_default DEFAULT_REALM_PORT 3724)"
}

# -----------------------------------------------------------------------------
# Bottles (Flatpak) integration — every Wine invocation in this script goes
# through here instead of a host 'wine' binary. See header note for why.
# -----------------------------------------------------------------------------

# _bottles_cli <args...> — runs bottles-cli inside the Bottles Flatpak sandbox.
_bottles_cli() { flatpak run --command=bottles-cli "$BOTTLES_APP_ID" "$@"; }

# _bottle_name <instance> — the underlying Bottles bottle name, namespaced so
# it can never collide with unrelated bottles managed via the Bottles GUI.
_bottle_name() { echo "dp-$1"; }
_bottle_dir()  { echo "${BOTTLES_DATA_DIR}/bottles/$(_bottle_name "$1")"; }
_runner_dir()  { echo "${BOTTLES_DATA_DIR}/runners/${BOTTLES_RUNNER}"; }

# _wine_run <instance> <runner-binary> [args...] — runs one Wine-side binary
# (wine, winecfg, wineserver, ...) against that instance's own bottle, using
# the configured runner, inside the Bottles sandbox. WAYLAND_DISPLAY is unset
# to force XWayland — see header note on the virtual-desktop bug in Wine's
# native Wayland driver.
_wine_run() {
    local instance="$1" bin="$2"; shift 2
    flatpak run --command="$(_runner_dir)/bin/${bin}" \
        --env=WINEPREFIX="$(_bottle_dir "$instance")" \
        --env=WINEDEBUG=-all \
        --unset-env=WAYLAND_DISPLAY \
        "$BOTTLES_APP_ID" "$@"
}

# _bottles_grant_fs_rw/_ro <path> — idempotently grants the Bottles sandbox
# access to a host path outside its own data dir (it has none by default).
_bottles_grant_fs_rw() { flatpak override --user --filesystem="$1" "$BOTTLES_APP_ID"; }
_bottles_grant_fs_ro() { flatpak override --user --filesystem="$1:ro" "$BOTTLES_APP_ID"; }

# _bottles_runners — echoes one non-"sys-*" runner name per line. "sys-*"
# runners proxy this host's own system Wine, which is exactly what we're
# avoiding (see header note on wineboot hangs on layered wine-core builds).
_bottles_runners() {
    _bottles_cli list components 2>/dev/null | awk '
        /^Found [0-9]+ runners/ {grab=1; next}
        /^Found [0-9]+/         {grab=0}
        grab && /^- /           {sub(/^- /, ""); print}
    ' | grep -v '^sys-' || true
}

_ensure_bottles_ready() {
    command -v flatpak &>/dev/null || error_exit "flatpak not found — install-deps requires it (see your distro's docs), then re-run."
    flatpak info "$BOTTLES_APP_ID" &>/dev/null || error_exit "Bottles is not installed — run 'install-deps' first."
    [[ -n "$BOTTLES_RUNNER" ]] || error_exit "No Wine runner configured — run 'configure' first."
    [[ -d "$(_runner_dir)" ]] || error_exit "Configured runner '${BOTTLES_RUNNER}' not found under Bottles — re-run 'configure' to pick an installed one."
}

# -----------------------------------------------------------------------------
# install-deps
# -----------------------------------------------------------------------------

cmd_install_deps() {
    header "dark-portal — Install dependencies"

    command -v flatpak &>/dev/null \
        || error_exit "flatpak not found. Install it via your distro's package manager first (it ships preinstalled on Bazzite and most desktop spins)."

    if flatpak info "$BOTTLES_APP_ID" &>/dev/null; then
        info "Bottles already installed."
    else
        info "Installing Bottles (Flatpak Wine runtime — see header note for why not a host wine package)..."
        flatpak install -y flathub "$BOTTLES_APP_ID" \
            || error_exit "Failed to install Bottles via Flatpak. Is the 'flathub' remote configured? (flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo)"
        success "Bottles installed."
    fi

    _bottles_grant_fs_rw "$CONFIG_DIR"
    info "Granted Bottles sandbox read-write access to ${CONFIG_DIR} (where instance data lives)."

    local runners; runners="$(_bottles_runners)"
    if [[ -z "$runners" ]]; then
        warn "Bottles has no Wine runner downloaded yet. Launch it once from your app menu (or: flatpak run ${BOTTLES_APP_ID}) and let its first-run setup finish downloading one, then re-run 'install-deps'."
    else
        info "Available runners: $(echo "$runners" | tr '\n' ' ')"
    fi

    if command -v nmap &>/dev/null; then
        info "nmap found — 'discover-realm' will use it for a fast LAN scan."
    else
        warn "nmap not found — 'discover-realm' will fall back to a slower pure-bash port scan. Optional: install nmap for faster results."
    fi

    if command -v xdotool &>/dev/null; then
        info "xdotool found — 'launch' will keep each instance's window titled with its instance name."
    else
        warn "xdotool not found — 'launch' will still work, but instance windows will show whatever title the game itself sets instead of a stable per-instance name. Install xdotool for multiboxing key-broadcaster targeting."
    fi

    success "Dependencies checked."
}

# -----------------------------------------------------------------------------
# LAN realm discovery — best-effort TCP port probe (see header note: this is
# NOT a full AUTH_LOGON_CHALLENGE handshake, just "is the realm port open").
# -----------------------------------------------------------------------------

# _local_subnet_base — echoes the /24 base (e.g. "192.168.1") this host's
# default-route interface sits on. Falls back to nothing (caller handles it)
# if no default route is found.
_local_subnet_base() {
    local ip
    ip="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')"
    [[ -z "$ip" ]] && return 1
    echo "${ip%.*}"
}

# _scan_lan_for_port <base> <port> — echoes one IP per line for every host in
# <base>.1-254 with <port> open. Prefers nmap (fast, one process) and falls
# back to a parallel bash /dev/tcp sweep if nmap isn't installed.
_scan_lan_for_port() {
    local base="$1" port="$2"
    if command -v nmap &>/dev/null; then
        nmap -p "$port" --open -T4 -n "${base}.0/24" -oG - 2>/dev/null \
            | awk -v p="$port" '$0 ~ p"/open" {print $2}'
    else
        seq 1 254 | xargs -P 64 -I{} bash -c \
            "timeout 0.4 bash -c 'echo >/dev/tcp/${base}.{}/${port}' 2>/dev/null && echo ${base}.{}"
    fi
}

# discover-realm — scans the LAN and prints each candidate realm IP to STDOUT
# (one per line), so the front-end can present them and let the operator pick.
# Progress/warnings go to stderr, keeping stdout clean/parseable. With --set,
# and only when the scan finds exactly one host, that address is persisted to
# DEFAULT_REALM_ADDRESS (an unambiguous auto-config shortcut for scripting).
cmd_discover_realm() {
    header "dark-portal — Discover realm on LAN"
    _settings

    local port="$DEFAULT_REALM_PORT" do_set=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --port) port="$2"; shift 2 ;;
        --set)  do_set=1; shift ;;
        *) error_exit "discover-realm: unknown flag: $1" ;;
    esac; done

    local base
    base="$(_local_subnet_base)" || error_exit "Could not determine this host's LAN subnet (no default route?). Set the realm address manually with 'set DEFAULT_REALM_ADDRESS <ip>' instead."

    info "Scanning ${base}.0/24 for open tcp/${port} (realm port)... this can take a bit."
    local -a hits=()
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && hits+=("$ip")
    done < <(_scan_lan_for_port "$base" "$port" 2>/dev/null | sort -u || true)

    if [[ ${#hits[@]} -eq 0 ]]; then
        warn "No host on ${base}.0/24 answered on tcp/${port} (port open — not protocol-verified)."
        return 1
    fi

    printf '%s\n' "${hits[@]}"

    if [[ "$do_set" -eq 1 ]]; then
        if [[ ${#hits[@]} -eq 1 ]]; then
            cfg_set DEFAULT_REALM_ADDRESS "${hits[0]}"
            success "DEFAULT_REALM_ADDRESS set to ${hits[0]} (launch always re-renders realmlist.wtf from the current setting)."
        else
            warn "--set ignored: ${#hits[@]} candidates found; pick one and 'set DEFAULT_REALM_ADDRESS <ip>'."
        fi
    fi
}

# -----------------------------------------------------------------------------
# configure — global settings shared by every instance unless overridden
# -----------------------------------------------------------------------------

# configure — NON-INTERACTIVE. Validates the persisted global settings and
# grants the Bottles sandbox the host access it needs, so the deploy commands
# (add-instance/launch) work. The front-end pushes the individual settings
# (CLIENT_SOURCE_DIR, CLIENT_ISOLATION_MODE, WINE_ARCH, BOTTLES_RUNNER,
# DEFAULT_RESOLUTION, DEFAULT_REALM_ADDRESS/PORT) with 'set <KEY> <VALUE>'
# beforehand; this just checks they're coherent.
cmd_configure() {
    header "dark-portal — Configure"
    _settings

    [[ -n "$CLIENT_SOURCE_DIR" ]] || error_exit "CLIENT_SOURCE_DIR not set — 'set CLIENT_SOURCE_DIR /path/to/vanilla/client' first."
    [[ -d "$CLIENT_SOURCE_DIR" ]] || error_exit "Directory not found: ${CLIENT_SOURCE_DIR}"
    [[ -f "${CLIENT_SOURCE_DIR}/WoW.exe" || -f "${CLIENT_SOURCE_DIR}/wow.exe" ]] \
        || error_exit "No WoW.exe found under ${CLIENT_SOURCE_DIR} — is this really the client's install directory?"

    [[ "$CLIENT_ISOLATION_MODE" =~ ^(full|shared)$ ]] || error_exit "CLIENT_ISOLATION_MODE must be full or shared (got '${CLIENT_ISOLATION_MODE}')."
    [[ "$WINE_ARCH" =~ ^(win32|win64)$ ]] || error_exit "WINE_ARCH must be win32 or win64 (got '${WINE_ARCH}')."
    [[ "$DEFAULT_RESOLUTION" =~ $RESOLUTION_RE ]] || error_exit "DEFAULT_RESOLUTION must be WxH, e.g. 1024x768 (got '${DEFAULT_RESOLUTION}')."

    local runners; runners="$(_bottles_runners)"
    [[ -n "$runners" ]] || error_exit "No Bottles Wine runner available yet. Run 'install-deps', then launch Bottles once from your app menu so it can download a runner, then retry."
    [[ -n "$BOTTLES_RUNNER" ]] || error_exit "BOTTLES_RUNNER not set — pick one of: $(echo "$runners" | tr '\n' ' ')and 'set BOTTLES_RUNNER <name>'."
    printf '%s\n' "$runners" | grep -qx "$BOTTLES_RUNNER" \
        || error_exit "Configured runner '${BOTTLES_RUNNER}' is not installed. Available: $(echo "$runners" | tr '\n' ' ')"

    _bottles_grant_fs_ro "$CLIENT_SOURCE_DIR"
    info "Granted Bottles sandbox read-only access to ${CLIENT_SOURCE_DIR}."

    success "Configure complete. Run 'add-instance --name <box>' to provision your first client."
}

# -----------------------------------------------------------------------------
# Instance helpers
# -----------------------------------------------------------------------------

_instance_dir()    { echo "${INSTANCES_DIR}/$1"; }
_instance_conf()   { echo "$(_instance_dir "$1")/instance.conf"; }
_instance_client() { echo "$(_instance_dir "$1")/client"; }
_instance_pidfile(){ echo "$(_instance_dir "$1")/instance.pid"; }

# _require_valid_name <cmd> <name> — the single gate every subcommand that
# takes an instance name goes through before the name is spliced into a
# path. INSTANCE_NAME_RE has no '.' or '/', so '..' or 'a/../b' can never
# reach the rm -rf / pkill in remove-instance and stop, and a typo can't
# silently resolve to a sibling instance's directory.
_require_valid_name() {
    local cmd="$1" name="$2"
    [[ -n "$name" ]] || error_exit "${cmd}: --name is required."
    [[ "$name" =~ $INSTANCE_NAME_RE ]] || error_exit "${cmd}: invalid name '${name}' — only letters, digits, '-' and '_' allowed (max 32 chars)."
}

# Instance names (sorted). A plain glob rather than `find -printf` — portable,
# and safe under `set -o pipefail` (an empty/missing dir yields no output and a
# clean exit, instead of a find failure aborting the caller's assignment).
_list_instance_names() {
    [[ -d "$INSTANCES_DIR" ]] || return 0
    local d
    for d in "$INSTANCES_DIR"/*/; do
        [[ -d "$d" ]] || continue
        basename "$d"
    done | sort
}

# _pid_is_instance <name> <pid> — true only if <pid> is alive AND its argv
# references this instance's own client exe. A pidfile alone isn't proof:
# after a reboot (or a crash that left the file behind) the recorded PID can
# be reused by anything, which would make 'launch' refuse to start and 'stop'
# SIGTERM a stranger. The launcher's argv carries the full exe path (see
# cmd_launch), so that's the fingerprint checked here. /proc is preferred;
# ps is the fallback for hosts without it.
_pid_is_instance() {
    local name="$1" pid="$2" client argv
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    client="$(_instance_client "$name")"
    if [[ -r "/proc/${pid}/cmdline" ]]; then
        argv="$(tr '\0' ' ' < "/proc/${pid}/cmdline")"
    else
        argv="$(ps -ww -o args= -p "$pid" 2>/dev/null || true)"
    fi
    [[ "$argv" == *"${client}/WoW.exe"* || "$argv" == *"${client}/wow.exe"* ]]
}

_instance_running() {
    local name="$1" pf; pf="$(_instance_pidfile "$name")"
    [[ -f "$pf" ]] || return 1
    _pid_is_instance "$name" "$(cat "$pf")"
}

# _regex_escape <string> — escapes ERE metacharacters so a literal path can
# be embedded in a pkill -f / grep -E pattern without '.' or '+' in a
# directory name widening the match.
_regex_escape() { printf '%s' "$1" | sed -e 's/[][\.*^$(){}?+|]/\\&/g'; }

# _instance_exe_pattern <name> — ERE matching an argv that invokes THIS
# instance's exe (either casing the client ships), and nothing else: the
# path is anchored to the exe name and to an argument boundary, so a shell
# that merely cd'd into the client dir, or an editor with a file open under
# it, doesn't match.
_instance_exe_pattern() {
    printf '%s/(WoW|wow)\.exe( |$)' "$(_regex_escape "$(_instance_client "$1")")"
}

# _effective_realm <name> — echoes "address:port" for this instance: its own
# override if set, otherwise the global default.
_effective_realm() {
    local name="$1" iconf; iconf="$(_instance_conf "$name")"
    local addr port
    addr="$(_cfg_default "$iconf" REALM_ADDRESS "$DEFAULT_REALM_ADDRESS")"
    port="$(_cfg_default "$iconf" REALM_PORT "$DEFAULT_REALM_PORT")"
    echo "${addr}:${port}"
}

# _effective_resolution <name>
_effective_resolution() {
    local name="$1" iconf; iconf="$(_instance_conf "$name")"
    _cfg_default "$iconf" RESOLUTION "$DEFAULT_RESOLUTION"
}

# _write_realmlist <name> — (re)writes realmlist.wtf from the instance's
# current effective realm setting. Vanilla (1.12) WoW reads this file from the
# client ROOT next to WoW.exe, not from WTF/ (that's a later-expansion
# convention) — a pristine client commonly ships its own root-level
# realmlist.wtf pointing at whatever server it was originally set up for, so
# this must overwrite that exact path or the client silently keeps using the
# old one. Some client builds (observed on a VanillaGaming.org-distributed
# client) also cache the realm as "SET realmList"/"SET realmName" cvars
# directly in WTF/Config.wtf, which took priority over realmlist.wtf entirely
# — those are stripped out here too so realmlist.wtf is the only thing in
# effect. Safe to call every launch — same idempotent re-derive-from-config
# pattern the server script uses for its own conf files.
_write_realmlist() {
    local name="$1" client_dir realm addr port value config_wtf rc
    client_dir="$(_instance_client "$name")"
    realm="$(_effective_realm "$name")"
    addr="${realm%:*}" port="${realm##*:}"
    [[ -z "$addr" ]] && { warn "No realm address set for '${name}' (global default is empty too) — set one via 'configure' or 'edit-instance'."; return 1; }

    value="$addr"
    [[ "$port" != "3724" ]] && value+=":${port}"

    printf 'set realmlist %s\n' "$value" > "${client_dir}/realmlist.wtf"

    config_wtf="${client_dir}/WTF/Config.wtf"
    if [[ -f "$config_wtf" ]] && grep -qiE '^SET +realm(List|Name)[[:space:]]' "$config_wtf"; then
        # grep -v exits 1 when NOTHING survives the filter (a Config.wtf made
        # of realm lines only) - a legitimate, empty result, not a failure -
        # so only exit >= 2 (unreadable file, bad pattern) is an error. With
        # a plain '&& mv' the exit-1 case skipped the rename and left the
        # stale cvars in place plus an orphaned .tmp next to them.
        rc=0
        grep -viE '^SET +realm(List|Name)[[:space:]]' "$config_wtf" > "${config_wtf}.tmp" || rc=$?
        if (( rc > 1 )); then
            rm -f "${config_wtf}.tmp"
            error_exit "Failed to rewrite ${config_wtf} (grep exited with ${rc})."
        fi
        mv "${config_wtf}.tmp" "$config_wtf"
    fi
}

# _wow_cfg_set <Config.wtf-path> <cvar> <value> — sets/replaces a
# `SET <cvar> "<value>"` line. Distinct file format from this script's own
# KEY="value" config files (_cfg_set) — this is the game's own WTF syntax.
_wow_cfg_set() {
    local file="$1" key="$2" val="$3"
    touch "$file"
    if grep -qE "^SET ${key} " "$file"; then
        sed -i -E "s|^SET ${key} .*|SET ${key} \"${val}\"|" "$file"
    else
        printf 'SET %s "%s"\n' "$key" "$val" >> "$file"
    fi
}

# _write_window_config <name> — pins this instance's client to windowed mode
# at its effective resolution. Now that 'launch' runs WoW.exe directly
# instead of wrapping it in a Wine virtual desktop (see header note), this
# Config.wtf cvar pair is what actually controls the game's own window size.
# Safe to call every launch — same idempotent pattern as _write_realmlist.
_write_window_config() {
    local name="$1" client_dir config_wtf res
    client_dir="$(_instance_client "$name")"
    res="$(_effective_resolution "$name")"
    config_wtf="${client_dir}/WTF/Config.wtf"
    mkdir -p "$(dirname "$config_wtf")"
    _wow_cfg_set "$config_wtf" gxWindow 1
    _wow_cfg_set "$config_wtf" gxResolution "$res"
}

# -----------------------------------------------------------------------------
# add-instance — provisions a Bottles bottle + client directory for one box
# -----------------------------------------------------------------------------

cmd_add_instance() {
    header "dark-portal — Add instance"
    _settings
    _ensure_bottles_ready

    [[ -n "$CLIENT_SOURCE_DIR" ]] || error_exit "Not configured yet — run 'configure' first."

    local name="" res_input="" realm_input="" port_input=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --name)       name="$2"; shift 2 ;;
        --resolution) res_input="$2"; shift 2 ;;
        --realm)      realm_input="$2"; shift 2 ;;
        --port)       port_input="$2"; shift 2 ;;
        *) error_exit "add-instance: unknown flag: $1" ;;
    esac; done

    _require_valid_name add-instance "$name"
    [[ -d "$(_instance_dir "$name")" ]] && error_exit "Instance '${name}' already exists."

    local dir client bottle
    dir="$(_instance_dir "$name")"
    client="$(_instance_client "$name")"
    bottle="$(_bottle_name "$name")"
    mkdir -p "$dir"

    if [[ -n "$res_input" ]]; then
        [[ "$res_input" =~ $RESOLUTION_RE ]] || error_exit "Invalid resolution '${res_input}' (expected WxH)."
        _cfg_set "$(_instance_conf "$name")" RESOLUTION "$res_input"
    fi
    if [[ -n "$realm_input" ]]; then
        _cfg_set "$(_instance_conf "$name")" REALM_ADDRESS "$realm_input"
        _cfg_set "$(_instance_conf "$name")" REALM_PORT "${port_input:-$DEFAULT_REALM_PORT}"
    fi

    info "Creating Bottles bottle '${bottle}' (runner: ${BOTTLES_RUNNER}, arch: ${WINE_ARCH})..."
    flatpak run --command=bottles-cli "$BOTTLES_APP_ID" new \
            --bottle-name "$bottle" --environment application --arch "$WINE_ARCH" --runner "$BOTTLES_RUNNER" \
        || error_exit "Failed to create Bottles bottle for '${name}'. Check that '${BOTTLES_RUNNER}' is a valid installed runner (install-deps)."

    case "$CLIENT_ISOLATION_MODE" in
        full)
            info "Copying client into instance directory (full isolation mode — this can take a while for a multi-GB install)..."
            du -sh "$CLIENT_SOURCE_DIR" 2>/dev/null | while read -r size _; do info "Source size: ${size}"; done
            cp -a "$CLIENT_SOURCE_DIR" "$client" \
                || error_exit "Failed to copy client files for '${name}'."
            ;;
        shared)
            info "Linking shared client files (shared isolation mode)..."
            mkdir -p "$client"
            local entry ename
            while IFS= read -r -d '' entry; do
                ename="$(basename "$entry")"
                case "$ename" in
                    WTF|Cache|Logs|Errors|Screenshots) mkdir -p "${client}/${ename}" ;;
                    # realmlist.wtf must stay private per instance too (see
                    # _write_realmlist) — symlinking it here would make every
                    # instance share, and overwrite, the pristine source's own
                    # copy instead of getting its own realm override.
                    *) [[ "${ename,,}" == "realmlist.wtf" ]] || ln -s "$entry" "${client}/${ename}" ;;
                esac
            done < <(find "$CLIENT_SOURCE_DIR" -mindepth 1 -maxdepth 1 -print0)
            ;;
        *) error_exit "Unknown CLIENT_ISOLATION_MODE '${CLIENT_ISOLATION_MODE}' — expected full|shared." ;;
    esac

    _write_realmlist "$name" || true
    _write_window_config "$name"

    success "Instance '${name}' provisioned. Launch it with 'launch --name ${name}', then log in and create your character as usual — WoW itself has no config for this, account credentials live only in the game/server."
}

# -----------------------------------------------------------------------------
# list-instances / status
# -----------------------------------------------------------------------------

# list-instances — human-readable summary by default. With --names, prints just
# the instance names (one per line) to STDOUT, which the front-end uses to build
# its instance picker.
cmd_list_instances() {
    _settings

    local names_only=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --names) names_only=1; shift ;;
        *) error_exit "list-instances: unknown flag: $1" ;;
    esac; done

    local names; names="$(_list_instance_names)"

    if [[ "$names_only" -eq 1 ]]; then
        [[ -n "$names" ]] && printf '%s\n' "$names"
        return 0
    fi

    header "dark-portal — Instances"
    if [[ -z "$names" ]]; then
        info "No instances configured yet — run 'add-instance'."
        return 0
    fi

    local name running realm res
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        realm="$(_effective_realm "$name")"
        [[ "$realm" == ":"* ]] && realm="<not set>"
        res="$(_effective_resolution "$name")"
        if _instance_running "$name"; then running="running"; else running="stopped"; fi
        printf '%s── %s%s\n' "$C_C" "$name" "$C_N" >&2
        info "  realm: ${realm} | resolution: ${res} | state: ${running}"
    done <<< "$names"
}

cmd_status() { cmd_list_instances; }

# -----------------------------------------------------------------------------
# edit-instance / remove-instance
# -----------------------------------------------------------------------------

# edit-instance --name N [--resolution WxH] [--realm ADDR] [--port P] — updates
# only the per-instance overrides given as flags; anything omitted is left as-is.
# Passing --realm without --port keeps/uses the current-or-default port.
cmd_edit_instance() {
    header "dark-portal — Edit instance"
    _settings

    local name="" res_input="" realm_input="" port_input="" got_port=0
    while [[ $# -gt 0 ]]; do case "$1" in
        --name)       name="$2"; shift 2 ;;
        --resolution) res_input="$2"; shift 2 ;;
        --realm)      realm_input="$2"; shift 2 ;;
        --port)       port_input="$2"; got_port=1; shift 2 ;;
        *) error_exit "edit-instance: unknown flag: $1" ;;
    esac; done

    _require_valid_name edit-instance "$name"
    [[ -d "$(_instance_dir "$name")" ]] || error_exit "No such instance: ${name}"

    local iconf; iconf="$(_instance_conf "$name")"
    local cur_port; cur_port="$(_cfg_get "$iconf" REALM_PORT)"

    if [[ -n "$res_input" ]]; then
        [[ "$res_input" =~ $RESOLUTION_RE ]] || error_exit "Invalid resolution '${res_input}' (expected WxH)."
        _cfg_set "$iconf" RESOLUTION "$res_input"
    fi

    if [[ -n "$realm_input" ]]; then
        _cfg_set "$iconf" REALM_ADDRESS "$realm_input"
        if [[ "$got_port" -eq 1 ]]; then
            _cfg_set "$iconf" REALM_PORT "$port_input"
        else
            _cfg_set "$iconf" REALM_PORT "${cur_port:-$DEFAULT_REALM_PORT}"
        fi
    elif [[ "$got_port" -eq 1 ]]; then
        _cfg_set "$iconf" REALM_PORT "$port_input"
    fi

    _write_realmlist "$name" || true
    _write_window_config "$name"
    success "Instance '${name}' updated."
    if _instance_running "$name"; then
        warn "It's currently running — restart (stop, then launch) for the new settings to take effect."
    fi
}

# remove-instance --name N — deletes the instance dir and its Bottles bottle.
# No confirmation prompt (the front-end confirms); stops it first if running.
cmd_remove_instance() {
    header "dark-portal — Remove instance"
    _settings

    local name=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --name) name="$2"; shift 2 ;;
        *) error_exit "remove-instance: unknown flag: $1" ;;
    esac; done
    _require_valid_name remove-instance "$name"
    [[ -d "$(_instance_dir "$name")" ]] || error_exit "No such instance: ${name}"

    if _instance_running "$name"; then
        _stop_instance_by_name "$name" || true
    fi
    rm -rf "$(_instance_dir "$name")"
    rm -rf "$(_bottle_dir "$name")"
    success "Instance '${name}' removed."
}

# -----------------------------------------------------------------------------
# winecfg — escape hatch for per-instance Wine tuning (DirectX/sound/DLL
# overrides) this script doesn't attempt to guess for every distro/Wine build.
# -----------------------------------------------------------------------------

cmd_winecfg() {
    header "dark-portal — winecfg"
    _settings
    _ensure_bottles_ready

    local name=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --name) name="$2"; shift 2 ;;
        *) error_exit "winecfg: unknown flag: $1" ;;
    esac; done
    _require_valid_name winecfg "$name"
    [[ -d "$(_instance_dir "$name")" ]] || error_exit "No such instance: ${name}"

    _wine_run "$name" winecfg
}

# -----------------------------------------------------------------------------
# launch / stop / stop-all
# -----------------------------------------------------------------------------

cmd_launch() {
    header "dark-portal — Launch"
    _settings
    _ensure_bottles_ready

    local name=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --name) name="$2"; shift 2 ;;
        -*) error_exit "launch: unknown flag: $1" ;;
        *) name="$1"; shift ;;
    esac; done
    _require_valid_name launch "$name"
    [[ -d "$(_instance_dir "$name")" ]] || error_exit "No such instance: ${name}"

    if _instance_running "$name"; then
        warn "'${name}' already appears to be running (pid file present)."
        return 0
    fi

    # Re-render realmlist.wtf and the window-size cvars from current settings
    # every launch — same idempotent re-derive-from-config pattern as the
    # server script's conf files, so an 'edit-instance' or 'configure' change
    # is never silently stale on the next launch.
    _write_realmlist "$name" || return 1
    _write_window_config "$name"

    local client pidfile res exe
    client="$(_instance_client "$name")"
    pidfile="$(_instance_pidfile "$name")"
    res="$(_effective_resolution "$name")"

    exe="${client}/WoW.exe"
    [[ -f "$exe" ]] || exe="${client}/wow.exe"
    [[ -f "$exe" ]] || error_exit "No WoW.exe found in ${client}."

    # Runs WoW.exe directly — no Wine virtual desktop wrapper. See header
    # note: that wrapper is itself a borderless window, which some WMs
    # auto-fullscreen regardless of the requested size; a plain window
    # doesn't trip that and stays normally tileable/resizable.
    #
    # Snapshot existing windows *before* launching so _title_keeper can find
    # the new one this instance creates by diffing, rather than by PID or
    # WM_CLASS — Bottles' bundled runner has been observed reporting a bogus
    # _NET_WM_PID (likely a Flatpak-sandbox PID-namespace artifact: the
    # in-sandbox PID, not the host one) and a generic WM_CLASS shared by every
    # instance using the same runner (it's Proton-derived), so neither can
    # tell two simultaneously running instances apart. A window that didn't
    # exist a moment ago and now does, right as this instance started, can
    # only be this instance's.
    local before_windows=""
    command -v xdotool &>/dev/null && before_windows="$(xdotool search --name "." 2>/dev/null)"

    info "Launching '${name}' (windowed ${res}, realm $(_effective_realm "$name"))..."
    (cd "$client" && nohup flatpak run --command="$(_runner_dir)/bin/wine" \
            --env=WINEPREFIX="$(_bottle_dir "$name")" --env=WINEDEBUG=-all --unset-env=WAYLAND_DISPLAY \
            "$BOTTLES_APP_ID" "$exe" \
        >> "${client}/../wine.log" 2>&1 &
     echo "$!" > "$pidfile")

    # Flatpak sandbox setup + wineserver spin-up + DXVK's cold-cache shader
    # compile can comfortably take longer than a flat 1s check would allow —
    # poll for a few seconds instead of declaring failure too early.
    local waited=0
    while (( waited < 10 )) && ! _instance_running "$name"; do
        sleep 1; waited=$((waited + 1))
    done
    if _instance_running "$name"; then
        if command -v xdotool &>/dev/null; then
            _title_keeper "$name" "$before_windows" >/dev/null 2>&1 &
            disown
            info "Window title will switch to '${name}' within a few seconds."
        fi
        success "'${name}' launched."
    else
        warn "'${name}' did not seem to start — check $(_instance_dir "$name")/wine.log"
    fi
}

# _title_keeper <name> <before-windows> — runs in the background for as long
# as the instance's WoW.exe process is alive, re-asserting its window title
# to the instance name every couple seconds. See header/launch notes on why:
# dropping the virtual desktop wrapper (to avoid the WM auto-fullscreen
# issue) lost its built-in title-naming, the game's own title changes at
# runtime on its own (login vs character select vs in-world) so a one-shot
# rename isn't enough, and neither PID nor WM_CLASS can identify which
# window is this instance's — <before-windows> (a newline-separated list of
# window IDs captured right before this instance launched) is diffed against
# the live list to find windows this launch actually created. The game also
# opens small helper windows around the same time (observed: "Default IME",
# "Input", ~1x1-119x34px) alongside its real ~800x600+ one, so among the new
# windows the largest by area is taken to be the actual game window, not
# just whichever the diff happens to list first.
#
# Found live: launching two instances close together (the normal way to set
# up a multibox session) races this diff. Instance B's window is "new since
# instance A's before-snapshot" too, since A's snapshot was taken before B
# even started — so if B's window loads faster/bigger than A's own window at
# that instant, A's keeper claims B's window as its own. Both keepers then
# fight over that one window every ~2s, each renaming it back to their own
# name, while the *other* real window sits untitled forever. Confirmed live:
# the same KWin internalId/PID observed labeled two different instance names
# 15 seconds apart.
#
# First fix attempt — skip any candidate whose CURRENT title already matches
# some *other* instance's name — was insufficient on its own: it only
# excludes windows a sibling keeper has *already renamed*. Launching two
# instances truly simultaneously (confirmed live) has both keepers reach the
# same still-untitled candidate before either has renamed anything, so both
# pass that check and both commit to it. Fixed for real with a proper mutual
# exclusion: WINDOW_CLAIMS_DIR/<window id>, created via `mkdir` — atomic on
# POSIX filesystems, so when two keepers race to claim the same window id at
# the same instant, exactly one `mkdir` succeeds and the other correctly
# fails and keeps searching. The title-match check stays too, as a cheap
# pre-filter that avoids even attempting to claim an obviously-already-named
# window. The claim is released once this keeper's own loop ends (game
# closed), so a later launch reusing that window id isn't blocked forever.
_title_keeper() {
    local name="$1" before="$2" client wid current waited
    local candidates cand WIDTH HEIGHT area best_area best_cand cand_title other_names

    client="$(_instance_client "$name")"
    other_names="$(_list_instance_names | grep -vxF "$name" || true)"

    wid="" waited=0
    while [[ -z "$wid" ]] && (( waited < 30 )) && pgrep -f "${client}/WoW.exe" >/dev/null 2>&1; do
        candidates="$(comm -13 <(printf '%s\n' "$before" | sort -u) <(xdotool search --name "." 2>/dev/null | sort -u))"
        best_area=0 best_cand=""
        while IFS= read -r cand; do
            [[ -z "$cand" ]] && continue
            [[ -d "${WINDOW_CLAIMS_DIR}/${cand}" ]] && continue
            cand_title="$(xdotool getwindowname "$cand" 2>/dev/null || true)"
            [[ -n "$cand_title" ]] && grep -qxF "$cand_title" <<< "$other_names" && continue
            WIDTH="" HEIGHT=""
            eval "$(xdotool getwindowgeometry --shell "$cand" 2>/dev/null | grep -E '^(WIDTH|HEIGHT)=')"
            [[ -z "$WIDTH" || -z "$HEIGHT" ]] && continue
            area=$(( WIDTH * HEIGHT ))
            if (( area > best_area )); then
                best_area=$area
                best_cand="$cand"
            fi
        done <<< "$candidates"
        # A real game window is comfortably larger than the tiny IME/helper
        # popups — require at least 100x100 before even trying to claim,
        # otherwise keep searching in case the actual window hasn't
        # appeared yet. The mkdir is the actual race-proof claim: the size
        # check above can pass for two keepers on the same candidate in the
        # same instant, but only one of them wins this.
        if (( best_area >= 10000 )) && mkdir "${WINDOW_CLAIMS_DIR}/${best_cand}" 2>/dev/null; then
            wid="$best_cand"
        else
            sleep 1; waited=$((waited + 1))
        fi
    done
    [[ -z "$wid" ]] && return 0
    trap 'rmdir "${WINDOW_CLAIMS_DIR}/${wid}" 2>/dev/null || true' RETURN

    while pgrep -f "${client}/WoW.exe" >/dev/null 2>&1; do
        current="$(xdotool getwindowname "$wid" 2>/dev/null || true)"
        [[ "$current" == "$name" ]] || xdotool set_window --name "$name" "$wid" 2>/dev/null || true
        sleep 2
    done
}

_stop_instance_by_name() {
    local name="$1" pidfile pid
    pidfile="$(_instance_pidfile "$name")"

    if [[ ! -f "$pidfile" ]]; then
        info "'${name}' not running."
        return 0
    fi
    pid="$(cat "$pidfile")"

    # wineserver -k tears down every process tied to this bottle (explorer,
    # the game, any helper processes it spawned) — more reliable than killing
    # just the tracked launcher pid, since Wine's process tree is several
    # levels deep and each bottle's wineserver instance is independent of the
    # others, so it can't affect a different instance. In practice it's not
    # always synchronous/complete (observed leaving the outer wine/explorer
    # wrapper alive after the game process itself exited) — a pkill on this
    # instance's own exe invocation is the fallback, since that path is
    # unique per instance and shows up verbatim in the whole process chain's
    # argv (wine/explorer/WoW.exe all reference it directly). The pattern is
    # anchored to '<client>/WoW.exe' as a whole argument (not the bare client
    # dir) so a shell or editor that merely mentions the directory survives,
    # and the pidfile PID is only signalled once its argv proves it's still
    # ours — a stale file from before a reboot may point at anything.
    _wine_run "$name" wineserver -k 2>/dev/null || true
    if _pid_is_instance "$name" "$pid"; then
        kill "$pid" 2>/dev/null || true
    else
        info "Stale pid file for '${name}' (pid ${pid} is gone or not ours) — skipping it."
    fi
    sleep 1
    pkill -9 -f "$(_instance_exe_pattern "$name")" 2>/dev/null || true
    rm -f "$pidfile"
    success "'${name}' stopped."
}

cmd_stop() {
    header "dark-portal — Stop"
    _settings
    _ensure_bottles_ready

    local name=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --name) name="$2"; shift 2 ;;
        -*) error_exit "stop: unknown flag: $1" ;;
        *) name="$1"; shift ;;
    esac; done
    _require_valid_name stop "$name"
    [[ -d "$(_instance_dir "$name")" ]] || error_exit "No such instance: ${name}"

    _stop_instance_by_name "$name"
}

cmd_stop_all() {
    header "dark-portal — Stop all"
    _settings
    _ensure_bottles_ready

    local names; names="$(_list_instance_names)"
    [[ -z "$names" ]] && { info "No instances configured."; return 0; }

    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        _instance_running "$name" && _stop_instance_by_name "$name"
    done <<< "$names"
}

# -----------------------------------------------------------------------------
# Config subcommands — the front-end (scomp-link's wow-dark-portal TUI) collects
# values with gum and pushes them here; the engine only reads/writes the flat
# key=value global config file. 'set'/'get' expose that store directly.
# -----------------------------------------------------------------------------

cmd_set() {
    _settings
    [[ $# -eq 2 ]] || error_exit "set: usage: set KEY VALUE"
    cfg_set "$1" "$2"
    success "Set ${1}."
}

cmd_get() {
    _settings
    [[ $# -eq 1 ]] || error_exit "get: usage: get KEY"
    # Return the EFFECTIVE value: for a known setting _settings has already
    # resolved it (config value or default), so echo that global; otherwise the
    # raw config store. Lets the front-end pre-fill prompts with real defaults.
    local key="$1"
    if declare -p "$key" &>/dev/null; then
        printf '%s\n' "${!key}"
    else
        cfg_get "$key"
    fi
}

cmd_config() {
    _settings
    [[ -f "$CONFIG_FILE" ]] && cat "$CONFIG_FILE" || info "No config yet at ${CONFIG_FILE}."
}

# list-runners — the Bottles Wine runners available to 'set BOTTLES_RUNNER'
# (one per line, sys-* excluded). The front-end offers these as a picker.
cmd_list_runners() {
    _bottles_runners
}

# -----------------------------------------------------------------------------
# Main dispatch — gum-free, flag-driven.
# -----------------------------------------------------------------------------

usage() {
    cat >&2 <<'EOF'
dark-portal — vanilla WoW (1.12.1) multibox client engine

Usage: dark-portal.sh <command> [flags]

Setup:
  install-deps
  configure                              validate settings + grant Bottles fs access
  discover-realm [--port P] [--set]      scan the LAN, print candidate realm IPs
  winecfg --name N                       open winecfg for one instance's bottle
  list-runners                           available Bottles Wine runners

Instances:
  add-instance --name N [--resolution WxH] [--realm ADDR] [--port P]
  edit-instance --name N [--resolution WxH] [--realm ADDR] [--port P]
  remove-instance --name N
  list-instances [--names]               summary, or bare names with --names

Launch:
  launch --name N
  stop --name N
  stop-all
  status

Config store (used by the scomp-link front-end):
  set KEY VALUE | get KEY | config

Config keys: CLIENT_SOURCE_DIR, CLIENT_ISOLATION_MODE (full|shared),
  WINE_ARCH (win32|win64), BOTTLES_RUNNER, DEFAULT_RESOLUTION,
  DEFAULT_REALM_ADDRESS, DEFAULT_REALM_PORT.
EOF
}

main() {
    [[ $# -gt 0 ]] || { usage; exit 2; }

    local cmd="$1"; shift
    case "$cmd" in
        install-deps)    cmd_install_deps "$@" ;;
        configure)       cmd_configure "$@" ;;
        discover-realm)  cmd_discover_realm "$@" ;;
        add-instance)    cmd_add_instance "$@" ;;
        list-instances)  cmd_list_instances "$@" ;;
        edit-instance)   cmd_edit_instance "$@" ;;
        remove-instance) cmd_remove_instance "$@" ;;
        winecfg)         cmd_winecfg "$@" ;;
        launch)          cmd_launch "$@" ;;
        stop)            cmd_stop "$@" ;;
        stop-all)        cmd_stop_all "$@" ;;
        status)          cmd_status "$@" ;;
        list-runners)    cmd_list_runners "$@" ;;
        set)             cmd_set "$@" ;;
        get)             cmd_get "$@" ;;
        config)          cmd_config "$@" ;;
        -h|--help|help)  usage ;;
        *) error_exit "Unknown command: $cmd (run with --help for usage)" ;;
    esac
}

main "$@"
