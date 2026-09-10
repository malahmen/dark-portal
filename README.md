# dark-portal

> The gateway your clients step through onto a realm.

A **gum-free, flag-driven** engine that provisions and launches one or more
**vanilla WoW (1.12.1 / client build 5875)** game clients under Wine, for
**multiboxing** on a single Linux PC. Companion to the
[nordrassil](https://github.com/malahmen/nordrassil) server engine — this never
touches the server, only the player-facing client(s) that connect to one.

It has **no interactive prompts**: every command is driven by flags and a flat
`key=value` config file, so it's equally usable from a shell, a Makefile, CI, or
cron. [scomp-link](https://github.com/malahmen/scomp-link) ships a thin `gum` TUI
(**wow-dark-portal**) that collects values and drives this by flags — that
front-end owns all the interactivity, dark-portal owns the logic.

## What it does

Each **instance** is an independent client "box": its own Wine prefix (a
[Bottles](https://usebottles.com/) bottle) so registry/DirectX state never
collides, and its own `WTF`/`Cache`/`Logs` so account state, saved variables and
addon cache never collide.

- **Wine via Bottles (Flatpak)**, not a host-layered `wine` package. On
  immutable/atomic hosts (e.g. Bazzite) a layered `wine-core` needs a reboot and
  its `wineboot --init` has been seen to hang; Bottles bundles a known-good
  runner, needs no reboot, and works the same on any distro with Flatpak+Flathub.
- **Two isolation modes** (a per-deployment choice): `full` copies the whole
  client per instance (best at high instance counts — no shared-inode read
  contention); `shared` symlinks the large/static dirs and keeps private
  `WTF`/`Cache`/… (minimal disk, fine at low counts). A `shared` instance's
  `WTF/` starts **empty** — the source client's accounts, saved variables and
  keybinds are deliberately not copied; it begins at game defaults plus the
  window/realm cvars `launch` renders.
- **Plain windowed launch** — runs `WoW.exe` directly (no Wine virtual-desktop
  wrapper, which some WMs force-fullscreen), sized via `Config.wtf`'s
  `gxWindow`/`gxResolution`, re-rendered every launch.
- **Stable per-instance window title** — a small background "title keeper" finds
  the window each launch created (a before/after window-ID diff, since Bottles'
  runner reports a bogus PID and a shared `WM_CLASS`) and re-asserts its title to
  the instance name, so a key broadcaster can target boxes reliably. Needs
  `xdotool` and an X11/XWayland session.
- **`realmlist.wtf` is re-derived every launch** from the effective realm
  setting (and stray `SET realmList`/`realmName` cvars in `Config.wtf` are
  stripped), so an `edit-instance`/`set` change is never silently stale.
- **LAN realm discovery** — a best-effort TCP port probe of the local /24 for an
  open realm port (default 3724, `--port P` to change). A port probe, not a full
  protocol handshake — the result is a prefill you can override; `--set`
  persists it as the default only when exactly one host answers.
- **Per-instance `wine.log`** — every launch appends the Wine/game output to
  `instances/<name>/wine.log`; when a launch "did not seem to start", look there.

> **Platform:** Linux + Flatpak/Bottles + X11/XWayland. macOS can drive the
> config subcommands, but provisioning and launching clients needs Linux.

### Runtime requirements

| Tool | Needed for | Notes |
| --- | --- | --- |
| `bash` ≥ 4, `flatpak` | everything | `install-deps` installs Bottles from Flathub |
| GNU `grep`, GNU `sed` | config/realmlist rewriting, subnet detection | uses `grep -P` and `sed -i` — BSD variants won't do |
| `timeout` (coreutils), `ip` (iproute2) | `discover-realm` | `ip route` finds the local /24 |
| `xdotool` | stable window titles (`launch`) | optional — without it windows keep the game's own title |
| `nmap` | faster `discover-realm` | optional — falls back to a slower pure-bash sweep |

## Install / usage

`dark-portal.sh` is a self-contained Bash script — no `gum`, no shared lib.
Clone and run:

```sh
./dark-portal.sh --help
```

### Commands

```
Setup
  install-deps
  configure                              validate settings + grant Bottles fs access
  discover-realm [--port P] [--set]      scan the LAN, print candidate realm IPs
  winecfg --name N                       open winecfg for one instance's bottle
  list-runners                           available Bottles Wine runners

Instances
  add-instance --name N [--resolution WxH] [--realm ADDR] [--port P]
  edit-instance --name N [--resolution WxH] [--realm ADDR] [--port P]
  remove-instance --name N
  list-instances [--names]               summary, or bare names with --names

Launch
  launch --name N | launch N
  stop --name N | stop N
  stop-all
  status

Config store
  set KEY VALUE                          store one global key
  get KEY                                effective value (config or default)
  config                                 dump the raw global config file
```

`launch` and `stop` accept the instance name either as `--name N` or as a bare
positional argument. `discover-realm [--port P] [--set]` prints candidate IPs
to stdout (progress to stderr), so a front-end can present them; `--set`
persists the address only when the scan finds exactly one host. `get` returns
the *effective* value (stored or default), `config` dumps the raw file.

### Examples

```sh
# point at a pristine client, choose a runner, then validate + grant access
./dark-portal.sh install-deps
./dark-portal.sh list-runners
./dark-portal.sh set CLIENT_SOURCE_DIR ~/games/vanilla-wow
./dark-portal.sh set BOTTLES_RUNNER soda-9.0-1
./dark-portal.sh set DEFAULT_REALM_ADDRESS 192.168.1.50
./dark-portal.sh configure

# provision and launch two boxes
./dark-portal.sh add-instance --name box1 --resolution 1280x720
./dark-portal.sh add-instance --name box2 --realm 192.168.1.51
./dark-portal.sh launch --name box1
./dark-portal.sh stop-all
```

## Configuration

Global state lives in `$XDG_CONFIG_HOME/dark-portal/dark-portal.conf`
(`~/.config/dark-portal/` when `XDG_CONFIG_HOME` is unset); per-instance
overrides in `.../dark-portal/instances/<name>/instance.conf`, alongside that
instance's `client/` and `wine.log`. Read/write the global store with
`get`/`set`/`config`.

The Bottles sandbox is granted read-write access to that directory by
`install-deps`, and read-only access to `CLIENT_SOURCE_DIR` by `configure` —
each bound to the path **as it resolved when that command ran**. If you later
change `XDG_CONFIG_HOME` (or `CLIENT_SOURCE_DIR`), re-run `install-deps` (or
`configure`) so the sandbox can reach the new location.

| Key | Default | Notes |
| --- | --- | --- |
| `CLIENT_SOURCE_DIR` | (empty) | a pristine vanilla client install (contains `WoW.exe`) |
| `CLIENT_ISOLATION_MODE` | `full` | `full` (copy per instance) or `shared` (symlinked) |
| `WINE_ARCH` | `win32` | `win32` matches this 32-bit-era client |
| `BOTTLES_RUNNER` | (empty) | a Bottles Wine runner name (see `list-runners`) |
| `DEFAULT_RESOLUTION` | `1024x768` | window size (`gxWindow`/`gxResolution`) |
| `DEFAULT_REALM_ADDRESS` | (empty) | realm address clients connect to |
| `DEFAULT_REALM_PORT` | `3724` | realm port |

Per-instance overrides (`RESOLUTION`, `REALM_ADDRESS`, `REALM_PORT`) are set via
`add-instance`/`edit-instance` flags and win over the defaults. There is no flag
to clear one once set — edit or delete the line in that instance's
`instance.conf` to fall back to the global default.

## Credits

The client is Blizzard's; the emulation ecosystem it connects to is
[VMaNGOS](https://github.com/vmangos/core) and the vanilla WoW community's work.
dark-portal is the multiboxing provisioning/launch automation *around* a client —
it configures, isolates, and launches; the game is theirs.

## License

[The Unlicense](LICENSE) — public domain.
