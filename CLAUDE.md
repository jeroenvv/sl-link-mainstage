# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A MainStage Lua device script that connects Apple MainStage to a Studiologic SL88 MK2 keyboard over
the **SL Link** SysEx protocol - entirely from Lua, no helper app. The product is
`MainStageScript/STUDIOLOGIC/SL.device/config.lua` (~2,200 lines); `Scripts/run-lua-tests.sh` is its
offline regression gate (see "Lua tests" below). A handful of standalone Swift probes remain under
`Scripts/` (`sniff.swift`, `probe-sllink.swift`, `probe-display.swift`, `list-midi.swift`,
`sniff-all-sl-ports.swift`) for hardware debugging only - they are not part of the shipped product and
have no build step; run them with `swift <file>.swift`.

A macOS SwiftUI app preceded this script and implemented the same protocol. It has been removed from
this branch; it lives on `archive/swift-app` (and in git history) as a historical cross-check, not as
live code.

Verifying behaviour requires physical hardware: the SL88 MK2 must be attached over USB and exposing
MIDI endpoints whose short `kMIDIPropertyName` is `LINK` (display name `SL LINK`) - `config.lua`'s own
SIX RULES banner (rule 1) explains why the short name, not the display name, is what `outport` must
use; getting this wrong discards every outbound message with no error.

This is an implement-to-spec project, not a reverse-engineering one. Studiologic publishes the full
protocol at <https://github.com/fatarsrl/sl-link> (pinned at commit `4c0824d`, 2026-05-06), with
byte-level message tables under `docs/` and three reference JUCE implementations under `examples/`.
Start there, not from the code, when extending the protocol - the spec has a few internal
inconsistencies. `docs/implementing-sl-link.md` catalogues where real hardware disagrees with it, and
`config.lua`'s own comments note deviations inline where they mattered.

## Working efficiently in this repo

Lessons paid for in a long MainStage-bridge session. They are about *how* to work here, not about the
protocol.

**Edit files with the Edit/Write tools, not `python`/`sed` heredocs.** Editing a tracked file from the
shell makes the harness re-dump the whole file back into context — `config.lua` is ~2,200 lines, and
doing this repeatedly was the single largest waste of a long session. `Edit` also fails loudly on a
stale match, where a shell replacement silently no-ops or duplicates a section.

**Cap noisy output.** `LUA_DEBUG` captures and hardware probe runs can print hundreds of lines; pipe
them through `| tail -20`. Same for long `grep`/`cat`. Batch independent greps into one call, and read
targeted line ranges of long files rather than the whole file.

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

## Lua tests

`config.lua`'s only test suite, and the primary gate for changes to it:

```bash
./Scripts/run-lua-tests.sh
```

Two gates: `luac -p` on `config.lua` (fails fast on anything MainStage's own Lua host couldn't even
load), then `Tests/lua/harness.lua`, which drives `config.lua`'s callbacks directly and asserts on the
bytes/state they produce - covering flush budget and pacing, queue convergence, MIDI passthrough, the
CC batch cap, `clamp_scroll`, repaint rate, timer re-arm intervals, and golden byte vectors. The
vectors are derived from the tables in the spec's `docs/*.md`, not from the worked example at
`docs/basics.md:29` (`F0 00 20 1A 16 15 E3 04 01 00 F7`), which is malformed - `E3` has its MSB set
(illegal for a MIDI data byte) and Clear Screen needs three colour bytes, not one; that exact message
is instead used as a negative test proving the decoder rejects it. The vectors are cross-checked
against the Swift encoder preserved on `archive/swift-app`. Requires `lua` (`brew install lua`).

`Tests/` lives outside `MainStageScript/` for tidiness, not because anything requires it - there is no
build step here that would pick it up either way.

Every assertion is mutation-tested: the convention is to prove a new assertion FAILS on the bug it
exists to catch before it's trusted.

## Architecture

`config.lua` is one flat file, laid out top-to-bottom in the order MainStage needs it and marked with
`-- MARK:` section headers:

| Section | Responsibility |
|:---|:---|
| Protocol constants | Header bytes, item types, function codes, button/encoder/LED ids - kept in sync with the upstream spec and the archived Swift protocol layer. |
| CC dispatch | `CC_MAP`/`BUTTON_CC`/`ENCODER_CC`: every SL88 control (34 gestures) mapped to a MIDI CC on a dedicated channel, so MainStage can MIDI-Learn each one directly. |
| Session state | Module-level state: connection state machine, `instanceID`/retry bookkeeping, `timerPending`/`timerArmedInterval`, `displayFlushReady`, encoder/display caches. |
| Outbound plumbing | `queue_message`/`flush_pending`: the single byte-budgeted, one-message-per-flush send path every outbound message goes through. |
| CC queue/emit | Coalesces and drains queued CC messages within the same flush budget as display traffic. |
| Message builders | Pure `msg_*` functions building one SL Link message's bytes each, given the (id1, id2) pair. |
| Per-region memoization | `draw_text`/`draw_rect`/`draw_bitmap`: remember the last tuple sent per caller-supplied id; skip re-sending unchanged content. |
| Screen | Layout constants and the paint functions for each screen (zoom, list, popup). |
| Encoder value popup | Transient panel shown on any mapped encoder move: control name, wire CC number, and a filling ring gauge via the SL88's native Knob bitmap. |
| Session | Identification, login/logout, standby/restart, keepalive - the protocol state machine. |
| Inbound decoding | `controller_midi_in`'s SL frame recognition (`is_our_sl_frame`) and dispatch (`handle_sl_frame`). |
| MainStage callbacks | The entry points MainStage itself calls: `controller_initialize`, `controller_midi_in`, `controller_timer_trigger`, `controller_finalize`, patch-change hooks. |
| Device declaration | `controller_info()`: the MIDI items MainStage matches against, port names, and `patchselector`. |

Load-bearing invariants a reader must not break - each is one line here on purpose; `config.lua`'s own
SIX RULES banner at the top of the file states them precisely, and `docs/config-lua-history.md` has
the hardware evidence and rejected approaches behind each:

- **One message per flush, `<= FLUSH_BUDGET` bytes.** Over MainStage's ceiling the whole returned
  array is silently dropped, not just the overflow.
- **`displayFlushReady` paces display messages to one per timer tick.** An ungated flush drains at the
  inbound round-trip rate instead, and the SL88 silently drops a display message that arrives while
  still painting the previous one.
- **`timerPending` gates every `settriggertimer` call.** `settriggertimer` is a one-shot; an
  unconditional re-arm from a handler that runs on every inbound MIDI event pushes the deadline back
  forever and the timer never fires - no tick means no keepalive, and the SL88 silently drops the app.
- **Per-region memoization requires non-overlapping regions.** A region id must own screen pixels no
  other id draws, or a redraw of one id can leave a stale layer from another id on screen - see the
  "Per-region memoization" section's own comment for the escape hatch when overlap can't be avoided.

## SL Link protocol (as implemented)

All messages: `F0 00 20 1A 16 <id1> <id2> <itemType> [function] [payload...] F7`
(`00 20 1A` = Fatar/Studiologic manufacturer ID, `16` = SL Link protocol ID).

**The protocol itself is documented in [`docs/implementing-sl-link.md`](docs/implementing-sl-link.md)**
— encoding rules, session lifecycle, display, hardware I/O, and the places real hardware disagrees
with the published spec. Read that rather than re-deriving from the spec.

Project-specific notes that live only here:

- **Implemented:** Identification, System (device notification, login confirmation/recall, logout,
  standby, restart), Display (rect/text/bitmap), Buttons, Encoders. **Out of scope:** device icon
  upload, Master Volume, Hardware/Pedal Settings queries, White/RGB LED control.
- **Plot Bitmap draws from the SL88's internal bitmap library** (Groups/Icons, no pixel upload
  needed) — see `docs/implementing-sl-link.md` §5 for the group table; verified on hardware, Knob
  group renders as a filling 13-step ring gauge, used by the encoder value popup.
- **`SL_HOST_ID = 0x03`**, with the `instanceID` byte generated and bumped in-script on collision
  (`handle_identification_rejected`) rather than persisted across runs - `config.lua` has no
  `UserDefaults` equivalent (MainStage's Lua sandbox has no `io`/`os`, so nothing survives a script
  reload except what MainStage re-derives). There is no dev-console toggle for this or for anything
  else in the script; behaviour differences that used to be switchable at runtime in the Swift app now
  require editing the constant and redeploying (`Scripts/install-mainstage-script.sh` +
  `Scripts/restart-mainstage.sh`).
- The **hardware-confirmed deviations** — swapped firmware/model payloads, A encoder/button reaching
  the host, LONG_PRESSION delivered, trailing-byte optionality — are catalogued in
  `docs/implementing-sl-link.md` §7. Do not reintroduce logic that special-cases or drops A traffic,
  or that drops LONG_PRESSION, based on the spec's claims without re-confirming against hardware.

Session lifecycle: identify -> approved -> 3s keepalive (5s hard timeout on the keyboard, manufactured
in `config.lua` by sending an Identification Query on every flush since `settriggertimer` cannot
re-arm itself) -> user selects the app -> login confirmation -> active -> standby/restart bracket the
user leaving and returning to SL-Link mode (full repaint required on restart) -> logout is a
request/confirm pair, either side can initiate.

## Hardware verification status

Verified against a physically attached SL88 MK2 (firmware 1.1.2, model byte `0x01`), running the
device script under MainStage. Recorded because none of it is reproducible without the hardware, and
"passes the Lua harness" says nothing about whether the keyboard and MainStage agree.

Confirmed working: identification and approval; keepalive holding the app in the APP list; login
confirmation; the concert/set/patch screen painting correctly (coordinates, alignment, colours,
Max Width truncation and centring at both text sizes); all mapped encoders and buttons emitting CCs
MainStage can learn, including A and the joystick encoder with speed-sensitive multi-step ticks;
SHORT and LONG button presses; logout in both directions; force logout followed by re-identify;
standby -> restart with a full repaint; and Plot Bitmap, including the Knob group's 13-step fill gauge
used by the encoder value popup.

Not yet exercised, so treat as unproven: USB unplug/replug mid-session; the Identification Rejected
retry path beyond ordinary re-init collisions, which needs a deliberate DeviceID collision; and Login
Recall (`00 06`), which only fires once the keyboard has an icon stored for the (HostID, DeviceID)
pair and is therefore unreachable while icon upload stays out of scope.

Two app instances running concurrently (the `instanceID` bump-on-collision strategy) remains untested
too, but only because it didn't occur: a 2026-08-28 hardware run logged a single `instanceID`
(`03 6D`), zero identification rejections, 3,593 timer-tick lines with 3,593 distinct tick numbers,
and the documented 2 init / 2 finalize churn - despite the SL88 exposing three port pairs (`SL CTRL`/
`SL DAW`/`SL LINK`). One observation on one machine/version; the rejection-recovery defences stay. See
`docs/config-lua-history.md#single-instance-confirmed-on-hardware-2026-08-28`.

Timing measured on hardware: display messages drain at one per timer tick, sped up to `FLUSH_SOON_MS`
(35ms, settled after a sweep) while output is still queued; a full zoom-screen repaint costs a handful
of display messages (`zcnc`/`zset`/`zname`/`znext`/`zpos`). That budget is why per-region memoization
exists - an encoder tick should cost one message, not a repaint.
