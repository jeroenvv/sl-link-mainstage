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
   produced. 69 assertions, cross-checked against the archived Swift encoder (see the script's own
   header for the recipe).

Repo convention: a new assertion isn't trusted until it's mutation-tested — shown to actually fail on
the bug it's meant to catch — before relying on it.

```bash
./Scripts/run-lua-tests.sh
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
