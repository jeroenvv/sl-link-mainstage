# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versioning follows the policy in
`CLAUDE.md` (tracks the shipped Lua script only).

## [Unreleased]

### BREAKING

- **CC 40-50 are gone.** Every joystick gesture — the four tilts (40-47), the press (48/49) and the
  ring (50) — now selects patches in the script instead of emitting a CC, so any mapping learned to one
  of them must be redone and has nothing to remap to. The numbers are left unused rather than
  reassigned, so every other mapping is unaffected.
- Patch selection needs the concert's patches to carry **sequential program numbers** — see the README.
- The config screen no longer lists the joystick: with no CCs left to show, its four rows are gone.

### Added

- Turn the ring to browse the patch list, press the joystick to select. Browsing moves the cursor only;
  an uncommitted browse returns to the playing patch after a few seconds. The press sends Bank Select +
  Program Change.
- Joystick tilts select directly: up/down by patch, left/right by set, long up/down to the first/last
  patch of the concert. At either end a tilt does nothing rather than reloading the playing patch.
- Navigation icons on both patch screens, white, with the press icon lit while a browse waits.
- `FLUSH_BUDGET` 72 → 78, so text lines carry 43 characters instead of 37. Hardware-verified.
- `mainstage/Demo.concert`, an example rig on MainStage's Keyboard Minimalist template, with a README
  listing every CC to assign.

### Fixed

- No popup on a ring turn — the patch list is the feedback.
- The list's context bar stays readable: small and blue, after medium overflowed its box.

### Documentation

- README: how to set MainStage up for patch switching, and which Patch List command to use for a small
  concert versus a large one.
- The ceiling MainStage puts on a returned array was quoted as `[78, 87)` in three documents; the
  measurement it came from tested 96.

## [2.7.0] - 2026-09-20

- feat: select patches from the joystick ring via Bank Select + Program Change
- docs: record the patch-selection route, the six bindings tried and two traps

## [2.6.0] - 2026-09-20

- feat: colour the zone encoder rings from MainStage's own feedback
- feat: dim the ring with a volume's level, and coalesce ring updates
- feat: popup name above the ring in both modes, bigger, AUDIO MASTER for A
- feat: every ring tracks its value, not just names containing "volume"
- fix: include colour in midi_out's unchanged-tuple check
- fix: treat an empty reported name as no name
- docs: record the RGB rings, the colour-units trap and confirmed patch stepping
- docs: ring colour comes from the knob mapping's Custom Color
- docs: record the two mapping attributes that drive the SL88's display

## [2.5.1] - 2026-09-20

- refactor: name buttons and LEDs after the spec, not the panel

## [2.5.0] - 2026-09-20

- feat: add a config screen on the SETTINGS button
- fix: leave the ZOOM lamp alone in config, bigger title, no popup over it
- docs: record the config screen, the SETTINGS button id and the nav icons
- test: cover the config screen, its scroll and the unmappable SETTINGS button

## [2.4.1] - 2026-09-20

- fix: size the popup value box to the measured knob hole
- docs: record that host callbacks live in MainStageCore, not LogicMainStage
- docs: record the measured Write Text box heights and knob hole
- docs: record the hardware confirmation and the re-identify retry run
- test: add a text-metrics probe for glyph heights and the knob hole
- test: make the text-metrics probe an interactive caliper

## [2.4.0] - 2026-09-17

- feat: show MainStage's real parameter name and value in the popup
- feat: light the ZOOM lamp in list mode, dark in zoom mode
- fix: drive the mute ring LED from the timer tick, not the popup paint
- fix: make the mute ring LED prompt and correct from the start
- fix: drop stored parameter feedback when the concert changes
- fix: re-assert the mute rings after login confirmation
- fix: a net-zero CC batch no longer swallows the inbound event
- docs: spec the two-mode popup layout from the midi_out probe
- docs: correct the midi_out return-value claim
- docs: record the four mute LED faults found on hardware
- docs: record the controller_midi_in contract review

## [2.3.0] - 2026-09-17

- feat: release the registration when MainStage quits
- fix: stop the digest counting the logout line as a finalize
- docs: record logout-on-quit working, gated on state and tick
- chore: log when controller_finalize fires

## [2.2.1] - 2026-09-17

- fix: pace every queued SL message to one per tick
- fix: queue the popup value behind its knob redraw
- fix: drop stale identification requests on approval
- docs: identify every LED id on hardware
- docs: register the settings-storage follow-up
- docs: record the second hardware run and the faster CANCEL logout
- chore: order the generated changelog feat, fix, docs
- test: make the popup ordering assertion prove targeting
- chore: add a lua.log digest for cheap hardware-run reads
- chore: drop the popup pairing diagnostic, confirmed on hardware
- Merge fix/one-sl-message-per-tick: pace SL messages one per tick

## [2.2.0] - 2026-09-16

- fix: bump the README's version on release too
- feat: toggle audio-board mute from the A encoder button
- fix: repeat the mute and LED writes, which MainStage drops
- docs: record mute verified on hardware, and the dropped-volume follow-up
- docs: add the settled-volume follow-up
- fix: re-send the final volume value once a gesture settles
- fix: light the LED on login, and let fast turns send faster
- docs: record the mute and pacing work verified on hardware

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
