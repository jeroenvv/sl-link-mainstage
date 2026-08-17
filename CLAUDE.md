# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

macOS SwiftUI app that connects Apple MainStage to a Studiologic SL88 MK2 keyboard over the
**SL Link** SysEx protocol. Single app target, no external dependencies, no Xcode test target
(golden-vector codec tests run standalone via `swiftc` - see "Codec tests" below).

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
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `ENABLE_APP_SANDBOX = YES` (entitlements and Info.plist
are Xcode-generated — there are no checked-in `.entitlements` or `Info.plist` files).

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes *every* unannotated declaration in the project
implicitly main-actor-isolated, including plain enums/structs, not just classes. All of the
`SLLink/` layer is written to run off the main actor (see Threading below) and marks itself
`nonisolated` accordingly - if you add a new type under `SLLink/` and it needs to be called from a
background queue, it needs the same annotation, or you'll get "main actor-isolated ... cannot be
used in nonisolated context" warnings (errors under the Swift 6 language mode).

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

Implemented: Identification (request/approved/rejected/query), System (device notification,
login confirmation/recall, logout request/confirmation, standby, restart), Display (clear/rect/
text/bitmap-from-library), Buttons, Encoders, White/RGB LEDs. **Out of scope** (see the project
plan's Scope boundary): device icon upload, Master Volume, Hardware/Pedal Settings queries - their
`ItemType`/`Function` constants are kept in `SLLinkProtocol.swift` as accurate spec references, but
nothing encodes or decodes them.

Two spec discrepancies from the reference JUCE implementations, both switchable from the dev console
without a rebuild:

1. **ID byte semantics** — the spec's prose describes one 14-bit random ID; both reference
   implementations instead use `(HOST_ID constant, random instance byte)`. `SLLinkSession` follows
   the reference implementations (`SLLinkHeader.defaultHostID = 0x03`) and persists the pair in
   `UserDefaults` (fixing the old code's "new random ID every connect" bug, which discarded Login
   Recall). Both bytes are editable from the dev console.
2. **Where the app name goes** — the spec puts it only in the Identification Request; both reference
   implementations also append it to every keepalive. `SLLinkSession.useNameInKeepalive` defaults to
   the spec-only path; flip it from the dev console (`SLLinkController.useNameInKeepalive`) if the
   app never appears in the SL88's APP list.

**Hardware-confirmed deviations** — the two above were inferred from the reference implementations;
these two were found by capturing live SysEx from a physically attached SL88 MK2 (firmware 1.1.2,
model byte `0x01` = SL88) and are not optional/switchable, because the spec's documented forms simply
never arrive:

3. **Identification Approved carries the firmware/model payload, not Login Confirmation.** The spec
   documents Identification Approved (`7F 01`) as a bare 10 bytes, and puts a 4-byte `MAJ MIN REV SL`
   payload on Login Confirmation/Recall (`00 01` / `00 06`) instead. Real hardware does the opposite:
   Approved arrives as 14 bytes with `MAJ MIN REV SL` appended (captured: `F0 00 20 1A 16 03 2A 7F 01
   01 01 02 01 F7`, decoding to firmware 1.1.2 / SL88), and Login Confirmation arrives as a bare 10
   bytes with no payload at all (captured: `F0 00 20 1A 16 03 2A 00 01 F7`). `SLLinkDecoder` accepts
   both the spec-derived and hardware-observed length for all three functions (`identificationApproved`,
   `loginConfirmed`, `loginRecall` all carry `firmware`/`model` as optionals); `SLLinkSession` latches
   the values from whichever message actually carries them and carries them forward through later
   state transitions that don't. Login Recall's payload has never been observed on hardware either;
   its optionality is inferred by symmetry with Login Confirmation, not separately captured.
4. **Trailing-byte optionality is the general pattern, not a one-off.** The spec itself documents some
   trailing bytes as optional elsewhere (Master Volume's `MUTE` byte, Hardware Settings' `HST` byte -
   both out of scope here, see above). Prefer accepting the known variant lengths explicitly over a
   strict `bytes.count == N` guard when extending the decoder, per point 3.
5. **The A Encoder and A Encoder Button are not actually reserved from the Host.** `hardware-io.md`
   states the Host never receives A Encoder (`EID 0x05`) / A Encoder Button (`BID 0x0B`) messages -
   supposedly reserved for the USB audio board's volume/mute - and says nothing about whether
   LONG_PRESSION is delivered. A live capture from a physically attached SL88 MK2 (firmware 1.1.2)
   contradicts both: A Encoder/A Encoder Button messages arrive as ordinary SL Link messages (no
   accompanying Master Volume or channel-voice CC/pitch-bend traffic), and LONG_PRESSION (`EVT 0x02`)
   is delivered for ordinary buttons (captured on the Zone 1 Encoder Button, `BID 0x00`).
   `SLLinkDemoScreen` treats A identically to B rather than special-casing or dropping it - see its
   type-level doc comment. Don't reintroduce logic that special-cases or silently discards A traffic,
   or that drops LONG_PRESSION, based on the spec's claims without re-confirming against hardware.

Session lifecycle (`SLLinkSession`): identify -> approved -> 3s keepalive (5s hard timeout on the
keyboard) -> user selects the app -> login confirmation/recall -> active -> standby/restart bracket
the user leaving/returning to SL-Link mode (screen must be fully repainted on restart, since the
keyboard retains no display state across standby) -> logout is a request/confirm pair, either side
can initiate.

## Hardware verification status

Verified against a physically attached SL88 MK2 (firmware 1.1.2, model byte `0x01`). Recorded because
none of it is reproducible without the hardware, and "builds and passes codec tests" says nothing
about whether the keyboard agrees.

Confirmed working: identification and approval; 3s keepalive holding the app in the APP list; login
confirmation; the demo screen painting correctly (coordinates, alignment, colours, bitmap); all seven
encoders including A and the joystick encoder, with speed-sensitive multi-step ticks (±8 observed in
ordinary use, not just ±1); buttons `0x00`-`0x07` and `0x0B`, SHORT and LONG; white LEDs tracking the
RGB rings; logout in both directions; force logout followed by re-identify; and standby -> restart
with a full repaint.

Not yet exercised, so treat as unproven: two app instances running concurrently (the DeviceID
instance-byte strategy); USB unplug/replug mid-session; the Identification Rejected retry path, which
needs a deliberate DeviceID collision; and Login Recall (`00 06`), which only fires once the keyboard
has an icon stored for the (HostID, DeviceID) pair and is therefore unreachable while icon upload
stays out of scope.

Timing measured on hardware: outbound paced at ~1 msg/ms sustained 1366 messages with no loss or
corruption; a full-screen repaint of the demo UI costs ~37 messages, roughly 55 ms of MIDI time. That
budget is why `SLLinkDisplay` memoizes per region - an encoder tick should cost one message, not a
repaint.
