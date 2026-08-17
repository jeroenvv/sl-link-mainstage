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
| `~/Music/Audio Music Apps/MIDI Device Scripts/` | **yes** — use this one |
| `~/Music/Audio Music Apps/MainStage Devices/` | yes |
| `~/Music/Audio Music Apps/MIDI Device Profiles/` | yes |
| `~/Library/Application Support/MIDI Device Scripts/` | no |
| `~/Library/Application Support/MainStage/MIDI Device Scripts/` | no |

`~/Music/Audio Music Apps/` is the shared Logic/MainStage user content root, and those three
subfolder names appear adjacent to each other in `LogicMainStage`, next to `Shared`.

This is the good outcome: installing a script needs no admin rights, no modification of
`MainStage.app`, and survives MainStage updates.

### Things that did not work, so nobody repeats them

- **`LUA_DEBUG` could not be switched on from outside.** The string exists in `LogicMainStage` and
  guards useful log lines (`LUA: Available scripts:`, the match/no-match lines above), but setting it
  as an environment variable and as an `NSUserDefaults` argument both produced no output, and nothing
  appears in `os_log` or `~/DebugLog`. If someone finds the real switch it would make debugging much
  easier.
- **Lua's `io` library appears to be unavailable.** A probe script calling `io.open` at parse time
  wrote nothing from any location, including folders proven scanned by their atime. Don't plan on
  file-based logging from inside a script.

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
