# sl-link-mainstage
Mainstage integration for SL88 MK2

## Installing the MainStage script

Run `./Scripts/install-mainstage-script.sh` to copy `MainStageScript/STUDIOLOGIC/SL.device` into
`~/Music/Audio Music Apps/MainStage Devices/STUDIOLOGIC/` (not "MIDI Device Scripts", which is
Logic Pro's folder of the same shape). It's idempotent, needs no admin rights, doesn't modify
MainStage.app, and survives MainStage updates. Re-run it after every `config.lua` change and after
a MainStage update that rescans its script folders, then quit and relaunch MainStage so it rescans
for the new script. Requires an SL88 MK2 connected over USB and MainStage; nothing else needs to be
running.

## Using it

Load a concert in MainStage, then select **MainStage** in the SL88's own APP list. The screen shows
the concert, set and patch, and follows patch changes made in MainStage. The Zoom button
(physically the button below Cancel) toggles between the patch list and the single-patch zoomed
view; a long press forces a full repaint.

If the app never appears in the APP list, quit and relaunch MainStage. For diagnostics,
`defaults write com.apple.mainstage3 LUA_DEBUG -bool true` routes the script's `print()` output to
MainStage's stdout — turn it back off afterward, since it measurably slows MainStage down.

## Setting up patch switching from the joystick ring

Turning the joystick's rotary ring selects patches. It works by injecting a **Bank Select** pair followed
by a **Program Change**, so MainStage needs to be told to accept those — until it is, the ring does
nothing at all. Verified against MainStage 4.3.1.

**1. Concert Settings → Attributes** (select the concert itself in the Patch List, then the Attributes
tab):

| Setting | Set it to | Why |
|:---|:---|:---|
| **Program Changes Device** | the SL88 — or **All** | The gate. MainStage only lets program changes select patches when they come from this source. Nothing works until this is right |
| **Program Changes Channel** | **16** — or All | The script sends on channel 16 |
| **Program Change Range** | **1–128** | The script assumes this numbering |
| **Reload Patches from saved state when receiving program change** | **off** (recommended) | Otherwise re-selecting the patch you are already on reloads it from its saved state mid-performance |

**2. Give the patches program change numbers.** From the Patch List's action menu, choose the command
that **resets program change numbers** — it numbers every non-skipped patch in Patch List order and rolls
into the next bank past 128. ⚠️ It **deletes any numbering you already have**, so check before running it
on a concert you numbered by hand.

**3. Optional, but makes it obvious:** turn on the Patch List option that **shows each patch's bank and
program change number** beside its name. The ring should then walk exactly down that column.

Then load the concert, select **MainStage** in the SL88's APP list, and turn the ring.

Notes:

- **Skipped patches are untested.** MainStage excludes them when numbering, but the script counts patches
  from the list MainStage hands it, and whether that list also omits them has not been checked. If you use
  skip and the ring lands one or two patches off, that is the likely cause — say so and it can be fixed.
- **Concerts longer than 128 patches work**: the numbering rolls into bank 2, 3 … and the script sends the
  matching bank before each program change.
- The ring sends **nothing but the patch selection** — no CC, and no popup on the SL88's screen, since the
  patch list is already the feedback. Its old CC 50 was removed in v3.0.0.
- If patch switching behaves oddly, check that **nothing else in the concert is mapped to patch selection**
  (a knob mapped to *current patch number*, or an assignment left over from experimenting) — two sources
  fighting looks like the ring skipping or sticking.

## Versioning

Current version: **2.7.0** (see the repo-root `VERSION` file; also stamped into
`config.lua`'s `SCRIPT_VERSION` and printed on every `controller_initialize`, so `/tmp/lua.log`
shows which build MainStage actually has loaded). Semantic versioning:

- **patch** — fixes and tuning, no mapping or install-layout change
- **minor** — new features or screens, backwards-compatible
- **major** — anything that breaks an existing MainStage MIDI-Learn mapping (the CC map in
  `config.lua`) or changes the install layout

The major bump matters in practice: the 34 CC assignments are MIDI-Learned by hand in MainStage, so
renumbering one silently breaks a working rig.

## Releases

Releases are published automatically whenever a change to the device script (`MainStageScript/**`)
lands on `main`. Grab the zip from the [Releases page](../../releases), unzip it, and run
`./Scripts/install-mainstage-script.sh` from the unzipped folder.

After unzipping, `SL.device` shows up in Finder as a single file rather than a folder — that's
expected, not a broken download. MainStage registers `.device` as a package type, so Finder
presents it as one item; it's still a real directory containing `config.lua` (the nested
`STUDIOLOGIC/SL.device` layout matches the manufacturer/model `controller_info()` reports).
Right-click and choose **Show Package Contents** to look inside from Finder, or just treat it as a
normal directory from the terminal. Either way, nothing needs to be unpacked by hand —
`install-mainstage-script.sh` copies the whole bundle to where MainStage expects it.

## Documentation

- [`docs/implementing-sl-link.md`](docs/implementing-sl-link.md) — reusable guide to implementing the
  SL Link protocol from spec in Lua or Swift, including where real hardware disagrees with the spec.
- [`docs/mainstage-device-scripts.md`](docs/mainstage-device-scripts.md) — practical guide to writing
  MainStage Lua device scripts for any controller: matching, callbacks, sending MIDI, and the
  undocumented constraints.
- [`docs/mainstage-integration.md`](docs/mainstage-integration.md) — status of the SL88 ↔ MainStage
  integration; the full investigation log is archived under `docs/archive/`.
- [`docs/full-functionality-plan.md`](docs/full-functionality-plan.md) — plan for the full SL88 ↔
  MainStage feature set (draft).

## Sponsoring

If you want to sponsor my initiative, you can [add a donation](https://buy.stripe.com/00wfZa6n6bcufu5apXebu00).

## Licence

Licensed under the Apache License, Version 2.0 — see [`LICENSE`](LICENSE) for the full text.
