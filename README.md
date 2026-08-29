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

## Versioning

Current version: **1.0.0** (see the repo-root `VERSION` file; also stamped into
`config.lua`'s `SCRIPT_VERSION` and printed on every `controller_initialize`, so `/tmp/lua.log`
shows which build MainStage actually has loaded). Semantic versioning:

- **patch** — fixes and tuning, no mapping or install-layout change
- **minor** — new features or screens, backwards-compatible
- **major** — anything that breaks an existing MainStage MIDI-Learn mapping (the CC map in
  `config.lua`) or changes the install layout

The major bump matters in practice: the 34 CC assignments are MIDI-Learned by hand in MainStage, so
renumbering one silently breaks a working rig.

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
