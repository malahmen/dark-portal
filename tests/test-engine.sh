#!/usr/bin/env bash
# Kamino items 30-38 (D1-D6 and three smaller ones). No network, no Bottles,
# no display: tests/stubs shadows flatpak and xdotool, HOME and
# XDG_CONFIG_HOME live under a temporary directory, and the "game" is a script
# named WoW.exe, so pgrep/pkill see the argv they see live.
# shellcheck disable=SC2034
# `out`/`rc` are read by the single-quoted assertions chk evaluates.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENG="${DARK_PORTAL:-${TEST_DIR}/../dark-portal.sh}"
[ -f "$ENG" ] || { echo "dark-portal.sh not found at $ENG" >&2; exit 1; }
T="$(mktemp -d)"
# Every "game" runs from under $T, so this pattern can only match this run's.
cleanup() { pkill -9 -f "${T}/" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

export PATH="${TEST_DIR}/stubs:$PATH"
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config"
unset DISPLAY WAYLAND_DISPLAY
mkdir -p "$HOME/.var/app/com.usebottles.bottles/data/bottles/runners/soda-test"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hdr()  { printf '\n\033[36m== %s\033[0m\n' "$1"; }
run()  { bash "$ENG" "$@" 2>&1; }
CONF="$XDG_CONFIG_HOME/dark-portal/dark-portal.conf"
INST="$XDG_CONFIG_HOME/dark-portal/instances"
games() { pgrep -f "${INST}/$1/client/WoW.exe" | wc -l; }   # running "games" of an instance

# A client to provision from, and the settings 'configure' wants.
SRC="$T/client"; mkdir -p "$SRC/Data" "$SRC/WTF"
printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$SRC/WoW.exe"; chmod +x "$SRC/WoW.exe"
run set CLIENT_SOURCE_DIR "$SRC" >/dev/null
run set BOTTLES_RUNNER soda-test >/dev/null
run set DEFAULT_REALM_ADDRESS 192.168.3.52 >/dev/null
out="$(run configure)"; rc=$?
chk "setup: configure passes"                  '[[ $rc -eq 0 ]]'

# ---------------------------------------------------------------- 30 (D1)
hdr "30 — D1: a port is a number"
out="$(cd "$T" && run discover-realm --port '1; touch PWNED; :')"; rc=$?
chk "discover-realm refuses a non-numeric port" '[[ $rc -ne 0 ]] && grep -q "port must be a number" <<<"$out"'
chk "  and ran nothing"                         '[[ ! -e "$T/PWNED" ]]'
for p in 0 65536 abc "80 81"; do
    out="$(run set DEFAULT_REALM_PORT "$p")"; rc=$?
    chk "set DEFAULT_REALM_PORT '$p' refused"    '[[ $rc -ne 0 ]]'
done
out="$(run set DEFAULT_REALM_PORT 3725)"; rc=$?
chk "  a real port is accepted (control)"      '[[ $rc -eq 0 ]] && grep -q "^DEFAULT_REALM_PORT=\"3725\"" "$CONF"'
run set DEFAULT_REALM_PORT 3724 >/dev/null
out="$(run add-instance --name p1 --realm 10.0.0.1 --port 'x;y')"; rc=$?
chk "add-instance refuses a bad port"          '[[ $rc -ne 0 ]] && [[ ! -d "$INST/p1" ]]'
out="$(run set DEFAULT_REALM_ADDRESS $'10.0.0.1\nset accountname x')"; rc=$?
chk "a realm address with a newline is refused" '[[ $rc -ne 0 ]]'
out="$(run set DEFAULT_REALM_ADDRESS 'a b')"; rc=$?
chk "  so is one with a space"                 '[[ $rc -ne 0 ]]'
scan="$(sed -n '/^_scan_lan_for_port() {/,/^}/p' "$ENG")"
chk "the scan passes base and port as arguments" 'grep -qF "/dev/tcp/\$1/\$2" <<<"$scan" && ! grep -qF "/dev/tcp/\${base}" <<<"$scan"'

# ---------------------------------------------------------------- 33 (D4)
hdr "33 — D4: config keys are names, not patterns"
out="$(run set 'B.*' x)"; rc=$?
chk "set 'B.*' x refused"                      '[[ $rc -ne 0 ]]'
chk "  and BOTTLES_RUNNER survives"            'grep -q "^BOTTLES_RUNNER=\"soda-test\"" "$CONF"'
out="$(run set WINE_ARCH $'win32\nBOTTLES_RUNNER="evil"')"; rc=$?
chk "a value with a newline is refused"        '[[ $rc -ne 0 ]] && ! grep -q evil "$CONF"'
out="$(run get PATH)"
chk "get PATH does not print the script's PATH" '[[ "$out" != *"/usr/bin"* ]]'
out="$(run get DEFAULT_REALM_PORT)"
chk "  a real setting still answers (control)" '[[ "$out" == "3724" ]]'

# ---------------------------------------------------------------- 35 (D6)
hdr "35 — D6: CLIENT_SOURCE_DIR is absolute"
out="$(cd "$T" && run set CLIENT_SOURCE_DIR client)"; rc=$?
chk "a relative path is stored absolute"       '[[ $rc -eq 0 ]] && grep -q "^CLIENT_SOURCE_DIR=\"${T}/client\"" "$CONF"'
sed -i 's|^CLIENT_SOURCE_DIR=.*|CLIENT_SOURCE_DIR="client"|' "$CONF"
out="$(cd "$T" && run configure)"; rc=$?
chk "a relative one already stored is refused" '[[ $rc -ne 0 ]] && grep -q "must be an absolute path" <<<"$out"'
# shellcheck disable=SC2088  # the literal tilde is what is being stored
out="$(run set CLIENT_SOURCE_DIR '~/client')"
chk "'~' is kept as typed"                     'grep -q "^CLIENT_SOURCE_DIR=\"~/client\"" "$CONF"'
run set CLIENT_SOURCE_DIR "$SRC" >/dev/null

# ---------------------------------------------------------------- 37
hdr "37 — a failed add-instance can be retried"
out="$(STUB_BOTTLE_FAIL=1 run add-instance --name box1)"; rc=$?
chk "the failure is reported"                  '[[ $rc -ne 0 ]]'
chk "  and its folder is gone"                 '[[ ! -e "$INST/box1" ]]'
out="$(run add-instance --name box1)"; rc=$?
chk "the retry succeeds"                       '[[ $rc -eq 0 && -f "$INST/box1/client/WoW.exe" ]]'
out="$(run add-instance --name box1)"; rc=$?
chk "  and a real duplicate is still refused, and kept" '[[ $rc -ne 0 ]] && grep -q "already exists" <<<"$out" && [[ -d "$INST/box1" ]]'

# ---------------------------------------------------------------- 34 (D5)
hdr "34 — D5: a failed launch exits non-zero"
out="$(STUB_WINE_FAIL=1 run launch box1)"; rc=$?
chk "launch exits 1"                           '[[ $rc -ne 0 ]] && grep -q "did not seem to start" <<<"$out"'
chk "  and leaves no lock behind"              '[[ ! -e "$INST/box1/launch.lock" ]]'

# ---------------------------------------------------------------- 31 (D2)
hdr "31 — D2: no X display"
out="$(STUB_X=nodisplay run launch box1)"; rc=$?
chk "launch still starts the game"             '[[ $rc -eq 0 ]] && [[ "$(games box1)" -ge 1 ]]'
chk "  says why the title is not held"         'grep -q "cannot reach an X display" <<<"$out"'
chk "  and leaves no launch lock"              '[[ ! -e "$XDG_CONFIG_HOME/dark-portal/launch.lock" && ! -e "$INST/box1/launch.lock" ]]'
run stop box1 >/dev/null
out="$(STUB_X=display STUB_X_STATE="$T/xstate" run launch box1)"; rc=$?
chk "with a display, the window is claimed (control)" '[[ $rc -eq 0 ]] && grep -q "Window found" <<<"$out"'
run stop box1 >/dev/null

# ---------------------------------------------------------------- 32 (D3)
hdr "32 — D3: stop and remove-instance without a pidfile"
run launch box1 >/dev/null
rm -f "$INST/box1/instance.pid"
chk "setup: the game runs with no pidfile"     '[[ "$(games box1)" -ge 1 ]]'
out="$(run stop box1)"; rc=$?
chk "stop still stops it"                      '[[ $rc -eq 0 && "$(games box1)" -eq 0 ]]'
out="$(run stop box1)"; rc=$?
chk "  and a second stop says not running"     '[[ $rc -eq 0 ]] && grep -q "not running" <<<"$out"'
run launch box1 >/dev/null
rm -f "$INST/box1/instance.pid"
out="$(run remove-instance --name box1)"; rc=$?
chk "remove-instance stops the game first"     '[[ $rc -eq 0 && "$(games box1)" -eq 0 && ! -e "$INST/box1" ]]'

# ---------------------------------------------------------------- 36
hdr "36 — two launches of one instance at once"
run add-instance --name box2 >/dev/null
run launch box2 > "$T/l1" 2>&1 & p1=$!
run launch box2 > "$T/l2" 2>&1 & p2=$!
wait "$p1" "$p2"
sleep 1
chk "only one game started"                    '[[ "$(games box2)" -eq 1 ]]'
chk "  the other launch said why"              'cat "$T/l1" "$T/l2" | grep -qE "being launched by another process|already appears to be running"'
run stop box2 >/dev/null

# ---------------------------------------------------------------- 38
hdr "38 — exe_re is local"
body="$(sed -n '/^_title_find_window() {/,/^}/p' "$ENG")"
chk "declared local in _title_find_window"     'grep -qE "^ +local .*\bexe_re\b" <<<"$body"'

# ---------------------------------------------------------------- 107
hdr "107 — two add-instance runs for one name"
# Both must pass the "already exists" check before either claims the folder:
# a mkdir on PATH pauses one second for this instance's folder only. A then
# makes the bottle; B, 0.3s behind, is told its bottle creation fails.
REAL_MKDIR="$(command -v mkdir)"
mkdir -p "$T/slow"
cat > "$T/slow/mkdir" <<SLOW
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == "$INST/race" ]] && sleep 1; done
exec "$REAL_MKDIR" "\$@"
SLOW
chmod +x "$T/slow/mkdir"
BOTTLE_RACE="$HOME/.var/app/com.usebottles.bottles/data/bottles/bottles/dp-race"
( PATH="$T/slow:$PATH" run add-instance --name race > "$T/race-a.out" ) &
sleep 0.3
outb="$(PATH="$T/slow:$PATH" STUB_BOTTLE_FAIL=1 run add-instance --name race)"; rcb=$?
wait
chk "the second run is refused: already exists" '[[ $rcb -ne 0 ]] && grep -q "already exists" <<<"$outb"'
chk "  and the first run's instance survives"   '[[ -d "$INST/race/client" ]]'
chk "  with its bottle"                         '[[ -d "$BOTTLE_RACE" ]]'

hdr "107 — a stored realm address the checks now refuse"
cp "$CONF" "$T/conf.bak"
sed -i 's/^DEFAULT_REALM_ADDRESS=.*/DEFAULT_REALM_ADDRESS="wow_server.lan"/' "$CONF"
out="$(run add-instance --name oldaddr)"; rc=$?
chk "add-instance still provisions the instance" '[[ $rc -eq 0 && -d "$INST/oldaddr/client" ]]'
chk "  warning that realmlist.wtf was not written" 'grep -q "realmlist.wtf not written" <<<"$out"'
chk "  and writes none"                         '[[ ! -e "$INST/oldaddr/client/realmlist.wtf" ]]'
cp "$T/conf.bak" "$CONF"

hdr "107 — breaking a stale launch lock"
# The engine's lock functions, run here. Between this launch's look at the
# stale lock and its mv, another launch breaks the same lock and takes a fresh
# one: the mv below does that first, once, then the real move.
fns="$(sed -n '/^_lock_is_stale() {/,/^}/p; /^_instance_lock_acquire() {/,/^}/p; /^_instance_lock_release() {/,/^}/p' "$ENG")"
cat > "$T/lockrace.sh" <<'RACE'
set -u
eval "$FNS"
_instance_dir() { printf '%s' "$LDIR"; }
lock="$LDIR/launch.lock"
mkdir -p "$lock"; echo 2147483646 > "$lock/owner"        # a dead owner: stale
raced=0
mv() {
    if (( ! raced )) && [[ "$1" == "$lock" ]]; then
        raced=1
        command mv "$lock" "$lock.other" && rm -rf "$lock.other"  # the other launch breaks it
        command mkdir "$lock" && echo "$OTHER" > "$lock/owner"   # and takes a fresh one
    fi
    command mv "$@"
}
if _instance_lock_acquire x; then echo "took it"; else echo "stood down"; fi
echo "owner now: $(cat "$lock/owner" 2>/dev/null)"
RACE
out="$(FNS="$fns" LDIR="$T/lockrace" OTHER="$$" bash "$T/lockrace.sh" 2>&1)"
chk "the launch that came second stands down"  'grep -q "stood down" <<<"$out"'
chk "  and the other launch keeps its fresh lock" 'grep -q "owner now: $$" <<<"$out"'
rm -rf "$T/lockrace"; mkdir -p "$T/lockrace"; echo 2147483646 > "$T/lockrace/x"
plain="$(sed 's/^mv() {/nomv() {/' "$T/lockrace.sh")"
out="$(FNS="$fns" LDIR="$T/lockrace" OTHER="$$" bash -c "$plain" 2>&1)"
chk "a lock that is only stale is still broken (control)" 'grep -q "took it" <<<"$out"'

echo
echo "pass=${pass} fail=${fail}"
(( fail == 0 ))
