# MainStage integration — how it works, and what was established by probing

Reference notes for the MainStage bridge. Written up because almost none of this is documented
publicly, and the parts that *are* documented are contradicted by what MainStage actually does.

## The mechanism

MainStage supports **Lua MIDI Device Scripts**. A matched device gets callbacks from MainStage,
including the entire patch list. This is the mechanism behind Nektar Panorama-class integrations —
notably *not* Program Change numbers and *not* parsing the `.concert` package.

Apple ships 98 scripts inside the app bundle, organised by manufacturer, including one from Nektar:

```
/Applications/MainStage.app/Contents/Frameworks/MACore.framework/Versions/A/Resources/
  MIDI Device Scripts/<Manufacturer>/<Model>.device/config.lua
```

Read those for working examples. The closest analogue to what this project needs is
`Infinite Response/VAX77.device/config.lua` (179 lines) — a keyboard with a display that browses
MainStage patches.

### Script API

| Callback | Purpose |
|:---|:---|
| `controller_info()` | Declares `model`, `manufacturer`, `items` (controls + MIDI), capability flags |
| `controller_select_patch(pcNumber, patchname, setname, concertname, patchlist, currentSetIndex, currentPatchIndex)` | MainStage pushes the **whole patch list** to the device |
| `controller_select_patch_done(pcNumber, patchname, setname, concertname)` | Fires after the switch completes |
| `controller_midi_in(midiEvent, portName)` | Filter/transform inbound device MIDI; return `{midi={}}` to swallow an event, `nil` to pass it through |
| `controller_midi_out(midiEvent, name, valueString, color)` | Control feedback carrying parameter **name, value string and colour** |
| `controller_initialize(applicationName, deviceNewlyDetected)` / `controller_finalize()` | Lifecycle — the natural hello/goodbye for bridge liveness |
| `controller_timer_trigger()` with `settriggertimer(ms)` | Deferred and periodic work |
| `controller_version()`, `controller_names(channel)`, `controller_note_names()`, `get_grid_items()` | Other hooks seen in shipped scripts |

`patchlist` entries expose `.IsPatch`, `.PatchIndex`, `.SetIndex`, `.Label`.

Callbacks return a list of MIDI event tables to send to the device. **A negative number in that list
is a delay in milliseconds** — the VAX77 script uses `-100` to stop CoreMIDI interleaving Bank Select
events with a SysEx dump.

### Patch selection is by index, not Program Change

`controller_info()` declares `patchselector = true`. The device then selects a patch by sending
**Bank Select MSB = PatchIndex, Bank Select LSB = SetIndex**, then a Program Change. The VAX77
script's own comment says so, and it swallows inbound Program Change entirely:

```lua
elseif midiEvent[0] == 0xC0 then
    return {midi={}}    -- always ignore program change for this keyboard
end
```

So there is no need to derive PC numbers, and no need for MainStage's "Reset Program Numbers".

### Device matching

From strings in `LogicMainStage.framework`, matching is either by **USB vendor/product id**
(`usb_vendor_id`) or **generically by manufacturer / devicename / modelname**:

```
LUA: Script matched for USB ID %#lx,%#lx
LUA: Script matched generically for manufacturer: '%@', devicename: '%@', modelname: '%@'
LUA: No matching script found for for manufacturer: '%@', devicename: '%@', modelname: '%@'
```

Generic matching is what makes a *virtual* MIDI endpoint plausible: set `kMIDIPropertyManufacturer`
and `kMIDIPropertyModel` on the endpoint to match `controller_info()`.

## Established by probing (2026-08-17, MainStage 3.7.1)

### Script search paths — there IS a user-writable location

Determined empirically by creating candidate directories, launching MainStage, and comparing
directory access times against the process start time. MainStage started at 12:44:56; the folders it
read show an atime of 12:44:57, the ones it ignored still show their creation time.

| Path | Scanned? |
|:---|:---|
| `~/Music/Audio Music Apps/MIDI Device Scripts/` | listed, but **this is Logic Pro's folder** — see correction below |
| `~/Music/Audio Music Apps/MainStage Devices/` | **yes — this is the one MainStage actually loads from** |
| `~/Music/Audio Music Apps/MIDI Device Profiles/` | yes |
| `~/Library/Application Support/MIDI Device Scripts/` | no |
| `~/Library/Application Support/MainStage/MIDI Device Scripts/` | no |

`~/Music/Audio Music Apps/` is the shared Logic/MainStage user content root, and those three
subfolder names appear adjacent to each other in `LogicMainStage`, next to `Shared`.

This is the good outcome: installing a script needs no admin rights, no modification of
`MainStage.app`, and survives MainStage updates.

> **Correction (2026-08-17, Phase 0 v2 spike):** the row above originally said `MIDI Device Scripts`
> was "the one to use" — wrong, and it cost several rounds of a script silently never matching.
> `MIDI Device Scripts` is Logic Pro's folder; MainStage reads `MainStage Devices`. The directory-atime
> evidence above only ever proved MainStage *listed* both folders (plausible if a shared `LogicMainStage`
> framework enumerates the whole `Audio Music Apps` tree regardless of which app is running), not that
> it loads `config.lua` from either one. Installing under `MainStage Devices/<Manufacturer>/<Model>.device/`
> and matching by `usb_vendor_id`/`usb_product_id` is what actually produces `LUA: Script matched for
> USB ID 0x9516,0x4039` in the log — confirmed live, twice per launch (one line per USB-MIDI interface
> the SL88 exposes).

### Things that did not work, so nobody repeats them

- **Lua's `io` library appears to be unavailable.** A probe script calling `io.open` at parse time
  wrote nothing from any location, including folders proven scanned by their atime. Don't plan on
  file-based logging from inside a script.

> **Correction (2026-08-17, Phase 0 v2 spike):** this section originally also claimed `LUA_DEBUG`
> "could not be switched on from outside" — wrong. It works:
> `defaults write com.apple.mainstage3 LUA_DEBUG -bool true`, then launch
> `/Applications/MainStage.app/Contents/MacOS/MainStage` from a terminal with stdout redirected
> (`> /tmp/lua.log 2>&1`) — `LUA:` lines, including every `print()` call from a device script, go to
> **stdout only**; `log show`/`log stream`/`os_log`/`~/DebugLog` show nothing, which is almost
> certainly why the earlier attempt concluded it didn't work. The earlier attempt also used the wrong
> bundle id (`com.apple.mainstage`, no `3` suffix) — the same mistake that broke process detection
> elsewhere in this investigation. Turn it back off afterwards
> (`defaults write com.apple.mainstage3 LUA_DEBUG -bool false`) — it measurably slows MainStage down.

### Still unverified

Whether MainStage will generically match a **virtual** MIDI endpoint (as opposed to a physical USB
device). The shipped scripts all target real hardware. This is cheap to test once the app publishes
its virtual endpoints, and is the remaining gate on the whole approach.

## Virtual device registration — spike result: does not work (2026-08-17)

MainStage sees our bare `MIDISourceCreate`/`MIDIDestinationCreate` endpoints but never binds
`config.lua` to them. Comparing our endpoints against the real SL88 in CoreMIDI shows the difference:
the SL88's ports each have a parent `MIDIDeviceRef` (name `SL`) and `MIDIEntityRef`; our virtual
endpoints have neither, because `MIDISourceCreate`/`MIDIDestinationCreate` never create one. Since
MainStage's own log strings talk about matching on `devicename` as well as `manufacturer`/`modelname`,
the working theory was that a bare endpoint has nothing to supply `devicename` from, and that
publishing a proper `MIDIDeviceRef` (`MIDIDeviceCreate` → `MIDIDeviceAddEntity` → `MIDISetupAddDevice`)
would fix that.

**It doesn't get far enough to test that theory.** `MIDIDeviceCreate(owner: nil, ...)` — the only
entry point a non-driver process has into this API at all — returns `paramErr` (`-50`) immediately,
before `MIDIDeviceAddEntity` or `MIDISetupAddDevice` are ever reached. Confirmed twice, identically:

1. A bare, unsigned, unsandboxed command-line probe (`swiftc` + run directly, no Xcode project, no
   entitlements) got `-50` from the very first call.
2. The actual signed, sandboxed Debug build of this app (`ENABLE_APP_SANDBOX = YES`, confirmed via
   `codesign -d --entitlements`, no MIDI-related entitlement present or added) got the identical `-50`,
   logged live in the dev console's "MainStage Bridge" section and its MIDI Log pane.

Both runs fail at the same call with the same code, so **this is not an App Sandbox restriction** — no
entitlement would fix it, and none was added (per the task's constraint not to add one speculatively).
It is CoreMIDI itself refusing `MIDIDeviceCreate` for a process that isn't a registered MIDI driver,
on this machine's macOS version (26.5.1). Apple's own `MIDIDriver.h` comment on `MIDIDeviceCreate`
("Non-drivers may call this function ... to create external devices") appears to no longer hold in
practice, or never held for the *embedded* (I/O-capable) entity shape this task needed rather than the
external-device (metadata-only, no owned endpoints) shape. Either way, the distinction is moot here:
both shapes go through the identical `MIDIDeviceCreate` call, which fails first.

This also means `MIDISetupAddDevice` was never reached to test its own documented restriction, but
it's worth recording anyway since it explains *why* the API is shaped this way: `MIDISetup.h` says
outright, "Only MIDI drivers may make this call; it is in this header file only for consistency with
`MIDISetupRemoveDevice`." A real fix would mean shipping an actual CoreMIDI driver bundle (a
`MIDIDriverInterface`-conforming plug-in installed under `~/Library/Audio/MIDI Drivers/` or
`/Library/Audio/MIDI Drivers/`, loaded by `coremidiservice` itself) — a materially different, far
more invasive architecture than an ordinary sandboxed app calling `MIDIClientCreate`, and out of scope
for this milestone.

**Outcome:** `SL-Link-Mainstage/MainStage/MainStageDeviceRegistration.swift` implements the full
requested `MIDIDeviceCreate` → `MIDIDeviceAddEntity` → `MIDISetupAddDevice` chain anyway (rather than
stopping at the probe), logging every `OSStatus`, so that if Apple ever loosens this restriction it
starts working with no further code changes, and so the dev console always shows the real, current
status. It also implements the requested stale-device cleanup (scans `MIDIGetNumberOfDevices()` for a
device matching our manufacturer/model/name at every startup, before attempting a fresh registration)
and a manual "Remove Device" dev-console button, both of which are cheap, correct, and harmless to ship
even though registration itself never succeeds on this machine — they cost nothing today and start
paying off the moment (if ever) the underlying restriction lifts.

`MainStageEndpoint`'s bare `MIDISourceCreate`/`MIDIDestinationCreate` endpoints remain the sole
publishing mechanism that actually works, unchanged by any of this. Whatever is blocking MainStage from
binding `config.lua` to them, it is not the missing device/entity parent — or if it is, this project has
no way to supply one without becoming a CoreMIDI driver. The remaining open question is the same
"still unverified" one above: whether MainStage's generic matcher will bind to a virtual endpoint at
all, bare or otherwise. That can only be answered by the user, at the keyboard, with MainStage actually
running and the device script installed.

## The SL88's own MIDI identity

For reference when writing `controller_info()` — the SL88 MK2 presents three port pairs, all
reporting manufacturer `STUDIOLOGIC`, model `SL`, device `SL`:

| Endpoint name | Display name | Used for |
|:---|:---|:---|
| `CTRL` | `SL CTRL` | normal keyboard MIDI to the host |
| `DAW` | `SL DAW` | DAW control |
| `LINK` | `SL LINK` | the SL Link protocol this app speaks |

## Status 2026-08-17 — device-script route BLOCKED

Bridge never goes live. Two dead ends found, one open question.

**Dead end 1 — no parent device.** `MIDIDeviceCreate` returns `paramErr` (-50) for any non-driver
process. Confirmed in both the sandboxed app and a bare unsigned CLI probe, so it is not a sandbox
issue. `MIDISetup.h`: "Only MIDI drivers may make this call." Our virtual endpoints therefore have no
`device`/`entity`, unlike the real SL88's ports.

**Dead end 2 — no third-party script has ever demonstrably run.** A probe script installed under the
*physical* SL88's own identity (`STUDIOLOGIC`/`SL`) emitted nothing on CTRL, DAW or LINK across five
genuine patch changes, where `controller_select_patch` is contractually guaranteed to fire.

**Correction to the Phase 0 finding above.** The directory-atime evidence proves MainStage *listed*
`~/Music/Audio Music Apps/MIDI Device Scripts/`, NOT that it loads scripts from there. That section
overstates its case. Per-file atimes do not update on this system (Apple's own bundled VAX77
`config.lua` shows a 2023 atime despite certainly being parsed), so file-level access cannot be used
as evidence either.

**Open question:** is our script shape wrong, or are third-party scripts in the user folder never
loaded at all? The discriminating test is installing a probe *inside* MainStage.app next to Apple's
own scripts, where they definitely load. Needs sudo and can invalidate the app's code signature.

**Fallback if the route is truly closed:** Program Change + `.concert` parsing. Concert structure is
parseable — patch/song names are directory names under `Concert.patch/`, order comes from each
level's `nodes` array. Loses live sync when the patch is changed inside MainStage.

## Phase 0 v2 — does `outport` reach an arbitrary destination? (2026-08-17, MainStage 3.7.1)

The v1 status above assumed the script was never binding at all. It turns out that diagnosis was
half right: with both bugs fixed (script under `MainStage Devices/`, matched by
`usb_vendor_id = 38166, usb_product_id = 16441` inside `controller_info()`, same table position as
Apple's own `KeyLab 88.device/config.lua`), **the script demonstrably runs** — `LUA: Script matched
for USB ID 0x9516,0x4039` fires twice per launch, and `controller_initialize`, `controller_timer_trigger`,
and `controller_select_patch` all fire with correct live data (`print()` output landing in
`/tmp/lua.log`, e.g. `LUA: [probe] controller_select_patch patch=C07 Strings` on a real patch change
driven by System Events). This resolves "Dead end 2"'s open question above in the "does run" direction
— a third-party script in the user folder **does** get matched and invoked when the match method and
folder are both right.

What still doesn't work is getting anything back *out*. A throwaway probe
(`MainStage Devices/STUDIOLOGIC/SL.device/config.lua`, not committed — this section is its permanent
record) tried to send a marker SysEx (`F0 7D 53 4D 7E F7`) or, in later variants, a plain Note On, from
every lifecycle hook that can return `outport`, against a positive-control-verified receiver:

**Receivers, both confirmed working before trusting any negative result:**
- A throwaway CoreMIDI destination+source pair named exactly `SL MainStage` (`MIDIDestinationCreate`
  with a C-function-pointer `MIDIReadProc`, the pattern `MainStageEndpoint.swift` already uses
  successfully) — used instead of running the real app, to avoid two ports sharing that name.
- A multi-port sniffer connected to the SL88's own `CTRL`/`DAW`/`LINK` sources via
  `MIDIInputPortCreateWithBlock` (the block-based form — the C-function-pointer `MIDIInputPortCreate`
  variant silently receives nothing for *input* ports in this environment, unlike for destinations).
  Positive control: `Scripts/probe-sllink.swift` sent a real Identification Request and this sniffer's
  sibling logic (the script itself) captured the SL88's real `IDENTIFICATION APPROVED` /
  `LOGOUT CONFIRMATION` replies on the LINK source — proof the sniffing mechanism genuinely receives
  hardware traffic, not just a dead port.

**Results — every `outport` value tried delivered nothing, across 9+ send attempts each (both
lifecycle hooks and real, System-Events-driven patch changes):**

| `outport` value | Target | Delivered? |
|:---|:---|:---|
| `'SL MainStage'` | throwaway virtual destination (arbitrary, unrelated to the matched device) | **no** |
| `'LINK'` | SL88's own LINK port, `kMIDIPropertyName` spelling | **no** |
| `'SL LINK'` | SL88's own LINK port, `kMIDIPropertyDisplayName` spelling | **no** |
| `'CTRL'` | SL88's own CTRL port — literally owned by the exact device that matched | **no** |
| *(omitted)* | whatever MainStage would pick by default | **no** |

The `'CTRL'` and omitted-outport rows are the important ones: they rule out "outport only accepts
names belonging to the matched device" as the explanation, because even a port *unambiguously owned
by the matched device* got nothing, and even letting MainStage choose the destination itself got
nothing. Switching the payload from the marker SysEx to a bare Note On (`0x90 0x60 0x60`, on the
theory that MainStage's Lua↔MIDI bridge might special-case or drop unsolicited SysEx) made no
difference either. The `midi` field shape was also double-checked against Apple's own
`KeyLab 88.device/config.lua`: it must be a **flat** byte array (raw bytes and negative delay markers
concatenated in one table), not nested per-message — the first probe iteration had this wrong
(`midi = { MARKER }` instead of `midi = MARKER`); fixing it did not change the result, so it was not
the cause.

**Conclusion: THE QUESTION is answered — `outport = 'SL MainStage'` does NOT deliver the marker.**
But the broader finding is that *no* `outport` value delivers anything, including ports the matching
device itself owns. That means the blocker is not (or not only) "arbitrary destinations are
disallowed" — the return-value → CoreMIDI-send path appears non-functional in this MainStage version
for a device matched via `usb_vendor_id`/`usb_product_id`, independent of what `outport` names. This
is a **different and more fundamental** blocker than the one Architecture A vs. B was framed around,
and it forecloses naive Architecture B (script → SL88 LINK directly) exactly as much as Architecture A.

**What would settle it, since this remains genuinely inconclusive on the *why*:**
- Whether outbound send from a device script requires the device to additionally be accepted through
  MainStage's Control Surfaces setup UI (not just CoreMIDI-matched) — plausible given Logic/MainStage's
  history of a separate "Control Surface Setup" acceptance step, and not something a `usb_vendor_id`
  match or a background-launched, non-interactive MainStage process can satisfy. A menu item named
  "Settings" exists (`MainStage` menu) but did not open an accessible window under UI scripting in this
  session, so this could not be checked live within Phase 0's time budget.
  - Whether a script matched by **generic** manufacturer/model matching (like the reference Launchkey
  script, which has no `usb_vendor_id` at all) behaves differently from one matched by USB ID — the
  working public examples (Launchkey MK3, and Apple's own `KeyLab 88.device`, whose `usb_vendor_id`
  lines are commented out) may all be relying on the generic path for outbound delivery specifically,
  even though `controller_info()` accepts both.
- Whether `controller_midi_out` (control-surface *feedback*, requiring a mapped Smart Control in
  Layout mode) is the only hook MainStage actually flushes MIDI from, as opposed to the lifecycle hooks
  (`controller_initialize`/`controller_finalize`/`controller_timer_trigger`/`controller_select_patch`)
  used here and documented as carrying `outport` in the "Script API" table above — none of that table's
  sourcing has been independently re-verified against current MainStage behavior in this session, only
  against decompiled strings and the reference scripts' own usage.

**Given this, "Architecture A" cannot be marked as working.** Recommend treating the device-script
route as still blocked pending one of the above, and keeping the Program Change + `.concert`-parsing
fallback (noted above) as the live default rather than a fallback-of-last-resort.

## Where this stands — resume here

**Script execution: SOLVED.** With both v1 bugs fixed the script matches and runs, and MainStage
hands it real patch data:

```
LUA: Script matched for USB ID 0x9516,0x4039
LUA: [probe] controller_initialize appName=MainStage
LUA: [probe] controller_select_patch patch=C07 Strings
```

**Remaining blocker: outbound MIDI from the script never arrives.** No `outport` spelling delivered —
not our virtual destination `SL MainStage`, not `LINK`/`SL LINK`/`CTRL` (ports the matched device
owns), not omitting `outport`, not a plain Note On instead of SysEx. Verified against a
positive-control-checked receiver.

### Next thing to try (in progress)

**Re-test whether Lua's `io` library works.** The earlier "io is unavailable" note was recorded when
scripts never executed at all, so it proved nothing. If `io.open` works, the script can write the
patch list to a file the app watches (e.g. under `~/Library/Application Support/`), bypassing MIDI
entirely. Crude, but it only needs to carry a patch list a few times a second at most.

`config.lua` now has a minimal probe (`io_probe_write`, called from `controller_initialize` and
`controller_timer_trigger`): it `pcall`-wraps `io.open('/tmp/sl-mainstage-io-probe.log', 'a')` and
reports success/failure through `print()` either way, so the result lands in `/tmp/lua.log` under the
existing debugging recipe even if `io.open` errors instead of returning `nil`. Not yet run against
hardware — that's the next step. Remove the probe block once this is settled.

**Also found and fixed while wiring this up:** `Scripts/install-mainstage-script.sh` and this script's
own header comment still pointed at `~/Music/Audio Music Apps/MIDI Device Scripts/` — the *first*
Phase 0 finding, which the Phase 0 v2 correction above already established is Logic Pro's folder, not
MainStage's. Both now point at `MainStage Devices/`. This means every install since that correction
was written silently put the script where MainStage never reads it — worth knowing if any hardware
test between then and now looked like the script wasn't matching.

### Then, in order of promise

1. Whether MainStage requires the device to be accepted in a Control Surfaces / Layout setup step
   before it will flush script-returned MIDI.
2. Whether **generic** manufacturer/model matching behaves differently from USB-ID matching for
   outbound delivery — the known-working reference scripts (Launchkey MK3; Apple's `KeyLab 88.device`
   has `usb_vendor_id` commented out) rely on generic matching.
3. Whether only `controller_midi_out` (Smart Control feedback, needs a Layout-mode mapping) is ever
   actually flushed, as opposed to the lifecycle hooks used so far.

### Debugging recipe (don't rediscover this)

- `defaults write com.apple.mainstage3 LUA_DEBUG -bool true`, and set it back to `false` afterwards.
- `LUA:` output goes to **stdout only**: `/Applications/MainStage.app/Contents/MacOS/MainStage > /tmp/lua.log 2>&1 &`.
  `log show`/`log stream` show nothing.
- Script matching runs on **CoreMIDI device-add events**, not every launch. Unplug/replug the SL88 to
  force a rescan.
- Any MIDI sniffer must use `MIDIInputPortCreateWithBlock`. The C-function-pointer variant of
  `MIDIInputPortCreate` silently receives nothing and has already produced one false negative here.
- Reference working script: <https://github.com/mkuron/launchkey-mk3-mainstage>

### Fallback if the script route stays blocked

Program Change + `.concert` parsing. Concert structure is parseable: patch/song names are directory
names under `Concert.patch/`, ordering comes from each level's `nodes` array. Loses live sync.
