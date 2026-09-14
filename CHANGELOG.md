# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versioning follows the policy in
`CLAUDE.md` (tracks the shipped Lua script only).

## [Unreleased]

## [2.1.0] - 2026-09-14

- docs: tidy the generated 2.0.0 changelog section
- docs: record v2.0.0 verified on hardware
- docs: draft the upstream correction for sl-link issue #2
- feat: move the popup value inside the ring
- fix: duplicate the underlying screen's line, not the list's
- fix: make session recovery reachable when the clock is dead
- fix: throttle the popup value's repaint to ~10/second
- docs: record the popup rework verified on hardware

## [2.0.0] - 2026-09-14

### BREAKING

- The five encoders and the joystick rotary ring now send `Relative2C` two's-complement relative
  deltas instead of an absolute 0-127 value. Any mapping learned against the old absolute behaviour
  must be redone. The wire encoding is hardware-verified (2026-09-05).

No CC numbers moved in this release.

### Added

- All 34 SL88 gestures declared as named `controller_info()` items, so they appear in MainStage's
  Layout mode by name instead of as bare CC numbers.
- `logicprox = false`; the emitted CC numbers now appear in the debug log; MainStage's injected
  globals are logged at `controller_initialize`.
- Master Volume driven from the A encoder: writes paced to one per timer tick, the value tracked
  locally (seeded at 60, not read from the device — see Fixed), a popup showing it, and the popup
  region erased with a filled rectangle on entry.
- Per-instance DeviceIDs and per-instance log tags, so concurrent script instances are distinguishable
  in the log instead of colliding on one id.
- Bounded recovery when the SL88 goes silent mid-session: after `ACTIVE_QUERY_DROP_MS` with no
  Identification Query reply, the script re-identifies, capped at `MAX_RECOVERY_ATTEMPTS`. **Untested
  on hardware** — the one session-drop it was live for was resolved by MainStage's own churn before
  the threshold was reached, so the watchdog never actually fired.
- Logout from the Cancel button: SHORT sends a Logout Request and withholds the keepalive until the
  SL88 drops the app (it never confirms the request); LONG force-logs-out locally without sending one.
- `Scripts/probe-mastervolume.swift`, a standalone SL Link probe that drives its own session with no
  MainStage involved, with a `--cadence` diagnostic mode.

### Changed

- Relicensed from GPLv3 to Apache-2.0; the release zip now ships `LICENSE` and `NOTICE` (it
  previously shipped no license at all).

### Fixed

- The stick item names were transposed: Stick 1 is the XY stick whose X axis is pitch bend, Stick 2
  is the modulation stick.
- Pending relative CC deltas now accumulate in signed space, so a fast encoder twist cannot lose a
  tick.
- A watchdog now recovers the session clock if MainStage ever fails to deliver a `settriggertimer`
  one-shot, which previously latched `timerPending` forever and silently killed the keepalive
  (captured on hardware: stalled dead at tick #352 with no recovery short of restarting MainStage).
  The watchdog only re-arms once queued display output is stuck behind the dead clock, so it cannot
  fire during ordinary play and starve the clock itself (rule 6).
- Identification APPROVED and REJECTED frames now actually reach the script. They were being lost in
  the window after MainStage wires `outport` but before it starts delivering `controller_midi_in`,
  which made the re-identify recovery path (`handle_identification_rejected`,
  `STATE_REIDENTIFY_WAIT`) unreachable for the project's entire life until now. Fixed by re-sending the
  Identification Request until an explicit approval arrives.
- Master Volume's never-write-until-confirmed guard was removed: the device only answers a READ while
  a write is in flight, so the guard could never confirm and left the encoder polling forever. The
  value is instead tracked locally from a known-safe seed (60) rather than trusted from the device.

### Documented

- The `controller_info()` key vocabulary extracted from `LogicMainStage.framework`, and the finding
  that the undocumented `action_<app>` field is inert in MainStage 4.3.1 (added, then removed once
  proven to do nothing on hardware).
- MainStage's device matching requires the `.device` folder name, `controller_info()`'s `model`, and
  the hardware's reported `kMIDIPropertyModel` to all agree exactly; a mismatch on any one fails
  silently, with no error anywhere.

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

[Unreleased]: https://github.com/jeroenvv/sl-link-mainstage/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/jeroenvv/sl-link-mainstage/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/jeroenvv/sl-link-mainstage/releases/tag/v1.0.0
