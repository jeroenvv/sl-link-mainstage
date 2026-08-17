# Scripts

## `run-codec-tests.sh`

Compiles the pure codec files (`SLLinkProtocol/Encoder/Decoder.swift`) plus `Tests/SLLinkCodecTests.swift`
with `swiftc` and runs them. No Xcode test target involved — see CLAUDE.md's "Codec tests" section.

```bash
./Scripts/run-codec-tests.sh
```

## Hardware probes

Standalone `swift` scripts that talk to the SL88 MK2 directly, without launching the app. During
development these isolated protocol questions considerably faster than debugging through the UI —
each one is a single file with no dependencies, so it can be edited and re-run in seconds.

Run them with the SL88 attached over USB:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift Scripts/<script>.swift [seconds]
```

| Script | What it does |
|:---|:---|
| `list-midi.swift` | Dumps every CoreMIDI endpoint with name, display name, manufacturer, model and parent device. Use it to confirm the `SL LINK` port is present before suspecting the protocol. |
| `probe-sllink.swift` | Minimal handshake: sends an Identification Request, keepalives every 3 s, decodes and logs replies, then logs out cleanly. Answers "does the keyboard talk to us at all". |
| `probe-display.swift` | Full session plus a painted UI on the LCD, reacting live to buttons and encoders. Includes SysEx reassembly. Use it to check display encodings without touching the app. |
| `sniff.swift` | **Passive** — connects to the source and logs every inbound frame in hex with a decode, plus any non-SysEx channel-voice traffic. Sends nothing and identifies as nothing, so it can watch traffic while the app holds its own session. This is the one to reach for when you need ground truth about what the hardware actually emits. |

`sniff.swift` is how the three documented spec deviations in CLAUDE.md were established. When the
documentation and the hardware disagree, capture the bytes before believing either.
