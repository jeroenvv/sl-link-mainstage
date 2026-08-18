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

> **SUPERSEDED (2026-08-19) — jump to "SOLVED: outbound MIDI works" near the end of this file.**
> The "remaining blocker" below turned out to be a wrong `outport` string: MainStage wants the short
> `kMIDIPropertyName` (`'LINK'`), not the display name (`'SL LINK'`). Outbound *and* inbound MIDI both
> work from the script. The sections between here and there are kept as the investigation record —
> several of their negative results were measured with a sniffer that could not observe the direction
> under test, and are explicitly corrected later in this file. Read the last two sections first.

**Script execution: SOLVED.** With both v1 bugs fixed the script matches and runs, and MainStage
hands it real patch data:

```
LUA: Script matched for USB ID 0x9516,0x4039
LUA: [probe] controller_initialize appName=MainStage
LUA: [probe] controller_select_patch patch=C07 Strings
```

**Believed at the time — since disproven:** that outbound MIDI from the script never arrives, for any
`outport` spelling. That conclusion came from a sniffer watching only CoreMIDI *sources* while
`outport` addresses a *destination*; see the correction and solution sections at the end.

### Pivot (2026-08-18): matching moved from the virtual endpoint to the real SL88

The first attempt at the "next thing to try" above put an `io.open` probe on the *shipped*
`config.lua` — which matched **generically** against the app's own virtual endpoint (manufacturer `SL
Link Bridge`). That never had a chance to fire: the "Virtual device registration" section above already
established that a bare `MIDISourceCreate`/`MIDIDestinationCreate` endpoint has no `MIDIDeviceRef`
parent, and MainStage never binds `config.lua` to one. Testing on hardware correctly came back with
nothing in either `/tmp/lua.log` or the probe file — not a new negative finding, just confirmation of
the already-known dead end, applied to the wrong script by mistake.

The only match method ever confirmed to actually invoke a script is `usb_vendor_id`/`usb_product_id`
against the **real SL88's** own USB IDs (`0x9516`/`0x4039`), from the Phase 0 v2 spike. `config.lua`
now matches that way instead — it lives at `MainStageScript/STUDIOLOGIC/SL.device/config.lua` (moved
from `SL MainStage.device/`) and `controller_info()` reports the SL88's own identity
(`manufacturer='STUDIOLOGIC', model='SL'`) plus `usb_vendor_id = 38166, usb_product_id = 16441`
(decimal, matching the field's convention in Apple's bundled `KeyLab 88.device/config.lua`).
`Scripts/install-mainstage-script.sh` was updated to match (`STUDIOLOGIC/SL.device`, still installed
under `MainStage Devices/`).

**Consequence:** the script now occupies the SL88's own device-script slot instead of a separate
identity. `MainStageProtocol.encodeSelection`/`MainStageEndpoint.sendSelection` (the app→MainStage
patch-selection direction, sent from the app's *virtual* endpoint) were already flagged "unconfirmed"
before this pivot; they're now less likely to work than before, since patchselector's Bank
Select/Program Change handling is tied to whichever device MainStage matched the script to, which is
no longer the virtual endpoint at all. Out of scope for the current (inbound, MainStage→app) work —
noted here so nobody is surprised when testing selection-send later.

**Transport also switched, in the same change:** given Phase 0 v2 exhaustively found no `outport`
value ever delivers, the lifecycle hooks (`controller_initialize`/`controller_finalize`/
`controller_timer_trigger`/`controller_select_patch`) no longer attempt a MIDI send at all — they call
a new `write_frame(path, event)` helper that `pcall`-wraps `io.open(path, 'wb')` and writes the exact
same `F0...F7`-shaped byte sequence straight to one of two files (`/tmp/sl-mainstage-bridge-status.bin`
for Hello/Heartbeat/Goodbye, `/tmp/sl-mainstage-bridge-patchlist.bin` for the patch list — each always
fully overwritten, not appended, since only the latest state matters). Every write reports
success/failure through `print()`, so this doubles as the `io`-library re-test the earlier probe was
meant to be — no separate probe script needed now that the *matching* script itself is the one
confirmed to run.

**Verified without hardware, as far as that goes:** `luac -p` syntax-checks clean; a local Lua 5.5
harness (`brew install lua`) drove every callback (`controller_info`, `controller_initialize`,
`controller_timer_trigger`, `controller_select_patch` including its unchanged-dump dedup,
`controller_finalize`, `controller_midi_in`'s Program-Change swallow) and confirmed both files get
written with the right bytes; a throwaway Swift harness then fed those exact file bytes through the
real `MainStageProtocol.decode` and got back correctly-typed `.hello`/`.goodbye`/`.patchList` values —
so the Lua-write ↔ Swift-decode round trip is byte-for-byte confirmed. **What's not verified is
anything requiring MainStage or the SL88 itself**: whether `usb_vendor_id` matching still fires now
that the identity fields also changed, whether `io.open` truly succeeds inside MainStage's Lua sandbox
(only ever tested outside it), and — a newly-identified concern, see below — whether the app can even
read the file once written.

### Open question before the app side can be wired up: can a sandboxed app read `/tmp`?

`SL-Link-Mainstage` runs with `ENABLE_APP_SANDBOX = YES` and no filesystem entitlement beyond the
default (see CLAUDE.md, and the "no MIDI-related entitlement present or added" note in the "Virtual
device registration" section above). App Sandbox restricts file reads to the app's own container plus
a short allow-list of special-cased locations; arbitrary absolute paths like `/tmp/sl-mainstage-
bridge-status.bin` are very likely outside that list, meaning the app may not be able to read the file
MainStage's Lua process just wrote, regardless of whether `io.open` itself works. The same problem
would apply to `~/Library/Application Support/...`: the *sandboxed* app's view of that path is
redirected into its own container, which is not the same real filesystem location an *unsandboxed*
process like MainStage would write to. Untested — needs either confirming the default sandbox somehow
permits this, or adding a read entitlement (most likely `com.apple.security.temporary-exception.files.
absolute-path.read-only` scoped to the two bridge files) before the Swift-side file reader is worth
writing. Flagged rather than resolved unilaterally, since adding a new entitlement is a real project
decision, not a speculative one to make alone.

### Resolved on real hardware (2026-08-18): `io` is not available either — both transports are dead

The sandbox-read question above got resolved (scoped `temporary-exception` entitlement, working - see
the entitlements file's own comment for the `/private/tmp` vs `/tmp` gotcha), so the Swift-side file
poller (`MainStageEndpoint.pollBridgeFiles`) got built and verified: a manually-written pair of bridge
files was correctly read, decoded, delivered through `onInbound`, and (with a real SL88 in `.active`
session state) actually repainted the title bar on the physical keyboard's screen
(`SLLinkDemoScreen.showMainStageStatus`, confirmed visually by the user) - so the **app-side half of
the file transport works end to end**.

Then the same script was installed for real (`Scripts/install-mainstage-script.sh`) and MainStage
relaunched with `LUA_DEBUG` on, stdout to `/tmp/lua.log`, against a real SL88 and a real loaded
concert. Two things came back:

```
LUA: Script matched for USB ID 0x9516,0x4039
[bridge] pcall error writing /tmp/sl-mainstage-bridge-status.bin: [string "?"]:183: attempt to index global 'io' (a nil value)
```

1. **USB-ID matching against the real SL88 is confirmed solid** - fires immediately on launch (no
   unplug/replug needed this time; the device was already connected), twice per launch as before.
2. **`io` is not merely restricted - the global doesn't exist in MainStage's Lua sandbox at all.**
   `attempt to index global 'io' (a nil value)` is a stricter failure than `io.open` returning `nil`;
   the earlier pre-Phase-0-v2 "io is unavailable" finding, which this session's earlier work set out to
   overturn on the theory that it was recorded before any script was confirmed to run, turns out to
   have been *right* after all - just for a different reason than "unproven." Every lifecycle hook kept
   firing normally afterward (`controller_initialize`/`controller_timer_trigger`/`controller_select_patch`
   all still ran - both the status and patchlist write attempts recurred on their normal cadence) because
   every call site is `pcall`-wrapped; without that, this would have been a hard Lua error on every single
   invocation instead of a clean, visible log line. MainStage itself never crashed or hiccuped.

**Both candidate transports for Lua -> app data are now confirmed dead on real hardware**: MIDI
`outport` (Phase 0 v2, exhaustive) and `io.open` (this section). Nothing else in the shipped Lua API
(see the Script API table near the top of this file) offers a third way to get bytes out of a device
script. The file-write code in `config.lua`/`MainStageEndpoint.swift`'s poller is harmless (fails
silently via `pcall`, costs nothing) but is now dead weight - kept in place pending a decision on
whether to strip it, rather than removed reflexively, since the app-side half (file read -> decode ->
screen paint) is itself a real, working, reusable piece if a third transport ever surfaces.

**Neither transport has worked yet for the MainStage -> app direction**, not just one implementation of
one of them. The only thing device scripts still plausibly offer this project is the other direction
(app -> MainStage patch selection via `patchselector`'s Bank Select/Program Change), which was already
flagged unconfirmed and now doubly so post-pivot (see the "Pivot" section above) - and even that has no
dependency on `outport`/`io` since it's the device (this script) declaring `patchselector = true` and
MainStage's own core, not the script, doing the receiving.

**Next decision: pursue the documented fallback while this stays open.** Program Change + `.concert`
parsing - noted throughout this file as the fallback-of-last-resort - is the only other live option for the
MainStage -> app direction. Concert structure is parseable: patch/song names are directory names under
`Concert.patch/`, ordering comes from each level's `nodes` array. Loses live sync (the app would need
to re-parse on some trigger, not get pushed updates) and needs Program Change numbers to be derivable
or MainStage's "Reset Program Numbers" to be usable, neither confirmed. Not started.

## MIDI outbound, round 2 — matching-method comparison against all 98 bundled scripts (2026-08-18)

Revisited after the `io` dead end above, prompted by a direct question: does the *matching method*
itself affect whether outbound MIDI is ever flushed, independent of `outport`'s value? All of Phase 0
v2's `outport` testing happened under `usb_vendor_id` matching (the only method then known to make the
script run at all, back when the alternative was a dead virtual endpoint). That was never disentangled
from the possibility that `usb_vendor_id` matching itself disables outbound delivery, regardless of
`outport`.

**Comparison method:** grepped all 98 scripts Apple ships under `MIDI Device Scripts/` for `outport`
usage and for an active (non-commented) `usb_vendor_id` line. Result, with zero counterexamples in
either direction:

- Every script that sends unsolicited MIDI from a lifecycle hook (`controller_initialize`/
  `controller_select_patch`/`controller_timer_trigger`) - VAX77, KeyLab 88, Launch Control, MPK249, and
  27 others - matches **generically** (manufacturer/model only).
- Exactly 3 scripts in the whole bundle have an active `usb_vendor_id` (the M-Audio Axiom/Oxygen
  scripts). **None of the 3 ever call a lifecycle hook or send unsolicited MIDI** - their one `{midi=
  ...}` return is a synchronous reply inside `controller_midi_in`, echoing a just-received inbound
  event, not a spontaneous send.

Also clarified what `outport` actually names in every working example: never an arbitrary third-party
destination. VAX77 (single port) omits `outport` entirely and lets MainStage route to its own device's
port; KeyLab 88 sets `outport='KeyLab 88'`, its own `model` value; MPK249 (multi-port hardware) uses
`outport='Port A'`, a named sub-port of its own hardware. Always the matched device's own port, by name
or by omission - never someone else's.

**This matters here because the real SL88, unlike the abandoned virtual endpoint, already has a proper
`MIDIDeviceRef`/`MIDIEntityRef`** (see "Virtual device registration" above) - so generic matching
against it is a genuinely new, untested configuration, not a repeat of that dead end.

### Retested on real hardware: still nothing, and one new destabilizing finding

`config.lua` switched to generic matching (`usb_vendor_id`/`usb_product_id` commented out, mirroring
Apple's own `KeyLab 88.device` convention) and retested through three rounds, each installed via
`Scripts/install-mainstage-script.sh` and verified with a MainStage quit/relaunch (confirmed sufficient
to force a rescan - no physical unplug/replug needed when the device was already connected):

1. **`outport='SL MainStage'`** (the app's own virtual destination, already fully wired to decode this
   exact Hello frame via `MainStageEndpoint`'s dormant CoreMIDI destination) - nothing arrived; the
   app's dev console showed no Hello.
2. **Omitted entirely** (the exact VAX77 pattern: bare `{midi={event}}`, no `outport` key) - watched
   with a new multi-port sniffer, `Scripts/sniff-all-sl-ports.swift` (extends `sniff.swift`'s
   `MIDIInputPortCreateWithBlock` pattern to all four `SL *`-named sources at once, since which port a
   bare return would land on wasn't known in advance) - nothing arrived on any of `SL CTRL`/`SL DAW`/
   `SL LINK`/`SL MainStage`.
3. **A sweep of `outport='CTRL'`/`'DAW'`/`'LINK'`/`'SL'`** (the SL88's own real port names, plus its own
   `model` value), one candidate per `controller_timer_trigger` tick (temporarily sped up to 1s) so one
   relaunch could cover all four instead of four separate ones. Only the first candidate (`'CTRL'`) was
   ever tried: `controller_timer_trigger` fired once, logged `outport sweep: trying "CTRL"`, and then
   **never fired again** - not on the same run, not after 15+ more seconds - while MainStage itself
   stayed fully alive and responsive (confirmed via `ps`, still consuming CPU normally). No error
   surfaced in `/tmp/lua.log` beyond the (harmless, `pcall`-caught) `io` failure already known. This is
   qualitatively different from rounds 1-2, which failed silently but left the script's timer running
   normally afterward - `outport='CTRL'` appears to have gotten MainStage to quietly deregister the
   script's periodic callback going forward, without any corresponding surfaced error. Untested whether
   `'DAW'`/`'LINK'`/`'SL'` behave the same way, since continuing the sweep past the point where the
   timer had already stopped would have taught nothing new, and repeated relaunching to isolate it
   further risked destabilizing the user's live MainStage session further for diminishing information.
   `config.lua` was reverted to the safe, outbound-attempt-free state (file writes only, `io` already
   known dead) and MainStage relaunched clean to confirm normal operation resumed.

**Matching method alone doesn't explain the blocker.** Generic matching against the real SL88 - the
configuration used by every working reference example - still delivers nothing for any `outport`
spelling tried, exactly like `usb_vendor_id` matching did in Phase 0 v2. Combined with the `io` finding
above, this rules out the last major variable tried so far for the MainStage -> app direction via
device scripts - not a sign nothing will work, just that the right combination hasn't been found yet.
The `'CTRL'` timer-deregistration behavior is worth keeping in mind if this is ever revisited - it
suggests MainStage's Lua bridge treats *some* invalid `outport` values as more than a no-op, and a full
sweep (ideally against a disposable MainStage/concert, not a session with real user content open) would
be needed to characterize which ones and why before trusting any of them.

### Round 4 — retested `CTRL` patiently, ruling out the "test ran too fast" objection

Round 3's single `'CTRL'` attempt happened only ~15s after a MainStage relaunch, while a real
orchestral concert (`Joseph key2.concert`, Vienna Instruments) was still loading - a fair objection
(Jeroen's) is that MainStage might simply have been too busy to service the script's timer, not that
`'CTRL'` itself broke anything, and that `CTRL` (the SL88's default "Controller" MIDI mode - `DAW` is
transport-button-only, `LINK` is this project's own unrelated protocol) was the semantically correct
target to focus on rather than a blind sweep. Retested accordingly: `controller_timer_trigger` sending
*only* to `outport='CTRL'`, at its normal 2s cadence (not round 3's sped-up 1s sweep, so it wouldn't
compete with instrument loading), watched continuously via `Scripts/sniff-all-sl-ports.swift` for the
full loading period rather than a fixed short window - confirmed patiently, checking MainStage's own
state directly rather than guessing from timing, before drawing any conclusion.

**Same result.** Even ~100+ seconds in, with MainStage confirmed fully loaded and CPU usage settled
(down from ~40% to ~21%), the log still showed exactly one `CTRL retest: attempt seq=1` - never
seq=2 or beyond, though the 2s cadence should have produced roughly 50 by that point - and nothing
arrived on any of the four sniffed ports. So round 3's finding wasn't a loading-noise artifact: the
patient retest reproduces it exactly. `outport='CTRL'` still doesn't deliver, and still appears to stop
MainStage from calling the script's timer again after that first attempt. `config.lua` reverted to the
safe, outbound-attempt-free state again afterward and MainStage relaunched clean.

`'DAW'`/`'LINK'`/`'SL'` remain untested with this same patient methodology (round 3 never got past
`'CTRL'` before the timer stopped). If revisited, test one at a time, patiently, the same way.

### Rounds 5-7 — DAW, LINK, and SL (model name): identical result, sweep complete

Continued the same one-candidate-at-a-time, patient methodology (normal `HEARTBEAT_MS` cadence, wait
for Jeroen to confirm MainStage fully loaded before checking results - not a guessed timeout) through
the three remaining candidates: `outport='DAW'`, `outport='LINK'`, and `outport='SL'` (the device's own
`model` value, the KeyLab-88-style convention for a device that doesn't name a specific sub-port).

**All three reproduce round 4's `'CTRL'` result exactly**: `controller_timer_trigger` fires exactly
once (`attempt seq=1`), nothing arrives on any of the four sniffed ports, and the timer then stops
firing entirely - confirmed each time by waiting a further ~45s past Jeroen's own "ready now"
confirmation, with MainStage staying alive and responsive throughout (`ps` showing normal, changing CPU
usage each time, never hung).

**The sweep is now exhaustive and conclusive.** Every plausible `outport` value has been tried, patiently,
against the real SL88 with generic matching:

| `outport` | Round | Result |
|:---|:---|:---|
| `'SL MainStage'` (app's own virtual destination) | Round 2, this doc | nothing; timer kept running normally afterward |
| omitted (VAX77's own pattern) | Round 2, this doc | nothing; timer kept running normally afterward |
| `'CTRL'` | Round 4 | nothing; timer stopped after one attempt |
| `'DAW'` | Round 5 | nothing; timer stopped after one attempt |
| `'LINK'` | Round 6 | nothing; timer stopped after one attempt |
| `'SL'` (own model name) | Round 7 | nothing; timer stopped after one attempt |

(Plus, from Phase 0 v2, the same negative result for all of the above under `usb_vendor_id` matching
instead of generic.) Nothing left to try that has a plausible basis in how any of the 98 bundled
reference scripts use `outport` - this project has now covered every pattern they use, and several they
don't.

**Working theory for the two different failure signatures**, not yet confirmed: the four *real* port
names (`CTRL`/`DAW`/`LINK`/`SL`, i.e. anything MainStage might recognize as actually belonging to the
matched SL88) trigger something that deregisters the script's timer, while names MainStage doesn't
recognize as belonging to any device (`'SL MainStage'`, an unrelated virtual endpoint) or omitting
`outport` entirely just get silently dropped with no side effect. If true, that would mean MainStage
*is* attempting to route to a real, recognized port in the CTRL/DAW/LINK/SL cases specifically, and
something in that routing path throws/faults in a way that also kills the periodic callback - as
opposed to never resolving a destination at all in the other two cases. Untested and possibly
untestable without instrumenting MainStage itself (e.g. a debugger, or `dtrace`/`fs_usage`-style
observation of what happens between the Lua return and the timer's next scheduled fire) - offered as
the most concrete remaining thread if this is ever revisited, not as something to chase further right
now.

**No working approach found yet for the device-script route on the MainStage -> app direction.**
Matching method, `outport` value, and the `io` library have all been ruled out as fixable with the
ideas tried so far. The fallback (Program Change + `.concert` parsing, noted throughout this file) is
the other live option in the meantime.

## MIDI outbound, round 3 — checked against a real working reference package (2026-08-18)

Jeroen pointed at a second, more concrete source beyond the 98 bundled scripts:
`https://github.com/mkuron/launchkey-mk3-mainstage`, specifically its released installer,
`mainstage-devices.pkg`. Downloaded and inspected with `pkgutil --expand` (extracts the payload without
running any installer script or actually installing anything - safe, read-only). Confirms
`install-location="Music/Audio Music Apps/MainStage Devices"`, matching this project's own install
path, and contains real, actively-maintained `config.lua` files for five Launchkey MK3 variants.

**This script demonstrably sends unsolicited MIDI from `controller_initialize` and
`controller_select_patch`** (`return {midi={...}, outport=DAW_IN}`, and `controller_midi_out` too) -
real, working, first-hand proof the mechanism this project needs is not fundamentally broken in
current MainStage, for *some* device. Structural details worth noting:

- `outport` targets `DAW_IN = 'LKMK3 DAW In'` - a **full, unabbreviated CoreMIDI display name**, not a
  short form. This project's rounds 4-7 above only ever tried the SL88's short `kMIDIPropertyName`
  forms (`'CTRL'`/`'DAW'`/`'LINK'`), never the full `kMIDIPropertyDisplayName` forms
  (`'SL CTRL'`/`'SL DAW'`/`'SL LINK'`) under generic matching - genuinely untested.
- Every item in `controller_info()`'s `items` table that participates in bidirectional communication
  declares its own `inport`/`outport` (`DAW_OUT`/`DAW_IN`) - unlike this project's `items`, none of
  which reference any port at all. Raised a real hypothesis: MainStage might only honor an `outport` in
  a lifecycle-hook return if that port was already "announced" via some item's own `inport`/`outport`.
- This script does **not** set `patchselector` at all - unlike this project's `config.lua`. Weaker lead
  (VAX77 does set `patchselector = true` and is presumed to work), but cheap to rule out.

### Retested: rounds 8-12, same result

Continued the same patient, one-variable-at-a-time methodology, each confirmed against Jeroen's own
"ready now" and each further checked ~45s past that before concluding:

| Round | Change | Result |
|:---|:---|:---|
| 8 | `outport='SL CTRL'` (full display name) | nothing; timer stopped after one attempt |
| 9 | `outport='SL DAW'` (full display name) | nothing; timer stopped after one attempt |
| 10 | `outport='SL LINK'` (full display name) | nothing; timer stopped after one attempt |
| 11 | `outport='SL DAW'`, pre-announced via a real item's own `outport` field | nothing; timer stopped after one attempt |
| 12 | Same as 11, plus `patchselector` temporarily disabled | nothing; timer stopped after one attempt |

Every structural difference identified by close comparison with the real working reference - full
display names, item-level port announcement, `patchselector` - was tested, individually, patiently,
against real hardware. None changed the outcome. `config.lua` reverted to its safe, outbound-attempt-
free committed state after each round; MainStage relaunched clean and confirmed healthy throughout.

**Every lever available from within `config.lua` has been tried, without finding a working combination
yet.** Matching method, every plausible `outport` spelling, item-level port declaration,
`patchselector` - all tested individually and patiently against real hardware, mirroring a
confirmed-working reference in every dimension identifiable from its source. A plausible next thread,
not yet tried: the remaining difference between this project's SL88 script and the Launchkey MK3
reference may be something below the Lua layer - possibly in how the two devices' USB-MIDI interface
descriptors present themselves (Novation's DAW port pair may be a firmware-level construct MainStage's
native code specifically recognizes as DAW-capable, independent of what CoreMIDI happens to name the
port). Following that would mean instrumenting MainStage itself (a debugger, or `dtrace`/`fs_usage`-
style observation) rather than editing the script further - a materially different kind of effort, not
attempted here, not a closed door. **Still true**: the device-script route hasn't produced a working
approach for the MainStage -> app direction yet; `.concert` parsing is the other live option in the
meantime.

## SOLVED (2026-08-19): outbound MIDI works — `outport` needs the SHORT port name

**The whole outbound blocker was the `outport` string.** MainStage wants the short
`kMIDIPropertyName` (`'LINK'`), not the `kMIDIPropertyDisplayName` (`'SL LINK'`) this project had been
using everywhere.

MainStage says so itself, and we'd been looking straight past it: the `portName` argument it passes to
`controller_midi_in` is **`LINK`**. Once `controller_midi_in` was instrumented to log its arguments,
the mismatch was obvious.

**Proof.** With `outport='LINK'`, an SL Link Identification Request sent from the script drew real
replies from the SL88, captured on the LINK source with the helper app closed:

```
F0 00 20 1A 16 03 6D 7F 01 01 01 02 01 F7      IDENTIFICATION APPROVED (fw 1.1.2, model SL88)
F0 00 20 1A 16 03 6D 7F 02 00 01 01 02 01 F7   IDENTIFICATION REJECTED (reason 0x00, DeviceID taken)
```

`03 6D` is the script's own `LuaProbe` DeviceID. The rejection is the *second* script instance -
MainStage loads the script once per matched USB-MIDI interface, and both hardcoded the same instance
byte. Any real implementation needs a per-instance DeviceID or a retry on rejection.

**Inbound works too**: `controller_midi_in` receives the SL88's traffic (38 events captured while
playing), and the VAX77 reference confirms SysEx is delivered there as well. So the script can both
send and receive SL Link directly - no helper app required for the keyboard-facing side.

### Why this took so long — the two testing flaws that hid it

Worth recording, because both produced confident wrong conclusions:

1. **The sniffer watched the wrong direction** (see the correction section below). `outport` names a
   *destination*; the sniffer only ever enumerated *sources*. So `'SL LINK'` and `'LINK'` looked
   identical - both "silent" - when in fact one was wrong-name-silently-dropped and the other was
   never actually retried under observable conditions. Round 6 did try `'LINK'`, but with the
   unobservable setup, so its negative was meaningless.
2. **No positive control until late.** Once an identification round-trip (request -> keyboard replies
   on a source) was used, with `Scripts/probe-sllink.swift` proving the chain end-to-end first, the
   answer appeared within two attempts.

The general lesson: test with a signal you have independently proven you can observe, before trusting
any negative result.

## Correction (2026-08-19): rounds 4-10 were UNOBSERVED, not negative

Re-examining the method after Jeroen asked what we'd missed versus the reference package, two of the
conclusions above don't hold up. Both are corrections to *evidence quality*, not new failures:

**1. The sniffer was watching the wrong direction.** `Scripts/sniff-all-sl-ports.swift` enumerates
`MIDIGetSource` only - CoreMIDI **sources** (device -> host). But `outport` names a **destination**
(host -> into device). The SL88 exposes `SL CTRL`/`SL DAW`/`SL LINK` as *both*, so when MainStage sent
to `'SL LINK'`, the bytes went into the keyboard where nothing was listening. The reference package
makes this obvious in hindsight: `DAW_IN = 'LKMK3 DAW In'` - "In" is the device's input, i.e. a
destination. **Rounds 4-10's "nothing arrived" results prove nothing** and have been re-run properly
below. (The sniffer now documents this limitation in its own header, and was additionally rewritten to
use one input port per source rather than passing a Swift `String` through `srcConnRefCon` and
`load(as:)`-ing it in a real-time callback, which was never sound.)

**2. "`outport='CTRL'` stops the script's timer" was unfounded.** Every round that showed a single
`seq=1` returned `{midi=...}` from `controller_timer_trigger`; every "baseline" returned `nil`. And
`write_frame` logs no sequence number, so a baseline's repeated status writes are equally explained by
several script *instances* each running `controller_initialize` once (MainStage loads the script once
per matched USB-MIDI interface). No baseline ever demonstrated the timer ticking repeatedly, so there
was never a contrast to attribute to `outport`. Disregard that claim and the theory built on it.

### Re-run properly: an observable round-trip, with a positive control

The fix is to send something the keyboard *answers*, so the reply comes back on a source where the
sniffer can legitimately see it. `controller_initialize` now sends a real **SL Link Identification
Request** (`F0 00 20 1A 16 03 6D 7F 00 "LuaProbe" 00 F7`, byte-for-byte verified against
`SLLinkEncoder.identificationRequest`, with an instance byte distinct from the app's own) to
`outport='SL LINK'`.

**Positive control, run twice** (`Scripts/probe-sllink.swift` sending the identical message shape from
an ordinary process): the SL88 answered in ~2 ms both times, and the sniffer independently captured it -
`F0 00 20 1A 16 03 2A 7F 01 01 01 02 01 F7` (IDENTIFICATION APPROVED, fw 1.1.2, SL88). Confirmed both
with the app running and with the app closed, so the observation chain is sound in either state.

**Result: still nothing from Lua.** The probe fired (twice, once per script instance, logged), and no
reply ever appeared. Tested under progressively cleaner conditions:

| Condition | Reply? |
|:---|:---|
| Generic matching, fictional `items`, app running | no |
| Real `items` (see below) declaring `inport`/`outport` on `SL LINK`, app running | no |
| Same, with the SL Link app **quit** so nothing else held the LINK port | no |

That last row matters: Jeroen pointed out the app was still bound to SL Link and could be influencing
things. With it closed - and the keyboard re-confirmed responsive in that exact state - the answer is
unchanged. **This is the first properly controlled outbound negative in the whole investigation.**

### Also corrected: the `items` were fiction, and CTRL is not the SL88's controller port

The `items` table declared invented CC numbers (`0xBF 0x50`-`0x5C`) that the SL88 never transmits, with
no `inport`/`outport` at all - unlike the reference, which declares real controls on real ports and so
gives MainStage an actual bidirectional surface to bind. Rewrote them from a live capture (one input
port per source, playing the keyboard and moving both sticks):

| Control | Bytes | Port |
|:---|:---|:---|
| Notes | `0x90`/`0x80` | `SL LINK` |
| Pitch bend | `0xE0` | `SL LINK` |
| Modulation | `0xB0 0x01` | `SL LINK` |
| Second stick | `0xB0 0x10` | `SL LINK` |
| Sustain | `0xB0 0x40` | `SL LINK` |

**All 138 captured events arrived on `SL LINK`; zero on `SL CTRL`.** That contradicts this document's
own assumption (and the "CTRL = controller mode" reasoning behind round 4). Caveat: this capture was
taken while the app held an active SL Link session, which is plausibly *why* the keyboard routes its
playing MIDI there - whether it reverts to CTRL with no session open is **not** tested.

Declaring those real items changed nothing about outbound delivery, so the "MainStage only opens the
outbound path once a real surface is bound" theory is not supported either - though note the surface
still may never have gone truly live, since nothing verified MainStage was actually *receiving* those
declared controls.

**Where that leaves it**: a script-returned `{midi=...}` has still never been observed to leave
MainStage, but the evidence base is now much smaller and much sounder than the round-by-round table
above suggests. Still no working approach found - not a demonstration that none exists.

**One process note worth keeping**: earlier rounds in this session judged results against a fixed
wait after a MainStage relaunch. Jeroen corrected this - `Joseph key2.concert`'s real orchestral
instruments (Vienna Instruments MIDI) take a long, variable time to finish loading, so a fixed timeout
confounds "the thing being tested failed" with "MainStage was still busy." Every round from 4 onward
instead waited for Jeroen's own live confirmation that MainStage had actually finished loading before
judging anything - see the "mainstage-hardware-test-pacing" memory for the standing version of this.

### Debugging recipe (don't rediscover this)

- `defaults write com.apple.mainstage3 LUA_DEBUG -bool true`, and set it back to `false` afterwards.
- `LUA:` output goes to **stdout only**: `/Applications/MainStage.app/Contents/MacOS/MainStage > /tmp/lua.log 2>&1 &`.
  `log show`/`log stream` show nothing.
- Script matching runs on **CoreMIDI device-add events**. A full MainStage quit + relaunch forces a
  rescan on its own (confirmed 2026-08-18, repeatedly) - unplug/replug is only needed if MainStage stays
  running throughout.
- Any MIDI sniffer must use `MIDIInputPortCreateWithBlock`. The C-function-pointer variant of
  `MIDIInputPortCreate` silently receives nothing and has already produced one false negative here.
- To watch multiple ports at once without knowing in advance which one matters, use
  `Scripts/sniff-all-sl-ports.swift` rather than writing a new single-port sniffer each time.
- Quitting a live MainStage session to test a script edit is disruptive if real user content (an open
  concert) is involved - confirm before doing it, same as any other action affecting a shared/running
  process. `osascript -e 'tell application "MainStage" to quit'` works reliably; a plain `open -a
  MainStage` afterward relaunches it (add stdout redirection first if `LUA_DEBUG` output is needed).
- Reference working script: <https://github.com/mkuron/launchkey-mk3-mainstage>

### Fallback if the script route stays blocked

Program Change + `.concert` parsing. Concert structure is parseable: patch/song names are directory
names under `Concert.patch/`, ordering comes from each level's `nodes` array. Loses live sync.
