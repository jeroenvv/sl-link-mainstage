# Writing MainStage Lua device scripts — a practical guide

MainStage can drive a MIDI controller through a **Lua device script**: MainStage calls your callbacks
(including handing you the entire patch list), and you return MIDI to send back to the device. It is
the mechanism behind Nektar Panorama-class integrations — *not* Program Change numbers, and *not*
parsing the `.concert` package.

Almost none of this is documented publicly, and several parts contradict what the shipped examples
imply. Everything below was verified against **MainStage 3.7.1 on macOS 26.5**. Where a finding comes
from a single device (a Studiologic SL88 MK2), it is marked — it may not generalise.

**Read the shipped scripts.** Apple bundles 98 of them, which is the real reference documentation:

```
/Applications/MainStage.app/Contents/Frameworks/MACore.framework/Versions/A/Resources/
  MIDI Device Scripts/<Manufacturer>/<Model>.device/config.lua
```

Two worth reading first: `Infinite Response/VAX77.device` (a keyboard with a display that browses
MainStage patches — the closest analogue to a rich integration) and `Arturia/KeyLab 88.device`. For a
modern, actively maintained third-party example, see
<https://github.com/mkuron/launchkey-mk3-mainstage> (its released `.pkg` can be opened read-only with
`pkgutil --expand`).

---

## 1. Where scripts live, and how they are matched

**Install location** — user-writable, no admin rights, survives MainStage updates:

```
~/Music/Audio Music Apps/MainStage Devices/<Manufacturer>/<Model>.device/config.lua
```

**Do not use `~/Music/Audio Music Apps/MIDI Device Scripts/`.** That is Logic Pro's folder of the same
shape. MainStage will happily *list* it and never load from it — a silent failure that is easy to
misread as "my script is broken".

**Matching** is either generic (by manufacturer/model) or by USB IDs:

```lua
function controller_info()
  return {
    model = 'Launchkey MK3 61',            -- required
    manufacturer = 'Focusrite - Novation', -- required
    -- usb_vendor_id = 7285,               -- optional; decimal
    -- usb_product_id = 717,
    items = { ... },                       -- required
  }
end
```

Of the 98 bundled scripts, **all 98** set `model`, `manufacturer` and `items`; only **3** set an active
`usb_vendor_id`. Prefer generic matching — it is what nearly every working example uses, and Apple's
own `KeyLab 88` keeps its USB IDs commented out.

Matching runs on CoreMIDI device-add events. A full quit and relaunch of MainStage forces a rescan; you
do not need to unplug the device if it is already connected.

**Virtual endpoints do not work.** A bare `MIDISourceCreate`/`MIDIDestinationCreate` pair has no parent
`MIDIDeviceRef`/`MIDIEntityRef`, and MainStage never binds a script to one. Creating a proper device
requires `MIDIDeviceCreate`, which returns `paramErr` (-50) for any non-driver process. So a script
cannot be pointed at a virtual port your own app publishes — it must match real hardware.

**2026-09-05, confirmed on hardware:** **`model` is a matching key, not a label. It must equal the
device's reported `kMIDIPropertyModel`, and a mismatch fails completely silently — the script simply
never loads, with no error anywhere.** Hit this renaming this project's device from `SL` to `SL88` —
the SL88 MK2 reports `model: SL` over CoreMIDI (`Scripts/list-midi.swift` prints a connected device's
reported manufacturer/model, which is how to find the value generic matching needs), so `model =
'SL88'` no longer matched anything. Three things were tried to keep the friendlier name and all three
failed:

1. `model = 'SL88'` alone — never loaded, zero `[sllink]` lines.
2. `model = 'SL88'` plus correct active `usb_vendor_id`/`usb_product_id` (verified against `ioreg`) —
   still never loaded, across two restarts. **USB IDs are an additional filter, not a substitute for
   manufacturer/model matching.**
3. `model = 'SL88'` plus `compatibleModels = { 'SL' }` — still never loaded, 91 seconds after launch.
   **`compatibleModels` does not participate in device matching**, at least not in any way that lets
   `model` differ from the hardware's reported model.

Neither USB IDs nor `compatibleModels` is an escape hatch. `model` must equal the hardware's reported
`kMIDIPropertyModel` exactly.

**Confirmed:** the containing `.device` folder name must also equal `model`, which must equal the
hardware's reported `kMIDIPropertyModel`. A fourth negative isolated it: `model = 'SL'` restored (USB
IDs commented back out, no `compatibleModels`) — the exact configuration that worked all morning —
still never loaded while the folder stayed named `SL88.device`. All four attempts, compactly:

1. `model = 'SL88'` alone — never loaded.
2. `model = 'SL88'` plus correct active USB IDs — never loaded.
3. `model = 'SL88'` plus `compatibleModels = { 'SL' }` — never loaded.
4. `model = 'SL'` (the known-working config) but folder still `SL88.device` — never loaded.

The device's presented name is dictated entirely by its firmware; it cannot be relabelled from a
device script, and every failure mode above is silent — the script simply never loads, with no error
anywhere. Folder name, `model` and the hardware's reported model must all agree; there is no escape
hatch. The device stays `SL.device` with `model = 'SL'`.

Lesson from a separate mix-up the same day: a static finding must name the MainStage version it came
from, and that version must be the one actually running — two installed copies can otherwise produce
findings that silently describe the wrong app.

## 2. `controller_info` — the `items` table

Each item describes one physical control and makes it mappable in MainStage.

```lua
{name='Knob 1', label='Cutoff', objectType='Knob', midiType='Relative2C',
 midi={0xB0, 0x4A, MIDI_LSB}, inport=DAW_OUT, outport=DAW_IN}
```

`MIDI_LSB`, `MIDI_MSB` and `MIDI_Wildcard` are globals MainStage injects — placeholders in the `midi`
pattern for "the value goes here" and "match anything". Hardware logging (2026-09-05) showed their
actual runtime values are the **strings** `'aa'`, `'bb'` and `'??'` respectively; `MIDI_CtrChange` also
exists and is `176` (`0xB0`). The offline harness had stubbed the three as the number `0`, which was
wrong.

Vocabulary actually used across the 98 bundled scripts:

| `objectType` | Count | | `midiType` | Count |
|:---|---:|---|:---|---:|
| `Button` | 921 | | `Momentary` | 657 |
| `Knob` | 770 | | `Note` | 599 |
| `Drumpad` | 567 | | `Alternating` | 150 |
| `VFader` | 452 | | `Single` | 139 |
| `Wheel` | 182 | | `Keyboard` | 88 |
| `Keyboard` | 88 | | `Relative2C` | 42 |
| `Sustain Pedal` | 72 | | `DirectionAndSpeed` | 11 |
| `Pedal` | 47 | | `RelativeSM` | 10 |
| `Volume` | 14 | | `Absolute` | 8 |
| `HFader` | 2 | | `Toggle` | 6 |

A `Keyboard` item takes `startKey` and `numberKeys`. Other `controller_info` keys seen: `preset_name`
(53 scripts — a UI hint telling the user which device preset to select), `auto_passthrough` (10),
`device_request` (3, a SysEx inquiry), `copyright`, and `patchselector` — used by just two scripts,
both Infinite Response (`VAX77`, `VAXMIDI`). Setting it arms a parser in MainStageCore itself
(symbol `_WsMIDIHasPatchSelector`, `0x6e304`). Its wire format, confirmed against that parser rather
than against VAX77's own header comment — which is wrong about its own protocol:

- Status byte must be **exactly `0xB0`** — channel 1, not channel 16.
- **CC 0 (Bank MSB) only latches a value. CC 32 (Bank LSB) is what performs the selection.** MSB must
  arrive before LSB.
- **No Program Change is involved at all.** Selection completes on CC 32. VAX77 swallows inbound
  Program Change outright (its lines 17-18) and writes `0x7F` into the PC field of the row template it
  sends as a "none" sentinel — consistent with PC playing no role on the wire.
- **LSB indexes the concert's children (the SET); MSB indexes that set's children (the PATCH)** — the
  inverse of what an earlier version of this doc said. VAX77's own table-building code (lines 55-64)
  agrees with the binary; its header comment does not — the same trap this doc fell into.

**The parser only runs when `controller_midi_in` returns falsy.** When a script returns a table,
MainStage dispatches the event into the generic assignment/action layer instead, and the
patch-selector code is branched around entirely. So bytes injected via a `controller_midi_in`
substitution return (§4) can **never** reach the patch selector — on any channel, in any byte order,
with or without a Program Change. There is no encoding of the injection that makes this work.

Caveats on the above: the branch polarity was inferred from control flow in the disassembly, not from
a named symbol, and the parser's target class was not confirmed via an `isKindOfClass:` check. What
would confirm it: sending MSB-then-LSB on channel 1 with no Program Change from a **real** external
MIDI port, not an injected substitution.

### The complete key vocabulary, read out of the binary

`controller_info()`'s parser lives in `LogicMainStage.framework` (MainStage and Logic Pro share the
control-surface code; this framework was named `LogicPro.framework` in older MainStage versions such
as 3.7.1), not in MainStage's own binary. `strings` on
`/Applications/MainStage.app/Contents/Frameworks/LogicMainStage.framework/Versions/A/LogicMainStage`
(version 4.3.1, the one actually running) finds one contiguous string table holding every key the
parser recognises, interleaved with its own error strings (`LUA: controller_info() returned a
non-table 'item' object in the items table`, `LUA: controller_info() didn't return a table`, `LUA:
Script incompatible with application '%@'`) — that co-location is what ties this list to the Lua
parser rather than to some unrelated plist schema.

Top-level keys, in the order the table stores them (usage counts are `grep -rl` over the 98 bundled
scripts under `MIDI Device Scripts/`, §1; "—" means not independently counted):

| Key | Scripts | Note |
|:---|---:|:---|
| `model`, `manufacturer`, `items` | 98 | required; documented above |
| `usb_vendor_id` / `usb_product_id` | 4 / — | documented above (§1 counts 3 as *active* — `M-Audio/Axiom 25 #1`, `M-Audio/Oxygen 25 #1`, `M-Audio/Oxygen 49 #1`; the 4th is commented out, in `Arturia/KeyLab 88.device/config.lua:70` — `--usb_vendor_id = 7285,`) |
| `preset_name` | 53 | documented above |
| `auto_passthrough` | 10 | documented above |
| `device_request` / `device_reply` | 3 / 0 | `device_request` documented above (SysEx inquiry); `device_reply` **unproven** |
| `patchselector` | 2 | documented above |
| `compatibleModels` | 0 | **unproven** |
| `logicpro` / `logicprox` | — / 3 | presumably app-targeting flags, parallel to `action_<app>` below; **unproven** |
| `supports_feedback` | 5 | **unproven** — presumably declares `controller_midi_out` support |
| `always_update` | 0 | **unproven** |
| `ignore_notes` | 2 | **unproven** — presumably suppresses passing Note events through |
| `device_inquiry` | 37 | the most-used key with no documented meaning here; **unproven** |
| `action_` (bare prefix) | 0 | root of the `action_<app>` family — see below |
| `action` | 0 | a distinct, singular per-item key, sitting next to `objectType`/`midiType` in the table; **unproven** |
| `assignments` / `alertAssignments` | 0 / 0 | sub-vocabulary below; **unexplored** |
| `copyright` | — | documented above |
| `OSC_pattern` | 0 | **unproven** |
| `dBToFader` / `dbToFader` | 0 / 0 | both cases present in the binary — the parser evidently accepts either; **unproven** |
| `replacingPlugInModel` / `replacingPlugInManufacturer` | 1 / 0 | from the table's second copy (re-locate via the anchor string in 4.3.1's binary rather than an offset, since offsets differ between versions); `replacingPlugInModel` associates the script with a plug-in for `PreferPlugIn()` (Roland `A-PRO`'s own comment); `replacingPlugInManufacturer` **unproven** |

Per-item keys: `objectType` and `midiType` sit immediately after `action` in the table. The ones the 98
scripts actually use — `name`, `label`, `midi`, `inport`, `outport`, `startKey`, `numberKeys` — are
already covered above; this list adds nothing new there.

So most of this vocabulary is unexercised by Apple's own scripts and unproven by this project — only
`device_inquiry`, `supports_feedback`, `usb_vendor_id`, `logicprox` and `ignore_notes` see any use at
all, and none of those uses has been decoded here.

**`assignments` / `alertAssignments` sub-vocabulary.** The same string table continues straight into a
second block that reads like Logic's control-surface assignment model exposed to Lua: `controlID`,
`paramName`, `shortParamName`, `OSCValueChange`, `OSCTouched`, `OSCLabel`, `OSCValueString`,
`midiTouched`, `gotoMarker`, `alertButton`, `liveLoopsColumn`, `globalObj`, `clockPart`,
`faderBankTrack`, `CSTrack`, `track`, `output`, `master`, `audio`, `instr`, `extMIDI`, `trackParam`,
`isMIDIPlugIn`, `boundManuf`, `boundSubID`, `boundPlugInID`, `keyCmd`, `CSGroupObj`, `bankType`,
`viewFilter`, `groupObj`, `groupParam`, `flipGroup`, `textFeedback`, `fbType`, `valueFormat`,
`valueMode`, `minVal`, `maxVal`, `minMaxOnly`, `selfFeedback`, `exclusive`, `keyRepeat`, `multiply`,
`ignoreTrim`, `objOffset`, `paramOffset`, `zone`, `mode`, `control`. Flagged as a lead worth returning
to, **not** as something known to work from a device script — zero of the 98 bundled scripts touch any
of it.

### `action_<app>`: binding a control to a MainStage command with no MIDI-Learn

Arturia's shipped `KeyLab 88 mk3.device/config.lua` (v1.4) declares seven items carrying an
`action_mainstage` field and **no** `objectType`:

```lua
{ name = "Play Stop", midiType = "Momentary", midi = {MIDI_CtrChange, 21, MIDI_LSB},
  inport = 'DAW', outport = 'DAW', action_mainstage = 'PlayStop' },
```

The seven values it uses: `Metronome`, `PanicFull`, `PlayStop`, `Record`, `TapTempo`, `Undo`, `Redo`.

The literal string `action_mainstage` appears **nowhere** in MainStage 4.3.1's binaries or resources
(verified by a recursive binary-safe grep of the whole app bundle; also absent from 3.7.1's binaries).
The bare prefix `action_` **does**,
inside the key table above, next to the sibling keys `logicpro`/`logicprox`. **Inference, not fact:**
the key is composed at runtime as `action_` followed by the lower-cased application name — MainStage
passes `applicationName = "MainStage"` to `controller_initialize` (seen in this project's own
`/tmp/lua.log`), which would compose to exactly `action_mainstage`. Untested on hardware as of this
writing.

The values are MainStage **command IDs**, not free text. The full set — 138 lines, ~127 commands
across 11 groups — lives in
`/Applications/MainStage.app/Contents/Resources/en.lproj/WsCommands.plist` (4.3.1; `plutil -p` to read
it; re-dump after a MainStage update, since the ID→menu mapping is not otherwise documented). All
seven Arturia names match an ID there exactly. The groups most relevant to this project:

| ID | Menu name |
|:---|:---|
| **Actions** | |
| `NextPatch` | Next Patch |
| `PreviousPatch` | Previous Patch |
| `NextSet` | Next Set |
| `PreviousSet` | Previous Set |
| `Metronome` | Toggle Metronome |
| `MasterMute` | Toggle Master Mute |
| `Panic` | Panic |
| `PanicFull` | Panic with External |
| `PlayStop` | Play/Stop |
| `Record` | Record |
| `TapTempo` | Tap Tempo |
| `ResetComparePatch` | Reset/Compare Patch |
| `SelectionFollowsMIDI` | Selection follows incoming MIDI |
| `MapParameter` | Map Parameter |
| `NewAssignment` | New Assignment |
| `AssignAndMap` | Assign and Map |
| `ArticulationMIDIRemote` | Toggle Articulation MIDI Remote |
| **Edit** | |
| `BeginSelectPatch` | Begin Select Patch |
| `Undo` | Undo |
| `Redo` | Redo |
| **View** | |
| `ToggleFullScreen` | Enter / Exit Full Screen |
| `TogglePatchList` | Toggle Patch List |
| `ViewPerform` | Perform Mode |
| `ViewLayout` | Layout Mode |
| `ViewEdit` | Edit Mode |
| **File** | |
| `SaveConcert` | Save Concert |

Why this matters here: `NextPatch`/`PreviousPatch` bound via `action_mainstage` would remove the
one-time MIDI-Learn per concert that the whole 34-CC map currently requires, and would give a
*relative* patch-navigation primitive for free — see `docs/mainstage-integration.md`, "Next thing to
try: a relative control instead of an absolute one".

The command table above is retained regardless of the result below — the IDs are a property of
MainStage's own command dispatch, not of this field, so they remain valid input to any future route
that does reach them.

**VERIFIED NEGATIVE (2026-09-05, MainStage 4.3.1, real SL88 MK2).** Two rounds, both inert.

Round 1 tested `action_<app>`/`action` in isolation:

| CC source | Channel | Key | `objectType` | Command | Fired |
|:--|:--|:--|:--|:--|:--|
| script-injected (CC 74) | 16 | `action_mainstage` | absent | Metronome | no |
| script-injected (CC 58) | 16 | `action_mainstage` | absent | Metronome | no |
| script-injected (CC 58) | 1 | `action_mainstage` | absent | ToggleChannelStrips | no |
| script-injected (CC 57) | 1 | `action` | absent | ToggleInspectors | no |
| real hardware CC 1 (mod wheel) | 1 | `action_mainstage` | `Wheel` | Metronome | no |
| real hardware CC 16 (stick 2) | 1 | `action` | absent | TogglePatchList | no |

Why this is a sound negative rather than a missed signal:

- Every injected CC was confirmed emitted with its exact declared number, via a log line added for
  this spike that prints the CC numbers in each batch (`[sllink] CC batch: 1 CC(s) [74=127], 3
  bytes`). An earlier round of this same spike produced a false negative precisely because that line
  did not exist — the gesture performed emitted CC 58 while the item under test was bound to CC 74,
  and nothing in the log showed the mismatch.
- The two real-hardware CCs were confirmed arriving in MainStage's own **Window > MIDI Message
  Monitor**.
- For CC 1 and CC 16 the script's `controller_midi_in` returns `nil` — the falsy path, already
  documented above as the condition MainStage's own parsers require (it is what `patchselector`
  needs). So the real-hardware rows are the best-case configuration, not a degraded one.
- A variant emitting no CC at all was also run and produced nothing, as predicted. That result is
  **vacuous** — MainStage had no MIDI to match, so it rules nothing in or out.

Round 1 has a confound: all six of those items omitted `objectType` and used invented names on
channel 16, so a missing `objectType` or the channel could in principle have been the reason, not
`action_<app>` itself. Round 2 closed that gap by mirroring Arturia's shipped KeyLab mk3 declarations
onto SL88 gestures **byte-for-byte** — same CC numbers (49/50/51/52 for Previous/Next Patch and Set,
91/92/94/95 for Knob1-4, 113 for Fader9, 20-23/27/43-44 for the transport and DAW commands), the same
MIDI channel 1 (`0xB0`), the same `objectType`/`midiType`, the same item names (`PreviousPatch`,
`NextPatch`, `Knob1`, `Fader9`), and the same `action_mainstage` presence or absence per control:

| Variable | Values tried |
|:--|:--|
| item `name` | invented (`Spike A1`), exact command ID (`NextPatch`, `Metronome`), Arturia's spaced names (`Play Stop`) |
| `objectType` | absent, `Button`, `Knob`, `VFader` |
| `action_<app>` | absent, present |
| CC number | ours (40-74), Arturia's exact numbers |
| channel | 16 and 1 |
| CC origin | script-injected, and real hardware CC 1 / CC 16 |

Result: no binding of any kind. Every gesture emitted its intended CC — confirmed in the log, e.g.
`[sllink] CC batch: 1 CC(s) [49=127]` and a clean absolute sweep `[113=64]`..`[113=72]` — and nothing
in MainStage responded.

Incidental finding from building the mirror: `MIDI_CtrChange` is simply the number `176` (`0xB0`), so
`MIDI_CtrChange` and `0xB0 + CC_CHANNEL` with `CC_CHANNEL = 0` are the identical value — the spelling
difference between Arturia's script and ours is cosmetic, not a protocol difference.

The mirror also moved the CC map to channel 1 to match Arturia exactly; this project's CC map stays
on **channel 16** rather than adopting that. Channel 1 is the channel the SL88 itself uses for notes,
mod wheel, Stick 1 Y and sustain, so synthetic control CCs there risk colliding with musical traffic a
patch is listening to. Channel 16 is deliberate isolation, not an arbitrary choice inherited from
elsewhere.

Supporting static evidence, already above: the literal `action_mainstage` appears nowhere in
MainStage 4.3.1's binaries (only the bare `action_` prefix, in `LogicMainStage.framework`'s key
table; also absent from 3.7.1's binaries), and zero of the 98 bundled MainStage scripts use it.

**Do not overstate this.** The honest conclusion is: inert in MainStage 4.3.1 across every path
reachable from a device script, now including a byte-for-byte mirror of a real vendor script's
declarations. It is NOT established as inert everywhere — the key table lives in
`LogicMainStage.framework`, so this may be a Logic Pro feature MainStage does not implement, and
Logic Pro is not installed on this machine, so that remains untested rather than disproven.

**Conclusion.** A MainStage device script cannot bind a control to a built-in command. `action_<app>`
is inert, item `name` is not a binding key, and mirroring a working vendor script's declarations
exactly does not help. The one-time MIDI-Learn per concert is unavoidable — and it is unavoidable for
Arturia too.

**Corrected understanding of Arturia's nav buttons.** It would be tempting to read a working KeyLab's
Previous/Next Patch buttons as evidence the device script has some mechanism this one lacks. It does
not: Arturia's own script contains no mechanism to change a patch at all — no Program Change, no Bank
Select; `SCROLL_TYPE` is redraw bookkeeping only, not patch navigation. A KeyLab whose nav buttons
work is relying on an assignment stored in that user's own MainStage setup, not on anything the
device script provides. MainStage itself ships no default controller-assignment presets — checked:
the only mapping resources in the app bundle are GM instrument mappings. Arturia's shipped
KeyLab mk3 script declares seven `action_<app>` items, which under this result do nothing under
MainStage.

## 3. Callbacks

How many of the 98 bundled scripts implement each — a useful signal of what is load-bearing versus
exotic:

| Callback | Scripts | Purpose |
|:---|---:|:---|
| `controller_info()` | 98 | Declares the device. The only mandatory one |
| `controller_midi_in(midiEvent, portName)` | 20 | Filter/transform every inbound event |
| `controller_midi_out(midiEvent, name, valueString, color)` | 14 | Feedback for mapped controls, with parameter **name, formatted value and colour** |
| `controller_names(channel)` | 13 | Names for CC numbers, per channel |
| `controller_initialize(appName, deviceNewlyDetected)` | 12 | Device setup |
| `controller_select_patch(pc, patchname, setname, concertname, patchlist, setIdx, patchIdx)` | 10 | **The whole patch list**, on every patch change |
| `controller_finalize()` | 10 | Teardown |
| `controller_select_patch_done(...)` | 6 | After the switch completes |
| `controller_timer_trigger()` | 5 | Deferred/periodic work, armed by `settriggertimer(ms)` |
| `get_grid_items()` | 4 | Grid controllers |
| `controller_note_names()` | 4 | Drum pad names |

`patchlist` entries expose `.IsPatch`, `.PatchIndex`, `.SetIndex`, `.Label`.

`midiEvent` is **0-indexed**: `midiEvent[0]` is the status byte. SysEx is delivered here too — VAX77
matches `midiEvent[0] == 0xF0` in its own `controller_midi_in`.

## 4. Sending MIDI

**There is no send function.** The only way out is the return value of a callback:

```lua
return { midi = { 0xB0, 0x07, 0x64 }, outport = 'PortName' }
```

`midi` is a **flat** byte array. Multiple complete messages may be concatenated into one array, and a
**negative number is a delay in milliseconds** (VAX77 uses `-100` to stop CoreMIDI interleaving Bank
Select with a SysEx dump).

### `outport` must be the SHORT port name

Use `kMIDIPropertyName` (`'LINK'`), **not** `kMIDIPropertyDisplayName` (`'SL LINK'`). Get this wrong and
every message is silently discarded — no error, no log line, nothing.

MainStage tells you the correct name: it is the `portName` argument passed to `controller_midi_in`.
Log that once and use exactly what it prints. *(Discovered on one device; the mechanism is
MainStage's, so it should be general.)*

### `outport` present vs absent means two different things

| Return | Effect |
|:---|:---|
| `{midi=..., outport='X'}` | Sent **outward to the device** on port X |
| `{midi=...}` from `controller_midi_in`, no `outport` | **Replaces the inbound event** — MainStage receives your bytes instead |
| `{midi={}}` from `controller_midi_in` | Swallows the event |
| `nil` from `controller_midi_in` | Passes the event through unchanged |

The substitution form is how you inject events into MainStage. Apple's `M-Audio/Oxygen 49 #1.device`
rewrites an inbound Program Change into a CC exactly this way. The Launchkey MK3 script, by contrast,
*never* injects — every one of its returns carries an `outport`, and it relies on declared `items`
plus MainStage's own assignment layer instead. Both are valid designs.

**This table is specific to `controller_midi_in`.** `outport`'s meaning is callback-dependent: in
`controller_select_patch`, `controller_initialize` and `controller_timer_trigger` there is no inbound
event to substitute, so a missing `outport` just means "the device's default output port". VAX77's
trailing Bank/PC bytes (its lines 96-108) are returned from `controller_select_patch` and travel **to**
the keyboard — they are not an example of injection, despite this project's own round-1 notes drawing
that inference from their byte ordering. That inference was invalid.

**Never swallow musical MIDI.** Returning a table replaces the event, so return `nil` for notes, pitch
bend and sustain or you will hang notes.

## 5. `settriggertimer` is a one-shot — and cannot re-arm itself

`settriggertimer(ms)` schedules **one** `controller_timer_trigger()`. Calling it again from *inside*
`controller_timer_trigger` does **not** re-arm it — the callback simply never fires again. It does
re-arm when called from `controller_midi_in`.

This is why VAX77 arms its timer from `controller_midi_in` rather than from the timer itself — a
detail that is easy to read past, and verifiable: `settriggertimer` appears once inside its
`controller_midi_in` and never inside its `controller_timer_trigger`.

**Consequence: a device script has no free-running clock.** If you need a periodic heartbeat and the
device is not already sending you traffic, you must manufacture inbound events. The pattern that works:
have every outgoing flush include a small message the device is obliged to answer; its reply lands in
`controller_midi_in`, which re-arms the timer, which sends the next one. The request/response chain
becomes the clock.

## 6. There is a byte ceiling on what a callback may return

**80 bytes deliver, 96 do not**, and exceeding the ceiling discards the **entire returned array** — not
just the overflow, and with no error. Symptoms are baffling: a burst of drawing commands where
seemingly arbitrary ones never take effect.

Send **one message per flush** and keep well under the limit. If you have more to send, queue it and
emit the rest from the next callback.

*(Measured on one device with SysEx display messages; the limit is presumably MainStage's, but the
exact threshold may vary.)*

## 7. Sandbox limits

- **`io` does not exist.** `io.open` raises `attempt to index global 'io' (a nil value)` — stricter
  than being restricted. No file-based logging, no file side channel. Wrap any attempt in `pcall`.
- **`os` should be assumed absent too**, so there is no clock and no entropy source. If you need a
  unique per-instance value, derive it from protocol feedback (e.g. bump a counter when the device
  rejects a duplicate ID) rather than randomness.
- **`bit32` *is* available** (`bit32.band` is used in shipped scripts), as are the usual `string.*`
  and `math.*` functions.
- **`string.crunch(text, maxChars)` is an undocumented MainStage-injected helper** — it fits a string
  into a character budget for a small hardware display. Used by 7 of Apple's bundled scripts and by the
  Launchkey MK3 script, always as `string.crunch(name, 16)` / `(valueString, 8)` and similar. Prefer it
  over hand-rolled truncation when writing to a character-cell display.
- `print()` works, and goes to stdout — see §9.

## 8. Instances and lifecycle

**The script is loaded once per matched USB-MIDI interface.** A device exposing three port pairs can
give you two or three live instances of your script, each with its own Lua globals. Every `print()`
appears more than once, and any resource that must be unique per host (a session ID, ownership of a
display) will collide. Design for it. (One recorded SL88 MK2 run exposed all three pairs but loaded a
single instance — see
`docs/config-lua-history.md#single-instance-confirmed-on-hardware-2026-08-28`; the guidance above
still stands as defence.)

**MainStage tears the script down and re-initialises it repeatedly** — `initialize → finalize →
initialize` within seconds, and not only when the user quits. Do **not** treat `controller_finalize` as
"the user is done": if you send a teardown/goodbye message there, every spurious churn will undo your
session.

## 9. Debugging

```bash
defaults write com.apple.mainstage3 LUA_DEBUG -bool true     # note the '3' — version-suffixed bundle id
/Applications/MainStage.app/Contents/MacOS/MainStage > /tmp/lua.log 2>&1 &
```

- `LUA:` lines and every `print()` go to **stdout only**. `log show`, `log stream` and `os_log` show
  nothing — this is why the flag is often assumed not to work.
- The bundle identifier is `com.apple.mainstage3`, not `com.apple.mainstage`.
- Turn it off afterwards; it measurably slows MainStage down.
- A successful match logs e.g. `LUA: Script matched for USB ID 0x9516,0x4039` or
  `LUA: Script matched generically for manufacturer: ...`.

**Quitting MainStage raises a "save the concert?" dialog.** Unanswered, it silently blocks the quit, so
your relaunch never happens and the next test appears to fail for unrelated reasons. Script the
dismissal and verify the process actually exited.

**Test the logic offline first.** `config.lua` is plain Lua: stub `settriggertimer` and the `MIDI_*`
globals, `dofile` the script, call the callbacks with 0-indexed event tables, and assert on the bytes
returned. A hardware round-trip costs a slow MainStage relaunch; most bugs do not need one.

**Beware timing when judging results.** If the concert loads real instruments, MainStage takes a long
and variable time to become ready, and a result captured during startup is indistinguishable from a
failure. Confirm it is loaded rather than waiting a fixed interval.

## 10. Case study: the Launchkey MK3 script

<https://github.com/mkuron/launchkey-mk3-mainstage> is the most useful third-party example available —
actively maintained, and doing everything a rich integration needs. Its released `mainstage-devices.pkg`
can be inspected read-only without installing:

```bash
pkgutil --expand mainstage-devices.pkg out
mkdir payload && cd payload && gunzip -c ../out/*.pkg/Payload | cpio -id
```

Its `PackageInfo` confirms the install location independently: `install-location=
"Music/Audio Music Apps/MainStage Devices"`.

Techniques worth stealing:

- **A dedicated DAW port pair.** `DAW_IN = 'LKMK3 DAW In'`, `DAW_OUT = 'LKMK3 DAW Out'`, declared once
  and referenced as `inport`/`outport` on **every** interactive item. Note these are that device's
  actual CoreMIDI port names — the rule from §4 still holds: use whatever `controller_midi_in` reports
  as `portName`, whatever its length.
- **Enter and leave the device's DAW mode explicitly.** `controller_initialize` sends `0x9f 0x0c 0x7f`
  to switch the hardware into DAW mode plus SysEx setting pad/fader/pot sub-modes;
  `controller_finalize` sends `0x9f 0x0c 0x00` to switch back. It then filters the device's own echo of
  that activation message in `controller_midi_in`, so it does not confuse its own state.
- **It never injects into MainStage.** Every single `{midi=...}` return carries `outport = DAW_IN` — it
  talks only to the device, and relies on declared `items` plus MainStage's assignment layer for
  control. It does not set `patchselector`. This is the opposite design choice from Apple's Oxygen
  script (§4) and is the lower-risk one.
- **`controller_midi_out` drives the display.** It receives the parameter `name`, `valueString` and
  `color` for each mapped control and writes them to the Launchkey's screen, caching the last label and
  value per control (`labelDisplayCache` / `valueDisplayCache`) so an unchanged parameter costs no
  SysEx. This is the pattern to copy for any device with a screen.
- **Deferred post-switch updates.** `controller_select_patch` builds a table of "things to update after
  the patch change" (LEDs off, parameter names cleared) keyed by control, and
  `controller_select_patch_done` simply returns it. That keeps the switch itself fast and lets later
  `controller_midi_out` calls cancel individual entries before they are sent.
- **Nearest-colour matching.** MainStage supplies an arbitrary RGB `color`; the device accepts only a
  fixed 128-entry palette. The script converts using a redmean distance function and memoizes the
  result per colour. Any device with an indexed LED palette needs this.
- **Conditional item lists.** Items are built in a plain Lua table and pruned at `controller_info` time
  (`HAS_FADERS`), so one script serves five hardware variants.
- **Flat `midi` arrays with `-2` delay markers** between concatenated messages.

## 11. Checklist

- [ ] Installed under `MainStage Devices/`, not `MIDI Device Scripts/`
- [ ] `controller_info` returns `model`, `manufacturer`, `items`
- [ ] Generic matching unless you have a specific reason to use USB IDs
- [ ] `outport` uses the **short** port name — confirm it against `controller_midi_in`'s `portName`
- [ ] One message per return; 80 bytes is measured good, 96 is not
- [ ] Timer re-armed from `controller_midi_in`, never from `controller_timer_trigger`
- [ ] Periodic work has a real clock source (inbound traffic you provoke, if necessary)
- [ ] `controller_midi_in` returns `nil` for musical MIDI
- [ ] No reliance on `io` or `os`
- [ ] Safe against multiple script instances
- [ ] `controller_finalize` does not assume the user quit
- [ ] `LUA_DEBUG` turned back off
