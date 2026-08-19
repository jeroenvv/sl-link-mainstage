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

## 2. `controller_info` — the `items` table

Each item describes one physical control and makes it mappable in MainStage.

```lua
{name='Knob 1', label='Cutoff', objectType='Knob', midiType='Relative2C',
 midi={0xB0, 0x4A, MIDI_LSB}, inport=DAW_OUT, outport=DAW_IN}
```

`MIDI_LSB`, `MIDI_MSB` and `MIDI_Wildcard` are globals MainStage injects — placeholders in the `midi`
pattern for "the value goes here" and "match anything".

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
both Infinite Response (`VAX77`, `VAXMIDI`). Setting it means MainStage's own core listens for the
device to select a patch with **Bank Select MSB = SetIndex, LSB = PatchIndex on channel 16, then a
Program Change** — you do not derive Program Change numbers yourself. VAX77's header states this, and
it swallows inbound Program Change entirely.

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

Measured between **78 and 87 bytes**, and exceeding it discards the **entire returned array** — not
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
display) will collide. Design for it.

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
- [ ] One message per return; stay well under ~78 bytes
- [ ] Timer re-armed from `controller_midi_in`, never from `controller_timer_trigger`
- [ ] Periodic work has a real clock source (inbound traffic you provoke, if necessary)
- [ ] `controller_midi_in` returns `nil` for musical MIDI
- [ ] No reliance on `io` or `os`
- [ ] Safe against multiple script instances
- [ ] `controller_finalize` does not assume the user quit
- [ ] `LUA_DEBUG` turned back off
