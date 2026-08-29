# Scripts

## `install-mainstage-script.sh`

The primary user-facing command. Copies `MainStageScript/STUDIOLOGIC/SL.device/` into MainStage's
device script folder:

```
~/Music/Audio Music Apps/MainStage Devices/STUDIOLOGIC/SL.device/
```

**Not** Logic Pro's identically-shaped "MIDI Device Scripts" folder — that's a different app.
Idempotent: safe to re-run any time (after editing `config.lua`, or after a MainStage update resets
the folder).

```bash
./Scripts/install-mainstage-script.sh
```

## `run-lua-tests.sh`

Offline regression suite for `config.lua`. Two gates:

1. `luac -p` — syntax check, fails fast on anything MainStage's Lua host wouldn't load.
2. `Tests/lua/harness.lua` — drives `config.lua`'s callbacks directly and asserts on the bytes/state
   produced. 69 assertions, derived from the spec's message tables (`docs/implementing-sl-link.md`,
   the upstream spec) and originally cross-checked by hand against this project's own Swift encoder,
   now preserved on the `archive/swift-app` branch (see the script's own header for that recipe).

Repo convention: a new assertion isn't trusted until it's mutation-tested — shown to actually fail on
the bug it's meant to catch — before relying on it.

```bash
./Scripts/run-lua-tests.sh
```

`lua`/`luac` are resolved from `PATH` by default; override with `LUA`/`LUAC` env vars for
distros that install them under versioned names (e.g. Debian/Ubuntu's `lua5.4`/`luac5.4`).

## `bump-version.sh`

Bumps `VERSION` and `config.lua`'s `SCRIPT_VERSION` together, then re-runs `run-lua-tests.sh` so
its drift assertion proves the two still agree. Versioning rule: the version moves only when the
shipped Lua device script changes — minor for features, patch for fixes, major only for a change
that breaks an existing MIDI-Learn mapping or the install layout.

```bash
./Scripts/bump-version.sh <major|minor|patch> [--dry-run]
```

`--dry-run` prints old -> new and changes nothing — used by CI to compute the next version before
deciding whether to commit a bump.

## `build-release.sh`

Builds `dist/sl-link-mainstage-<version>.zip`: verifies `config.lua`'s `SCRIPT_VERSION` matches
`VERSION`, runs `luac -p` and the full `run-lua-tests.sh` suite (never packages an untested
script), then stages and zips exactly `README.md`, `VERSION`,
`Scripts/install-mainstage-script.sh` and `MainStageScript/STUDIOLOGIC/SL.device/config.lua`. The
layout mirrors the repo so the same install command works from a checkout or an unzip.

```bash
./Scripts/build-release.sh [--output-dir <dir>]   # default: dist/, already .gitignore'd
```

## `restart-mainstage.sh`

Quits MainStage (answering the "save the concert?" prompt with **Don't Save**), waits for it to
actually exit, then relaunches it. Needed because testing a device script means relaunching MainStage
after every edit, and an unanswered save dialog silently blocks the quit.

```bash
./Scripts/restart-mainstage.sh              # quit + relaunch
./Scripts/restart-mainstage.sh --debug      # relaunch with LUA_DEBUG -> /tmp/lua.log
./Scripts/restart-mainstage.sh --quit-only  # quit and stay quit
```

## Hardware probes

Standalone CoreMIDI diagnostics, compiled ad hoc with `swiftc` — not part of any app, no shared
dependencies between them.

| Script | What it does |
|:---|:---|
| `list-midi.swift` | Dumps every CoreMIDI endpoint with name, display name, manufacturer, model and parent device. Confirms the `SL LINK` port is present before suspecting the protocol. |
| `probe-sllink.swift` | Minimal handshake: sends an Identification Request, keepalives every 3 s, decodes and logs replies, then logs out cleanly. |
| `probe-display.swift` | Full session plus a painted UI on the LCD, reacting live to buttons and encoders. Includes SysEx reassembly. |
| `sniff.swift` | Passive — connects to the `SL LINK` source and logs every inbound frame in hex, plus any non-SysEx channel-voice traffic. Sends nothing, so it can watch traffic alongside another session. |
| `sniff-all-sl-ports.swift` | Passive multi-port sniffer — connects to every CoreMIDI source whose name starts with `SL ` and logs raw bytes per port. Compiled by the `test-mainstage-script` skill on every hardware run. |

Run one directly:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift Scripts/<script>.swift [seconds]
```

Or compile once and reuse the binary (what the `test-mainstage-script` skill does):

```bash
swiftc -o /tmp/sniffer Scripts/sniff-all-sl-ports.swift
```
