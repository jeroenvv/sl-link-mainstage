# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versioning follows the policy in
`CLAUDE.md` (tracks the shipped Lua script only).

## [Unreleased]

### BREAKING

- The device is renamed from `SL` to `SL88`. The install path moves from
  `MainStage Devices/STUDIOLOGIC/SL.device/` to `.../SL88.device/` - remove the old folder. Because
  MainStage identifies a device by manufacturer and model, every existing MIDI-Learn mapping must be
  re-learned.
- The five encoders and the joystick rotary ring now send `Relative2C` two's-complement relative
  deltas instead of an absolute 0-127 value. Any mapping learned against the old absolute behaviour
  must be redone. The wire encoding is inferred from the name and is not yet confirmed on hardware.

No CC numbers moved in this release.

### Added

- All 34 SL88 gestures declared as named `controller_info()` items, so they appear in MainStage's
  Layout mode by name instead of as bare CC numbers.
- `logicprox = false`; the emitted CC numbers now appear in the debug log; MainStage's injected
  globals are logged at `controller_initialize`.

### Changed

- Relicensed from GPLv3 to Apache-2.0; the release zip now ships `LICENSE` and `NOTICE` (it
  previously shipped no license at all).

### Fixed

- The stick item names were transposed: Stick 1 is the XY stick whose X axis is pitch bend, Stick 2
  is the modulation stick.
- Pending relative CC deltas now accumulate in signed space, so a fast encoder twist cannot lose a
  tick.

### Documented

- The `controller_info()` key vocabulary extracted from `LogicPro.framework`, and the finding that
  the undocumented `action_<app>` field is inert in MainStage 3.7.1 (added, then removed once proven
  to do nothing on hardware).

## [1.0.0] - 2026-08-29

Initial release: a MainStage Lua device script that connects Apple MainStage to a Studiologic SL88
MK2 over the SL Link SysEx protocol, entirely from Lua, no helper app.

### Added

- The SL Link session protocol over SysEx: identification, login confirmation, 3s keepalive, logout,
  and standby/restart with a full repaint on return.
- Concert/set/patch display screens (zoom, list, single-patch), paced to the SL88's display budget.
- All 34 SL88 gestures (buttons, encoders, joystick) emitting MIDI-Learnable CCs on a dedicated
  channel.
- The encoder value popup: control name, wire CC number, and a filling ring gauge drawn with the
  SL88's native Knob bitmap.
- Semantic versioning and a release pipeline that bumps `VERSION` from commit prefixes.

[Unreleased]: https://github.com/jeroenvv/sl-link-mainstage/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/jeroenvv/sl-link-mainstage/releases/tag/v1.0.0
