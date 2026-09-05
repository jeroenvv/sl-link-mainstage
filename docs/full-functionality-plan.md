# SL88 ↔ MainStage — plan for full functionality

**Historical.** This is a draft written 2026-08-19; its Phases 1-3 have since shipped. See
`docs/mainstage-integration.md` for current status rather than treating this plan as live.

**Status: draft for revision.** Nothing here is implemented yet. Written 2026-08-19, on top of the
working Lua-only SL Link session (see `docs/mainstage-integration.md` and
`MainStageScript/STUDIOLOGIC/SL.device/config.lua`).

## Target behaviour (as specified)

| Control | Behaviour |
|:---|:---|
| Screen — default mode | Patch list of the current set, with the active patch highlighted |
| Screen — zoomed mode | Current patch only, in a large font for readability at a distance |
| Zoom button | Toggles between the two display modes |
| Joystick Up / Down | Move highlight one patch up / down |
| Joystick Left / Right | Previous / next set |
| Joystick main button — short | Select the highlighted patch |
| Joystick main button — long | Jump to the first patch of the set |
| A encoder | SL88 audio-board volume (SL Link Master Volume) |
| B encoder | MainStage main volume |
| B encoder turn | Shows a temporary pop-up with the level, which then disappears |
| Encoders 1–4 | Control the first four channel strips of the current patch |
| Encoders 1–4 turn | Shows the same temporary pop-up with the channel name and new value |
| Encoder 1–4 ring | Lit when that channel is active (single RGB lamp: colour + brightness only, no level arc) |
| Encoder 1–4 press — short | Mute / unmute that channel |
| Encoder 1–4 press — long | Reset that channel to **0 dB** (unity) |
| B encoder press — short | Mute / unmute the main fader |
| B encoder press — long | Reset the main fader to **0 dB** (unity) |
| Ring when muted | Off |
| Zone 1–4 Select buttons | Solo channel 1–4 (button LED shows solo state) |

## Button assignments

### DECIDED: the four Zone Select buttons are SOLO

The four **Zone Select** buttons (`SLButtonID.zone1SelectButton`..`zone4SelectButton`, `0x04`-`0x07`)
solo channels 1-4. They sit directly under encoders 1-4, keeping the whole column "about that
channel": mute on the encoder press, solo on the button below it. Each has a white LED
(`SLWhiteLED.zone1Button`..`zone4Button`, `0x00`-`0x03`) to show solo state.

Depends on Q3 — if solo turns out to be unreachable, see the fallback below.

Still unassigned: Global (`0x09`), DAW (`0x0A`), Apply (`0x0E`), Cancel (`0x0F`), Home (`0x10`), and
the A encoder push button (`0x0B`). Suggested, not yet decided:

| Button | Action | Why |
|:---|:---|:---|
| Cancel (`0x0F`) — LONG | **MIDI panic** (All Notes Off + All Sound Off + Reset Controllers on all 16 channels) | Panic belongs on a "stop/abort" button. LONG-press guards against triggering it mid-song by accident, and LONG is confirmed delivered on this hardware (CLAUDE.md deviation 5) |
| Apply (`0x0E`) | Force full screen repaint | Cheap safety valve if the display ever desyncs. Moved here from Home (`0x10`), which is the Zoom button — see Q7. Could equally be a LONG press of Zoom itself |
| Global (`0x09`) | Toggle screen view: patch list ↔ channel mixer | A second page solves the "where do channel names/levels go" layout problem from Phase 4. Note this is a *different* toggle from Zoom (Q7), which switches list ↔ single-patch |

### Fallback if solo turns out to be unreachable (Q3)

Only if solo cannot be driven — make the four buttons global utilities instead:

| Button | Action |
|:---|:---|
| Zone 1 Select | **MIDI panic** (LONG-press to confirm) |
| Zone 2 Select | Tap tempo |
| Zone 3 Select | Metronome / click on-off |
| Zone 4 Select | Toggle patch list ↔ channel mixer view |

### Other candidates worth considering

- **Mute all / "silence"** — one button that mutes every channel, for fast stage silence.
- **Tuner toggle** — common live need, if MainStage exposes it to a mapped control.
- **Bookmark / jump to a favourite patch** — SHORT jumps, LONG sets the bookmark.
- **Previous patch (toggle back)** — flip between the last two patches, useful mid-song.

**On MIDI panic specifically:** it is worth defining exactly what it sends -
CC 123 (All Notes Off), CC 120 (All Sound Off) and CC 121 (Reset All Controllers) on all 16 channels is
the thorough version. That is 48 messages, which must respect the byte budget and one-message-per-flush
rule, so it will drain over a second or so rather than firing instantly - acceptable for a panic, but
worth knowing. Whether it is sent to MainStage (inbound substitution, Q1a) or straight out to the
keyboard depends on what is actually stuck.

## What already works (do not re-derive)

- Lua-only SL Link session: identify → stay listed → draw. No helper app.
- `outport = 'LINK'` (short `kMIDIPropertyName`, never `'SL LINK'`).
- Inbound SL Link SysEx arrives at `controller_midi_in`.
- Session clock: `settriggertimer` is a one-shot that only re-arms from `controller_midi_in`, so every
  flush carries an Identification Query whose reply drives the next tick.
- Drawing rules: one message per flush, ≤72 bytes, **never** Clear Screen, never truncate strings.

## Proven building blocks to port from the Swift implementation

The Swift stack already solved several of these problems against this exact hardware. Port the
behaviour rather than re-deriving it.

### Encoder decoding — this is the bit that "worked well"

Message is 11 bytes: `F0 00 20 1A 16 ID#1 ID#2 03 EID TK F7`.

```
delta = TK - 0x40          -- SLLinkDecoder.decodeEncoder: `let delta = tick - 64`
```

The spec backs this exactly: *"the tick value is 64-centered, meaning that the negative values are all
the ones inferior to `0x40`, while the positive ones are above this value"*, and encoders *"do not send
absolute values but rather relative ones"*.

**Why it feels good, and the thing to preserve:** the tick magnitude is **speed-sensitive** — the spec
notes a fast turn yields ±2, ±3, and ±8 has been observed on this hardware. The Swift code simply adds
`delta` straight to the value (`zoneValues[0] += delta`). That is the whole trick: **no acceleration
curve, no smoothing, no accumulator** — the hardware's own speed sensitivity provides fine control when
turned slowly and coarse jumps when turned fast, for free. Do not "improve" this with a custom
acceleration ramp.

For the channel encoders this maps directly: add `delta` to the current 0–127 value and clamp. For a
pop-up, coalesce *repaints* (see Phase 3) but never coalesce the deltas themselves — sum them all, or
fast sweeps will lose travel.

Validate before use: length exactly 11, and a known `EID`. Reject otherwise, as `SLLinkDecoder` does.

### Buttons

Also 11 bytes: `F0 00 20 1A 16 ID#1 ID#2 01 BID EVT F7`, `EVT` = `0x01` SHORT / `0x02` LONG. Per spec, a
press held over one second sends LONG immediately; a shorter press sends SHORT **on release**.

**Never drop LONG** (CLAUDE.md deviation 5 — it is confirmed delivered here, contradicting the spec's
silence), and never silently discard A-encoder traffic: the spec says the host never sees `EID 0x05` /
`BID 0x0B` because they are reserved for USB audio, but on this firmware they arrive as ordinary
messages. `SLLinkDemoScreen` deliberately treats A exactly like B for this reason.

### Display memoization

`SLLinkDisplay`'s per-id memoization, its non-overlap requirement, and `invalidate(ids:)` for
unavoidable overlap — see Phase 3's pop-up notes and Q5.

## Open questions — resolve these BEFORE building

These are the load-bearing unknowns. Each one can invalidate a whole phase, so each gets a cheap
spike first, in this order.

### Q1. How does the script tell MainStage to change patch? — RESEARCHED 2026-08-19

`controller_info()` sets `patchselector = true`, so MainStage's core listens for Bank Select
MSB = SetIndex, LSB = PatchIndex on channel 16, then a Program Change. But **`outport` sends to the
keyboard, not to MainStage**, so that is not the route.

Checked both references. They show **two different mechanisms**, and neither is `outport`:

**(a) Inbound substitution — confirmed to exist.** Apple's own
`M-Audio/Oxygen 49 #1.device/config.lua` returns MIDI from `controller_midi_in` with **no `outport`**:

```lua
function controller_midi_in(midiEvent, portName)
    if midiEvent[0] == 0xB0 and (midiEvent[1] == 0x00 or midiEvent[1] == 0x20) then
        return {}                                    -- swallow
    end
    if midiEvent[0] == 0xc0 then
        return {midi={0xB0,0x50+midiEvent[1],0x7F}}  -- REPLACE inbound PC with a CC
    end
    return nil                                       -- pass through
end
```

So the return value of `controller_midi_in` rewrites what MainStage *receives*. `outport` is what makes
a return go outward to a device instead. This is the mechanism to use: on an SL88 navigation event,
return the patchselector triple with no `outport`.

**(b) Declared items + MainStage's own mapping — what Novation actually does.** (Written up in full in
`docs/mainstage-device-scripts.md` §10.) The Launchkey MK3
script never injects anything: **every** one of its `{midi=...}` returns carries `outport = DAW_IN`,
i.e. it only ever talks to the device. Its buttons are exposed as `items` (with `inport`/`outport`), and
MainStage's assignment layer binds them to actions. It does not set `patchselector` at all.

**Plan:** try (a) first, since it needs no per-concert setup. Fall back to (b), which is the
better-trodden path and dovetails with Q2 — the SL88's buttons also emit ordinary MIDI, which can be
declared as `items` and mapped, by hand in MainStage if necessary.

**Spike:** on a joystick press, return `{midi={0xBF,0x00,set, 0xBF,0x20,patch, 0xCF,0x00}}` with no
`outport`, and see whether MainStage switches patch.

### Q2. Do SL88 button/encoder SysEx messages reach the script? — ANSWERED 2026-08-20: YES

Confirmed on hardware. Buttons (`ItemType 0x01`) and Encoders (`0x03`) both arrive at
`controller_midi_in`. BIDs seen: `0x00`-`0x07`, `0x10`, `0x11`-`0x15`, in both SHORT and LONG.
Encoder speed sensitivity confirmed live (`delta=8` observed). **Q7 is answered at the same time: the
physical Zoom button is BID `0x10`**, which the spec calls Home — the working assumption was right.

The fallback route in Q2's second half is **not available**: the SL88's buttons emit **no ordinary
channel-voice MIDI**. That negative rests on a *proven* observation path — the modulation wheel
produced 311 CC messages through the same logging that stayed silent across every button press in two
separate runs. So inbound substitution (Q1a), not declared `items`, is the route for Phase 2.

The original question and its reasoning follow.

### Q2 (original). Do SL88 button/encoder SysEx messages reach the script?

Everything so far only proves *query replies* arrive. The SL88 sends Button (`ItemType 0x01`) and
Encoder (`0x03`) SL Link messages while a host is logged in, but that has never been observed from Lua.

**Spike:** log every inbound SysEx with `ItemType` in `{0x01, 0x03}` while pressing buttons and turning
encoders. Confirm IDs against `SLLinkProtocol.swift` (`SLButtonID`, `SLEncoderID`, `SLButtonEvent`).
Note that encoder ticks are speed-sensitive (±8 observed), so treat the delta as signed magnitude.

**Also log channel-voice traffic in the same spike.** The SL88's buttons are expected to emit ordinary
MIDI (CC/note) alongside — or instead of — the SL Link SysEx. If they do, that is a second, simpler
route: declare them as `items` and let MainStage map them, by hand in MainStage's own assignment UI if
automatic mapping is not possible. This is exactly what the Launchkey reference does (Q1b), so it is
the lower-risk path even though it needs setup per concert.

### Q3. How do we read and write channel-strip state? (blocks Phases 4–6)

Needed: per-channel name, level, mute state, "is active", and a colour for the ring.

`controller_midi_out(midiEvent, name, valueString, color)` delivers exactly that — parameter name,
formatted value and colour — but only for controls **mapped in Layout mode** to Smart Controls. This
has never been exercised in this project.

**Spike:** declare four `Knob` items, map one to a channel-strip volume in Layout mode, and log whether
`controller_midi_out` fires with usable `name` / `valueString` / `color`.

**Risk:** if mapping must be done by hand per concert, this stops being plug-and-play. Investigate
whether MainStage auto-maps by control name.

### Q4. Two separate volumes — RESOLVED 2026-08-19

There are two distinct volumes and they get **different encoders**:

| Encoder | Target | Mechanism |
|:---|:---|:---|
| **A** | the SL88's own USB audio-board volume | SL Link **Master Volume** message, `ItemType 0x07` |
| **B** | MainStage main volume | still open — mapped item or a CC MainStage listens to |

Master Volume (`hardware-io.md`) is `F0 00 20 1A 16 ID#1 ID#2 07 R/W VOL MUTE F7`, where `R/W = 1` to
write, `VOL` is **0–100 as a percentage** (values >100 ignored), and `MUTE` non-zero mutes. A read
(`R/W = 0`, `VOL` omitted) makes the SL88 answer with the current volume and mute state — use that on
startup to sync. `MUTE` may be omitted for backwards compatibility.

Note the spec claims the A encoder is *reserved* for exactly this and never reaches the host, but
CLAUDE.md deviation 5 records that A encoder messages **do** arrive as ordinary SL Link messages on
this firmware. So driving audio-board volume from A is both spec-aligned and achievable.

Still to decide: what MainStage's main volume actually is (concert master vs. output channel strip)
and how to reach it.

### Q5. Is the byte budget enough for a patch list? (blocks Phase 1)

A list of ~8 visible rows is ~8 Write Texts. At one message per flush and `FLUSH_SOON_MS = 100` that is
~0.8 s for a full list repaint — too slow if it repaints on every encoder tick.

**Mitigation to design in from the start:** redraw only what changed (the two rows whose highlight
moved), never the whole list. This is the same per-region memoization `SLLinkDisplay.swift` already
does on the Swift side — reuse that thinking. Consider raising `FLUSH_SOON_MS` responsiveness only if
measurements demand it.

### Q6. What raw value is 0 dB? (blocks the long-press resets)

Long-pressing a channel encoder resets that channel to **0 dB**, and long-pressing B resets the main
fader the same way. To be unambiguous: **0 dB means the fader's default position (unity gain), not
silence.** The reset must land where a freshly created fader sits, not at the bottom of its travel.

Where that sits in the value range depends entirely on how Q3 turns out. If channels are driven by a
mapped item sending 0–127, unity is *not* 127: MainStage's volume faders run past unity (up to about
+6 dB), so unity lands somewhere below the top of the range and has to be determined rather than
assumed. Read it off `controller_midi_out`'s `valueString`, which reports the formatted value (e.g.
`0.0 dB`) — sweep the encoder, find the raw value where the string reads 0 dB, and use that constant.

If instead a direct parameter-set route exists, prefer setting the parameter to unity by value and skip
the mapping entirely.

**Spike (fold into the Q3 spike):** log `valueString` against the raw value while sweeping one mapped
volume control, and record the unity point.

### Q7. Which BID is the Zoom button? (blocks the display-mode toggle)

The spec has **no button called Zoom** — `hardware-io.md`'s BID table names `0x0E` Apply, `0x0F` Cancel,
`0x10` Home, and `SLButtonID` mirrors it. Jeroen identifies Zoom physically as **the button below
Cancel**, which by that ordering is the one the spec calls **Home (`0x10`)**; the panel silkscreen and
the spec's naming evidently differ.

Treat `0x10` as the working assumption, but **confirm it rather than assume**: two BIDs are also
unaccounted for in the table — `0x08` (almost certainly the reserved APP button, appearing in the
white-LED table only as a question-marked `0x04 ?`) and `0x0D` (unexplained) — so an undocumented
button is not impossible.

**Fold into the Q2 spike:** log *every* BID seen, including `0x08` and `0x0D`, and press the physical
Zoom button. Whatever BID arrives is the answer.

**Knock-on:** `0x10` was pencilled in as "force full repaint" in the button suggestions. If Zoom is
`0x10`, that moves — repaint is a good fit for a LONG press of the same button, or for Apply (`0x0E`).

## Phases

Each phase must end in a state that is verified on hardware and committed, per the project's
one-commit-per-phase convention.

### Phase 0 — Spikes (Q1, Q2, Q3)

Throwaway probes, not shipped code. Outcome is a written answer in this document for each question.
**Do not start Phase 1 until Q1 and Q2 are answered**, since a "no" on either reshapes everything.

### Phase 1 — Patch list on screen (read-only), plus display modes

Two modes, toggled by the Zoom button — physically the button below Cancel, i.e. BID `0x10`, which the
spec calls Home (confirm in the spike, see Q7):

- **Default — list.** Patch list of the current set, active patch highlighted.
- **Zoomed — single patch.** Only the current patch name, large font, for reading at a distance.
  `SIZE_BIG` is 33 px (`display-messages.md`); on a 320×240 screen that allows a genuinely large,
  centred readout, optionally with the set name small above it.

Switching modes must erase what the other mode drew. Clear Screen is banned (see the drawing rules),
so **use Draw Rectangle** (`ItemType 0x04`, function `0x02`:
`... 04 02 XMSB XLSB YMSB YLSB WMSB WLSB HMSB HLSB R G B F7`) to paint over the regions being vacated.
That is the erase primitive this project has not needed until now, and it is also what the pop-up's
restore should use.

**Caution:** Clear Screen turned out to be slow enough to race with following draws. A rectangle fill is
smaller and should be safer, but that is an assumption — verify a large rect fill does not race the
same way before relying on it, and keep erase rects as small as the layout allows.

- Keep the whole patch list from `controller_select_patch` (it already provides `patchlist` with
  `.IsPatch`, `.PatchIndex`, `.SetIndex`, `.Label`).
- Model: current set index, highlight index, scroll offset.
- Per-row memoization: keep the last string+colour drawn per row id and skip unchanged rows.
- **Acceptance:** the list matches MainStage, and changing patch in MainStage moves the highlight,
  redrawing at most two rows.

**Resolved layout** (implemented in `config.lua`, superseding the original "N = 6 rows, ~22 px apart"
sketch):

- **Header, both modes' top region.** Two lines, `SIZE_SMALL`: the concert name dim grey
  (`120,120,120` on black) at `y = 2`, left-aligned; below it at `y = 25`, the set name in blue
  (`110,170,230` on black), left-aligned, sharing the row with an `n/N` position counter in the same
  blue, right-aligned against the right margin.
- **List mode rows.** `ROW_COUNT = 7` rows at `x = 8`, `maxWidth = 304`, starting at `ROW_Y0 = 52` and
  spaced `ROW_PITCH = 27` px apart. Each row is one of four colour states (fg/bg, `SIZE_SMALL`,
  left-aligned): `ROW_NORMAL` grey-on-black (`150,150,150`/`0,0,0`), `ROW_ACTIVE` amber-on-black
  (`255,170,40`/`0,0,0`) for the playing patch, `ROW_CURSOR` inverted black-on-white
  (`0,0,0`/`255,255,255`) for the browse cursor, and `ROW_CURSOR_ACTIVE` black-on-amber
  (`0,0,0`/`255,170,40`) when cursor and active patch coincide.
- **Zoom mode.** All four lines centred (`ALIGN_CENTER`) at `x = 8`, `maxWidth = 304`: concert (dim
  grey) at `y = 12`, set name (blue) at `y = 40`, patch name at `SIZE_BIG`/white at `y = 102`, and the
  `n/N` counter (dim grey) at `y = 172`.

### Phase 2 — Navigation and selection

> **SUPERSEDED (2026-08-22).** The browse-cursor + selection design below is not being built.
> MainStage's `patchselector` parser turns out to be unreachable from a device script's injected
> MIDI — see `docs/mainstage-integration.md`'s "Q1a closed" section. Phase 2 now exposes every SL88
> control as its own mappable CC instead, for MainStage's own MIDI Learn to bind — see that doc's
> "Every control emits a mappable CC" section. The design below is kept as historical record of what
> was originally planned, not as a live spec.

Depends on Q1 + Q2.

- Joystick Up / Down (`0x11` / `0x13`) → move highlight, clamped within the set.
- Joystick Left / Right (`0x12` / `0x14`) → previous / next set, highlight resets to its first patch.
- Joystick main (`0x15`): SHORT = select highlighted patch; LONG = jump to the set's first patch.
- Joystick encoder (`SLEncoderID.joystick`) rotation also moves the highlight.
- Selection emits the patchselector triple established in Q1.
- Handle both `SLButtonEvent.short` and `.long` — never drop LONG (see CLAUDE.md deviation 5).
- **Acceptance:** the SL88 alone can browse and select across sets; MainStage follows.

### Phase 3 — Shared value pop-up

Every encoder shows its value change the same way, so the pop-up is **one shared component**, not four
plus two. Built here, before its callers (Phases 4 and 6), and testable on its own with any dummy
label/value — it does not depend on Q3.

**Contract:** `show_popup(label, value)` — draw/refresh; `dismiss_popup()` — erase and restore.

Design points, all forced by constraints established earlier:

- **One pop-up at a time, last mover wins.** A single fixed screen region, so restoring it is a single
  known set of region ids. Two simultaneous pop-ups would mean tracking two overlap sets for no real
  benefit.
- **Draw the frame once, then only update the value.** A pop-up is a background rect + label + value.
  Re-sending all three on every encoder tick would swamp the byte budget. On first tick draw all
  three; on subsequent ticks re-send **only the value text** — one message, so one flush.
- **Coalesce fast ticks.** Encoder deltas are speed-sensitive (±8 observed in ordinary use), and ticks
  arrive far faster than a flush. Accumulate the delta and repaint the value at most once per flush,
  rather than queueing one repaint per tick — otherwise the queue grows unboundedly during a fast
  sweep. `drop_queued_display()` already gives the "supersede rather than pile up" behaviour needed.
- **Dismissal restores by redrawing, never by clearing.** Use the ported `invalidate(ids:)` pattern:
  force every region id the pop-up covered to be resent, then redraw them. Clear Screen stays banned.
- **Dismissal timing is quantised to the session clock.** ~1.5 s of no movement is the target; while a
  pop-up is visible the tick interval may need shortening so it disappears promptly rather than at the
  next 3 s keepalive.
- **Placement:** choose a region overlapping as few patch-list rows as possible, since those rows are
  what must be redrawn on dismissal.

**Acceptance:** turning any of A, B or encoders 1–4 shows the right label and value, a fast sweep stays
responsive without flooding, and the screen returns *exactly* to its previous state afterwards.

### Phase 4 — Encoders 1–4 → first four channel strips

Depends on Q3.

- Map encoders `0x00`–`0x03` to the first four channels of the current patch.
- Turning adjusts that channel's level; the value comes back via `controller_midi_out`.
- Show each channel's name and level on screen beneath the list (or on a second page — decide during
  Phase 1 layout). Transient feedback while turning is the shared pop-up from Phase 3; the persistent
  readout is separate from it.
- **Acceptance:** turning encoder 1 changes channel 1's level in MainStage, and the screen agrees.

### Phase 5 — Rings, mute and solo

**What the hardware can actually do** (`hardware-io.md`) — more limited than the word "ring" suggests:

- There are **4 RGB LEDs total**, one per zone encoder (`LID` 0–3):
  `F0 00 20 1A 16 ID#1 ID#2 05 LID R G B BR F7` — 7-bit colour per channel (same encoding as the
  display) plus a single **brightness** byte `BR`, 0–127, applying to the whole LED.
- **It is one lamp, not a segmented ring.** No arc, no per-segment control, no way to represent a level
  on it. A ring can express *state* (colour + brightness) but **never a value** — level feedback must
  come from the pop-up and the on-screen readout instead.
- The other 12 LEDs are **white, on/off only** (`ItemType 0x02`, `LST` 0/1), and that includes the A and
  B encoder LEDs (`0x0A`, `0x0B`). So **B cannot indicate the main volume level either**.

**Proposed state → appearance** (brightness values are a starting point; check on hardware):

| Channel state | Ring |
|:---|:---|
| Active | Channel colour from `controller_midi_out`'s `color`, normal brightness (~90) |
| Muted | Off (`BR = 0`) |
| Soloed | Distinct colour at full brightness (~127) — must not read as either of the above |
| No such channel (fewer than 4) | Off |

Solo also lights the Zone Select button's own white LED
(`SLWhiteLED.zone1Button`..`zone4Button`), which is the unambiguous solo indicator; the ring colour is
the supporting cue.

- Encoder press (`0x00`–`0x03`) SHORT toggles mute; muted → ring off.
- Encoder press LONG resets that channel to 0 dB (unity — see Q6), and shows the pop-up like any other
  value change. SHORT and LONG must both be handled; never drop LONG (CLAUDE.md deviation 5).
- Zone Select buttons (`0x04`–`0x07`) toggle solo on the same four channels.
- **Open:** what a channel that is *both* soloed and muted looks like, and whether "another channel is
  soloed, so this one is implicitly silent" deserves its own appearance (dimmed, say).
- **Acceptance:** mute and solo state on the SL88 and in MainStage always agree, including when changed
  in MainStage; a long press lands the channel exactly on 0 dB.

### Phase 6 — Volumes (A and B encoders)

Depends on Q4.

- **A encoder** (`SLEncoderID.aEncoder`) adjusts the SL88's own audio-board volume via the Master
  Volume message (`ItemType 0x07`, `R/W = 1`, `VOL` 0-100). Read the current value at startup
  (`R/W = 0`) to sync. Its push button (`0x0B`) is the natural audio-board mute toggle, via the same
  message's `MUTE` byte.
- **B encoder** (`SLEncoderID.bEncoder`) adjusts MainStage main volume.
- **B encoder push** (`SLButtonID.bEncoderButton`, `0x0C`): SHORT mutes/unmutes the main fader, LONG
  resets it to 0 dB (unity — see Q6), showing the pop-up. Exactly mirrors the channel encoders, so the
  gesture means the same thing everywhere.
- Both show the shared pop-up from Phase 3 — the erase/restore machinery lives there, not here.
- **Acceptance:** A changes the SL88's own output level and B changes MainStage's, each showing the
shared pop-up.

## Cross-cutting constraints to respect

- **Byte budget.** One message per flush, ≤72 bytes, always paired with the query.
- **No Clear Screen, ever.** Erase by redrawing regions.
- **Redraw only what changed.** The budget makes full repaints expensive; per-region memoization is
  mandatory, not an optimisation.
- **Two script instances (possible).** MainStage can load the script once per USB-MIDI interface —
  the one hardware run measured so far ran as a single instance instead (see
  `docs/config-lua-history.md#single-instance-confirmed-on-hardware-2026-08-28`). If it happens, both
  instances will try to drive the screen. Today they get distinct DeviceIDs; with interactive control
  this could mean two competing UIs, so decide whether the second instance should stay passive.
- **Never swallow musical MIDI.** `controller_midi_in` must keep returning `nil` for notes, pitch bend
  and sustain, or notes hang.

## Deliberately out of scope for now

Device icon upload, Hardware/Pedal Settings, bitmap/icon drawing, and anything requiring the helper
app — the Swift app remains unused by this path.
