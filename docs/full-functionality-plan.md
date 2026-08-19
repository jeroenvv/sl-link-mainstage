# SL88 ↔ MainStage — plan for full functionality

**Status: draft for revision.** Nothing here is implemented yet. Written 2026-08-19, on top of the
working Lua-only SL Link session (see `docs/mainstage-integration.md` and
`MainStageScript/STUDIOLOGIC/SL.device/config.lua`).

## Target behaviour (as specified)

| Control | Behaviour |
|:---|:---|
| Screen | Patch list of the current set, with the highlighted entry visible |
| Joystick Up / Down | Move highlight one patch up / down |
| Joystick Left / Right | Previous / next set |
| Joystick main button — short | Select the highlighted patch |
| Joystick main button — long | Jump to the first patch of the set |
| B encoder | MainStage main volume |
| B encoder turn | Shows a temporary pop-up with the level, which then disappears |
| Encoders 1–4 | Control the first four channel strips of the current patch |
| Encoder 1–4 ring | Lit when that channel is active |
| Encoder 1–4 press | Mute / unmute that channel |
| Ring when muted | Off |

## What already works (do not re-derive)

- Lua-only SL Link session: identify → stay listed → draw. No helper app.
- `outport = 'LINK'` (short `kMIDIPropertyName`, never `'SL LINK'`).
- Inbound SL Link SysEx arrives at `controller_midi_in`.
- Session clock: `settriggertimer` is a one-shot that only re-arms from `controller_midi_in`, so every
  flush carries an Identification Query whose reply drives the next tick.
- Drawing rules: one message per flush, ≤72 bytes, **never** Clear Screen, never truncate strings.

## Open questions — resolve these BEFORE building

These are the load-bearing unknowns. Each one can invalidate a whole phase, so each gets a cheap
spike first, in this order.

### Q1. How does the script tell MainStage to change patch? (blocks Phase 2)

`controller_info()` sets `patchselector = true`, so MainStage's own core listens for Bank Select
MSB = SetIndex, LSB = PatchIndex on channel 16, then a Program Change. But **the script's `outport`
sends to the keyboard, not to MainStage.**

Hypothesis: returning `{midi = ...}` from `controller_midi_in` **without** an `outport` substitutes the
event on the inbound path, i.e. MainStage sees it as if the device had sent it. Apple's own
`M-Audio/Oxygen 49 #1.device` does exactly this shape (`return {midi={0xB0,0x50+midiEvent[1],0x7F}}`).

**Spike:** on any SL88 button press, return `{midi={0xBF,0x00,set, 0xBF,0x20,patch, 0xCF,0x00}}` with no
`outport`, and see whether MainStage switches patch. If it does not, fall back options are (a) drive
selection from mapped `items` in Layout mode, or (b) abandon device-driven selection and make the
screen a read-only display.

### Q2. Do SL88 button/encoder SysEx messages reach the script? (blocks Phases 2–4)

Everything so far only proves *query replies* arrive. The SL88 sends Button (`ItemType 0x01`) and
Encoder (`0x03`) SL Link messages while a host is logged in, but that has never been observed from Lua.

**Spike:** log every inbound SysEx with `ItemType` in `{0x01, 0x03}` while pressing buttons and turning
encoders. Confirm IDs against `SLLinkProtocol.swift` (`SLButtonID`, `SLEncoderID`, `SLButtonEvent`).
Note that encoder ticks are speed-sensitive (±8 observed), so treat the delta as signed magnitude.

### Q3. How do we read and write channel-strip state? (blocks Phases 3–4)

Needed: per-channel name, level, mute state, "is active", and a colour for the ring.

`controller_midi_out(midiEvent, name, valueString, color)` delivers exactly that — parameter name,
formatted value and colour — but only for controls **mapped in Layout mode** to Smart Controls. This
has never been exercised in this project.

**Spike:** declare four `Knob` items, map one to a channel-strip volume in Layout mode, and log whether
`controller_midi_out` fires with usable `name` / `valueString` / `color`.

**Risk:** if mapping must be done by hand per concert, this stops being plug-and-play. Investigate
whether MainStage auto-maps by control name.

### Q4. Main volume — which target? (blocks Phase 5)

"MainStage main volume" could be the concert's master volume or the output channel strip. Decide, then
determine whether it is reachable via a mapped item or needs a specific CC.

### Q5. Is the byte budget enough for a patch list? (blocks Phase 1)

A list of ~8 visible rows is ~8 Write Texts. At one message per flush and `FLUSH_SOON_MS = 100` that is
~0.8 s for a full list repaint — too slow if it repaints on every encoder tick.

**Mitigation to design in from the start:** redraw only what changed (the two rows whose highlight
moved), never the whole list. This is the same per-region memoization `SLLinkDisplay.swift` already
does on the Swift side — reuse that thinking. Consider raising `FLUSH_SOON_MS` responsiveness only if
measurements demand it.

## Phases

Each phase must end in a state that is verified on hardware and committed, per the project's
one-commit-per-phase convention.

### Phase 0 — Spikes (Q1, Q2, Q3)

Throwaway probes, not shipped code. Outcome is a written answer in this document for each question.
**Do not start Phase 1 until Q1 and Q2 are answered**, since a "no" on either reshapes everything.

### Phase 1 — Patch list on screen (read-only)

- Keep the whole patch list from `controller_select_patch` (it already provides `patchlist` with
  `.IsPatch`, `.PatchIndex`, `.SetIndex`, `.Label`).
- Model: current set index, highlight index, scroll offset.
- Render a window of N rows (start with N = 6, small text, ~22 px apart) plus a header showing the set
  name. Highlight = inverted foreground/background on that row.
- Per-row memoization: keep the last string+colour drawn per row id and skip unchanged rows.
- **Acceptance:** the list matches MainStage, and changing patch in MainStage moves the highlight,
  redrawing at most two rows.

### Phase 2 — Navigation and selection

Depends on Q1 + Q2.

- Joystick Up / Down (`0x11` / `0x13`) → move highlight, clamped within the set.
- Joystick Left / Right (`0x12` / `0x14`) → previous / next set, highlight resets to its first patch.
- Joystick main (`0x15`): SHORT = select highlighted patch; LONG = jump to the set's first patch.
- Joystick encoder (`SLEncoderID.joystick`) rotation also moves the highlight.
- Selection emits the patchselector triple established in Q1.
- Handle both `SLButtonEvent.short` and `.long` — never drop LONG (see CLAUDE.md deviation 5).
- **Acceptance:** the SL88 alone can browse and select across sets; MainStage follows.

### Phase 3 — Encoders 1–4 → first four channel strips

Depends on Q3.

- Map encoders `0x00`–`0x03` to the first four channels of the current patch.
- Turning adjusts that channel's level; the value comes back via `controller_midi_out`.
- Show each channel's name and level on screen beneath the list (or on a second page — decide during
  Phase 1 layout).
- **Acceptance:** turning encoder 1 changes channel 1's level in MainStage, and the screen agrees.

### Phase 4 — Rings and mute

- Ring lit when the channel is active; use the RGB LED message (`ItemType 0x05`) and take the colour
  from `controller_midi_out`'s `color` argument where available.
- Encoder press (`0x00`–`0x03`) toggles mute; muted → ring off.
- Mirror onto the white LEDs (`ItemType 0x02`) if that reads better on hardware.
- **Acceptance:** mute state on the SL88 and in MainStage always agree, including when changed in
  MainStage.

### Phase 5 — Main volume on the B encoder + pop-up

Depends on Q4.

- B encoder (`SLEncoderID.bEncoder`) adjusts main volume.
- On change, draw a small pop-up (a filled rect plus a level readout) and remove it after ~1.5 s of
  no movement.
- **Removal is the interesting part**: Clear Screen is banned, so the pop-up must be erased by
  redrawing exactly the regions it covered. Design the pop-up to sit in a region whose restore is
  cheap — ideally one that overlaps as few list rows as possible.
- Timing: the session clock is the only timer, so pop-up dismissal is quantised to the tick rate.
  A dedicated shorter interval while a pop-up is visible may be needed.
- **Acceptance:** turning B shows the level and the screen returns exactly to its previous state.

## Cross-cutting constraints to respect

- **Byte budget.** One message per flush, ≤72 bytes, always paired with the query.
- **No Clear Screen, ever.** Erase by redrawing regions.
- **Redraw only what changed.** The budget makes full repaints expensive; per-region memoization is
  mandatory, not an optimisation.
- **Two script instances.** MainStage loads the script once per USB-MIDI interface. Both will try to
  drive the screen. Today they get distinct DeviceIDs; with interactive control this could mean two
  competing UIs, so decide whether the second instance should stay passive.
- **Never swallow musical MIDI.** `controller_midi_in` must keep returning `nil` for notes, pitch bend
  and sustain, or notes hang.

## Deliberately out of scope for now

Device icon upload, Hardware/Pedal Settings, bitmap/icon drawing, and anything requiring the helper
app — the Swift app remains unused by this path.
