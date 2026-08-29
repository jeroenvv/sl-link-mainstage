# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

macOS SwiftUI app that connects Apple MainStage to a Studiologic SL88 MK2 keyboard over the
**SL Link** SysEx protocol. Single app target, no external dependencies, no Xcode test target -
two standalone suites cover it instead: golden-vector codec tests via `swiftc` and an offline Lua
regression suite for `config.lua` (see "Codec tests" and "Lua tests" below).

This is an implement-to-spec project, not a reverse-engineering one. Studiologic publishes the full
protocol at <https://github.com/fatarsrl/sl-link> (pinned at commit `4c0824d`, 2026-05-06), with
byte-level message tables under `docs/` and three reference JUCE implementations under `examples/`.
Start there, not from the code, when extending the protocol - the spec has a few internal
inconsistencies (noted inline in `SLLinkEncoder.swift`/`SLLinkDecoder.swift` where they mattered).

## Build & run

The active developer directory on this machine is the Command Line Tools, so `xcodebuild` must be
pointed at Xcode explicitly:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project SL-Link-Mainstage.xcodeproj -scheme SL-Link-Mainstage -configuration Debug build

# run the built app
open ~/Library/Developer/Xcode/DerivedData/SL-Link-Mainstage-*/Build/Products/Debug/SL-Link-Mainstage.app
```

Verifying behaviour requires physical hardware: the SL88 MK2 must be attached over USB and exposing
MIDI endpoints whose display name contains "LINK" (the macOS port is named `SL LINK`). Without it,
`Connect + Identify` logs `SL LINK MIDI port not found.`

Key build settings: `MACOSX_DEPLOYMENT_TARGET = 26.5`, `SWIFT_VERSION = 5.0`,
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `ENABLE_APP_SANDBOX = YES`. Info.plist is
Xcode-generated (no checked-in `Info.plist`), but entitlements **are** checked in at
`SL-Link-Mainstage/SL-Link-Mainstage.entitlements` and wired up via `CODE_SIGN_ENTITLEMENTS` — they
carry a scoped `temporary-exception.files.absolute-path.read-only` for the MainStage bridge files.
Note that entitlement's paths must be the resolved `/private/tmp/...` form, not the `/tmp` symlink.

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes *every* unannotated declaration in the project
implicitly main-actor-isolated, including plain enums/structs, not just classes. All of the
`SLLink/` layer is written to run off the main actor (see Threading below) and marks itself
`nonisolated` accordingly - if you add a new type under `SLLink/` and it needs to be called from a
background queue, it needs the same annotation, or you'll get "main actor-isolated ... cannot be
used in nonisolated context" warnings (errors under the Swift 6 language mode).

## Working efficiently in this repo

Lessons paid for in a long MainStage-bridge session. They are about *how* to work here, not about the
protocol.

**Edit files with the Edit/Write tools, not `python`/`sed` heredocs.** Editing a tracked file from the
shell makes the harness re-dump the whole file back into context — `config.lua` is ~2,200 lines, and
doing this repeatedly was the single largest waste of a long session. `Edit` also fails loudly on a
stale match, where a shell replacement silently no-ops or duplicates a section.

**Cap noisy output.** `xcodebuild` prints hundreds of lines of compiler invocations; pipe it through
`| tail -5`. Same for long `grep`/`cat`. Batch independent greps into one call, and read targeted line
ranges of long files rather than the whole file.

**Dump what an unknown API gives you before testing hypotheses about it.** The `outport` blocker cost
about ten hardware round-trips; MainStage had been passing the answer all along as
`controller_midi_in`'s `portName` argument. One log line, ordered first, would have ended it.

**Prove you can observe the signal before trusting a negative.** A dozen rounds concluded "outbound
MIDI never works" using a sniffer that watched CoreMIDI *sources* while `outport` addresses a
*destination*. Prefer a request/response probe over a fire-and-forget send. See the
`test-mainstage-script` skill.

**Prefer one decisive experiment to a sweep.** Sweeping six `outport` values with no working
observation path produced six meaningless results.

**Dispatch exploration to a subagent.** Open-ended searching — "where is X handled", "how do the 98
bundled MainStage scripts use Y", auditing several files — should go to an `Explore`/Haiku/Sonnet
agent, which returns a summary. Searching inline dumps every raw result into the session context
permanently; in one long session `Read` results alone reached ~130% of the context window, mostly
re-reads. Not worth the spawn for a single targeted grep or a known `file:line`. Verify what an agent
reports rather than relaying it unchecked.

**Keep commit messages short.** Subject line plus a few lines at most. Extended reasoning, evidence
tables and rejected hypotheses belong in `docs/`, which the commit can reference.

**Use the skills.** `.claude/skills/test-mainstage-script` (hardware deploy/verify loop) and
`.claude/skills/lua-harness` (offline verification before spending a hardware round-trip).

**Read `docs/config-lua-history.md` before changing `config.lua`'s display pacing, session clock,
or flush logic.** It holds the hardware findings and rejected approaches behind the constraints
`config.lua`'s own comments only state tersely and cite by anchor.

## Codec tests

`SLLinkProtocol.swift`, `SLLinkEncoder.swift` and `SLLinkDecoder.swift` are pure (`import Foundation`
only - no CoreMIDI, no SwiftUI) so they can be compiled and tested standalone, without an Xcode test
target:

```bash
./Scripts/run-codec-tests.sh
```

This compiles those three files plus `Tests/SLLinkCodecTests.swift` (deliberately kept outside
`SL-Link-Mainstage/` so it's never compiled into the app - the app target is a
`PBXFileSystemSynchronizedRootGroup`, so anything under `SL-Link-Mainstage/` is picked up
automatically) with `swiftc`, and runs the resulting binary. It's a plain executable with top-level
assertions, not XCTest - see the script/test file for why (top-level code requires a file literally
named `main.swift`, so the script copies the test file into a scratch one before compiling).

Every golden vector is derived from the tables in the spec's `docs/*.md`, not from the worked example
at `docs/basics.md:29` (`F0 00 20 1A 16 15 E3 04 01 00 F7`), which is malformed - `E3` has its MSB
set (illegal for a MIDI data byte) and Clear Screen needs three colour bytes, not one. That exact
message is instead used as a negative test proving the decoder rejects it.

## Lua tests

`config.lua` has its own offline regression suite, the primary gate for changes to it:

```bash
./Scripts/run-lua-tests.sh
```

Two gates: `luac -p` on `config.lua` (fails fast on anything MainStage's own Lua host couldn't even
load), then `Tests/lua/harness.lua` under `lua`, which drives `config.lua`'s callbacks directly and
asserts on the bytes/state they produce - 52 assertions covering flush budget and pacing, queue
convergence, MIDI passthrough, the CC batch cap, `clamp_scroll`, repaint rate, timer re-arm
intervals, and golden byte vectors cross-checked against `SLLinkEncoder.swift`. Requires `lua`
(`brew install lua`).

`Tests/` lives outside `SL-Link-Mainstage/` for the same reason as the codec tests above - the app
target is a `PBXFileSystemSynchronizedRootGroup`, so it's never compiled into the app.

Every assertion is mutation-tested: the convention is to prove a new assertion FAILS on the bug it
exists to catch before it's trusted.

## Architecture

Layered under `SL-Link-Mainstage/SLLink/`, from pure to CoreMIDI/UI-facing:

| File | Responsibility |
|:---|:---|
| `SLLinkProtocol.swift` | Constants/enums only: header bytes, `ItemType`, per-category `Function`, button/encoder/LED IDs, `SLModel`, text align/size, colors. No behavior. |
| `SLLinkEncoder.swift` | Pure `[UInt8]`-returning builders, one per outbound message, all taking the (id1, id2) pair. Houses `msbLsb(_:)` and `rgb7(_:)`. |
| `SLLinkDecoder.swift` | Pure `[UInt8] -> SLLinkMessage?`. Validates header, 7-bit-ness, and per-function length before decoding. |
| `SLLinkTransport.swift` | CoreMIDI only: client/ports, endpoint discovery + hot-plug, the real-time-safe inbound path (lock-free ring buffer -> `DispatchSourceTimer` drain -> `F0...F7` reassembly), and the paced outbound queue (~1 msg/ms) with correctly-sized `MIDIPacketList` buffers. Knows nothing about message meaning. |
| `SLLinkSession.swift` | State machine: `.idle -> .identifying -> .listed -> .active <-> .standby`. Keepalive timer, DeviceID persistence/regeneration, login/logout/standby/restart handling. Runs on its own serial `queue` (distinct from the transport's), so it can call `transport.connect()` (which locks the transport's queue) without risking a same-queue deadlock. |
| `SLLinkDisplay.swift` | Drawing API over the encoder, routed through `SLLinkSession.send(_:)`. Memoizes the last rect/text sent per caller-supplied id so a redraw only re-sends what changed - `invalidateAll()` resets this after `clear()` and after a Restart. |
| `SLLinkDemoScreen.swift` | The on-keyboard demo UI (title + 4 zone panels, encoder-driven values, single-zone-selection navigable via select buttons or the Joystick) that exercises the whole stack. No MainStage integration. |
| `SLLinkController.swift` | `ObservableObject` façade for SwiftUI. Owns the whole stack; replaces the old `MIDIManager.swift`. |

**Endpoint matching** — case-insensitive *contains* "LINK" on `kMIDIPropertyDisplayName` (the macOS
port is `SL LINK`, not `LINK`). Requires both a source and a destination to match before connecting.

**Threading** — the only code on CoreMIDI's real-time thread is the `MIDIReadProc` trampoline in
`SLLinkTransport.swift`, and it does nothing but copy bytes into a lock-free ring buffer (no
allocation, no ARC, no logging, no dispatch). A `DispatchSourceTimer` on `SLLinkTransport.serialQueue`
drains it, reassembles `F0...F7` frames, and hands them to `SLLinkSession`, which decodes and runs
its state machine on its *own* serial `queue`. `SLLinkController` hops explicitly to main before
touching any `@Published` property. None of `SLLinkTransport`/`SLLinkSession`/`SLLinkDisplay`/
`SLLinkDemoScreen` are `@MainActor` - keep that discipline (and the `nonisolated` annotations that
make it so under the project's default-MainActor build setting) in any new code reachable from a
callback.

**Lifetime** — `SLLinkController` (and the transport/session it owns) is created once by
`SL_Link_MainstageApp` and torn down explicitly via `shutdown()` from `AppDelegate
.applicationWillTerminate`, not left to `deinit` ordering - the CoreMIDI callbacks resolve `self` via
`Unmanaged.passUnretained`, which is only safe because the object outlives the app.

**API vintage** — deliberately uses the CoreMIDI 1.0 byte-oriented API (`MIDIClientCreate`,
`MIDIInputPortCreate`, `MIDIPacketList`, `MIDIReadProc`) rather than `MIDIEventList`/UMP, because the
protocol is entirely SysEx. Stay on the 1.0 API so packet handling stays uniform.

**Logging is the debugging surface** — `SLLinkController.log` is a `@Published [String]` capped at
500 lines and rendered in the dev console (`ContentView.swift`). Every send/receive is logged in hex
via `SLLinkSessionEvent`.

**Demo screen interaction model** (`SLLinkDemoScreen`) — one zone at a time can be "selected"
(`selectedZone: Int?`, not the old per-zone `[Bool]` multi-select). A zone's own encoder always
adjusts that zone's value regardless of selection; the Joystick's Left/Right move the selection
between zones (wrapping) and its Up/Down/built-in encoder adjust the *selected* zone's value. A
zone's select button SHORT-toggles its selection and LONG resets its value to 0; a zone's encoder
push button has the same two actions with SHORT/LONG swapped (SHORT resets, LONG toggles selection).
The A/B encoders both nudge all four values together (see deviation 5 below on why A isn't
special-cased) and their push buttons, plus the Joystick's main button, reset everything. Home forces
a full repaint. No button event is dropped based on SHORT vs. LONG - every case either gives LONG a
distinct effect or runs the same action for both, since LONG_PRESSION is confirmed delivered on real
hardware (deviation 5). Panels draw their selection outline as four non-overlapping edge-strip rects
(not a filled "border" rect underneath the fill) specifically so a selection toggle - which only
needs to resend the outline - can't paint over the fill/label/value layered on top of it; see
`SLLinkDisplay`'s type-level doc comment for the general "per-id memoization requires non-overlapping
regions" rule this follows, and `SLLinkDisplay.invalidate(ids:)` for the escape hatch when overlap
can't be avoided.

## SL Link protocol (as implemented)

All messages: `F0 00 20 1A 16 <id1> <id2> <itemType> [function] [payload...] F7`
(`00 20 1A` = Fatar/Studiologic manufacturer ID, `16` = SL Link protocol ID).

**The protocol itself is documented in [`docs/implementing-sl-link.md`](docs/implementing-sl-link.md)**
— encoding rules, session lifecycle, display, hardware I/O, and the four places real hardware
disagrees with the published spec. Read that rather than re-deriving from the spec.

Project-specific notes that live only here:

- **Implemented:** Identification, System (device notification, login confirmation/recall, logout,
  standby, restart), Display (clear/rect/text/bitmap), Buttons, Encoders, White/RGB LEDs.
  **Out of scope:** device icon upload, Master Volume, Hardware/Pedal Settings queries — their
  constants are kept in `SLLinkProtocol.swift` as spec references, but nothing encodes or decodes them.
- **Plot Bitmap draws from the SL88's internal bitmap library** (Groups/Icons, no pixel upload
  needed) — see `docs/implementing-sl-link.md` §5 for the group table; verified on hardware, Knob
  group renders as a filling 13-step ring gauge. The device-logo form of it (`GIDX 0x7F`) is the
  part that still needs icon upload, so it stays out of scope; the library itself is a separate,
  unused opportunity — the encoder popup doesn't use it yet.
- **Two discrepancies are switchable from the dev console** without a rebuild, because they were
  inferred from the reference JUCE implementations rather than confirmed on hardware:
  `SLLinkHeader.defaultHostID = 0x03` with the DeviceID pair persisted in `UserDefaults` (the spec
  instead describes one 14-bit random ID), and `SLLinkSession.useNameInKeepalive` (the reference
  implementations append the app name to every keepalive; the spec puts it only in the Identification
  Request). Flip the latter if the app never appears in the SL88's APP list.
- The **hardware-confirmed deviations** — swapped firmware/model payloads, A encoder/button reaching
  the host, LONG_PRESSION delivered, trailing-byte optionality — are catalogued in
  `docs/implementing-sl-link.md` §7. Do not reintroduce logic that special-cases or drops A traffic,
  or that drops LONG_PRESSION, based on the spec's claims without re-confirming against hardware.

Session lifecycle: identify -> approved -> 3s keepalive (5s hard timeout on the keyboard) -> user
selects the app -> login confirmation/recall -> active -> standby/restart bracket the user leaving and
returning to SL-Link mode (full repaint required on restart) -> logout is a request/confirm pair,
either side can initiate.

## Hardware verification status

Verified against a physically attached SL88 MK2 (firmware 1.1.2, model byte `0x01`). Recorded because
none of it is reproducible without the hardware, and "builds and passes codec tests" says nothing
about whether the keyboard agrees.

Confirmed working: identification and approval; 3s keepalive holding the app in the APP list; login
confirmation; the demo screen painting correctly (coordinates, alignment, colours, bitmap); all seven
encoders including A and the joystick encoder, with speed-sensitive multi-step ticks (±8 observed in
ordinary use, not just ±1); buttons `0x00`-`0x07` and `0x0B`, SHORT and LONG; white LEDs tracking the
RGB rings; logout in both directions; force logout followed by re-identify; standby -> restart
with a full repaint; and Plot Bitmap, including the Knob group's 13-step fill gauge and device-side
gradient colouring.

Not yet exercised, so treat as unproven: USB unplug/replug mid-session; the Identification Rejected
retry path, which needs a deliberate DeviceID collision; and Login Recall (`00 06`), which only fires
once the keyboard has an icon stored for the (HostID, DeviceID) pair and is therefore unreachable
while icon upload stays out of scope.

Two app instances running concurrently (the DeviceID instance-byte strategy) remains untested too,
but only because it didn't occur: a 2026-08-28 hardware run logged a single `instanceID` (`03 6D`),
zero identification rejections, 3,593 timer-tick lines with 3,593 distinct tick numbers, and the
documented 2 init / 2 finalize churn - despite the SL88 exposing three port pairs (`SL CTRL`/`SL
DAW`/`SL LINK`). One observation on one machine/version; the rejection-recovery defences stay. See
`docs/config-lua-history.md#single-instance-confirmed-on-hardware-2026-08-28`.

Timing measured on hardware: outbound paced at ~1 msg/ms sustained 1366 messages with no loss or
corruption; a full-screen repaint of the demo UI costs ~37 messages, roughly 55 ms of MIDI time. That
budget is why `SLLinkDisplay` memoizes per region - an encoder tick should cost one message, not a
repaint.
