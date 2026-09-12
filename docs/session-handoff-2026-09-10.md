# Handoff — Master Volume session, 2026-09-10

Written at the end of a long hardware session, stopped on budget. This is the state of
`feature/host-api-actions` and what to pick up. Nothing here is speculation about what to do next
beyond what is explicitly labelled as such.

## The headline

**Master Volume works from MainStage.** The device requires a READ issued alongside the WRITE; a write
on its own is ignored. Jeroen proposed this early ("first send a read to get the current value, then
apply the change and send back"); it was deferred behind a verification chain and only tried hours
later, at which point it worked immediately. Confirmed on hardware: writes take effect and read replies
arrive (`<- MASTER VOLUME 67`).

Note the asymmetry, which is not understood: **reads issued during an encoder gesture are answered;
the read issued at login is not.** That was true in every run.

## THE IMMEDIATE PROBLEM — the rig is currently broken

The installed script logs the app out of the SL88's APP list. Symptom Jeroen saw: the app does not
appear, and the Master Volume popup is stuck on `--` with the volume unresponsive. Both are the same
cause.

**Cause.** `controller_finalize` was changed to send a Logout Request. MainStage tears the script down
and re-initialises it constantly, so every spurious teardown logs the app out. Hardware log shows an
instance APPROVED and then immediately `-> LOGOUT REQUEST from controller_finalize`. Per-instance
DeviceIDs made it worse: a re-init used to reclaim the same id so the entry effectively came back;
now each incarnation takes a different id, so it never does. Downstream, the session is never properly
registered, Master Volume reads go unanswered, `masterVolumeRead` stays nil, and the safety guard
(correctly) refuses to write an unconfirmed value — hence `--` and a dead encoder.

This is exactly the "showed up briefly, then disappeared" symptom that caused the original revert of
logout-on-finalize, documented in `config-lua-history.md`. It did not reproduce in the first test of
the change because that run happened to keep the approved instance alive.

**What remains valid:** `controller_finalize` genuinely *can* send — the device answered with `00 03`
LOGOUT CONFIRMATION, disproving the old "no return path" claim. The mechanism works; its effect on the
APP list is what fails.

## STATE OF THE WORKING TREE — read before doing anything

`config.lua` is **modified and uncommitted**, and the suite is **red: 234/235**, failing
`controller_finalize returns a Logout Request`.

An agent began reverting logout-on-finalize and was cut off mid-task. It applied the `config.lua` half
(`controller_finalize` now clears `pendingMessages`, sets `STATE_IDLE`, returns nil) but did not update
the harness test or the docs.

**To finish it:** update the harness test that asserts finalize returns a Logout Request so it asserts
the reverted behaviour, keeping the assertions that finalize still clears `pendingMessages` and sets
`STATE_IDLE`. Then add a short note to `config-lua-history.md` recording that logout-on-finalize was
tried on hardware and reverted the same day for the APP-list reason above. Then reinstall and restart
MainStage — the currently installed build is the broken one.

## Verified on hardware this session

- Identification APPROVED and REJECTED frames now reach the script. They were previously lost in the
  window after MainStage wires `outport` but before it delivers `controller_midi_in`, which made
  `handle_identification_rejected`, `STATE_REIDENTIFY_WAIT`, `REIDENTIFY_WAIT_MS` and
  `MAX_SAME_ID_RETRIES` unreachable for the project's entire life. Fixed by re-sending the
  Identification Request until an explicit approval arrives, with a fallback floor.
- Per-instance DeviceIDs and per-instance log tags. Two instances had been approved as `03 6D`
  simultaneously; tagging every log line is what made that visible.
- The 2 s popup dismissal (`POPUP_DISMISS_IDLE_TICKS = 2`) — Jeroen confirmed "popup displaytime is ok".
- Popup seeds from the device value at gesture start, then tracks the value being sent.

## Not tested on hardware

The final build's safety guard — never write a Master Volume value that has not been confirmed by a
READ reply. It exists because the first encoder tick previously applied a delta to an invented default
of 100 and **wrote 100 to the device**, i.e. one click could jump the audio board to full output. The
hazard is confirmed on the wire (`-> ... 07 01 64`); the fix for it is not yet confirmed working.

## Open, unexplained

- **Why the login-time READ is unanswered while gesture READs are answered.**
- **A MainStage freeze with audio pops while completely idle**, seen once. Suspected to be a drop
  detector added and removed the same day (it fell to `STATE_IDLE` after 6 s without a query reply,
  which could drive a re-identify loop). **Suspected, not proven** — the debug capture for that run was
  lost when MainStage was restarted by hand. If the freeze recurs without the detector, the cause is
  elsewhere. Consequence of its removal: the app cannot recover on its own if the keyboard drops it.
- **IDENTIFICATION REJECTED reason `00` is not understood.** A freshly derived, never-used id was still
  rejected twice before approval, so it cannot simply mean "that id is taken".

## Test-quality caveat

Roughly 50 assertions were added this session. Most were mutation-tested by the same agent that wrote
them and self-reported. The one independent verification pass that ran immediately found a **vacuous
assertion** — an off-by-one on the gesture boundary (`>=` vs `>`) passed the entire suite, because no
case sat on the boundary value. That gap is now closed and the fix independently confirmed.

A verification pass over the session's other new assertions is worth running before this branch merges.
The policy going forward (Jeroen's instruction): implementation agents write code and tests but do not
mutation-test; a separate agent with limited context does the verification, and is not given the
implementation prompt or the author's report.

Also noted by that pass: the harness has no `pcall` isolation, so a mutation causing a Lua error aborts
the whole run at that line and can mask whether later assertions would also have caught the bug.

## Housekeeping

`LUA_DEBUG` is still enabled and a sniffer may still be running. Both cost performance:

```
defaults write com.apple.mainstage3 LUA_DEBUG -bool false
pkill -f /tmp/sniffer
```

Kept logs: `/tmp/lua-mvol-login-read-keep.log`, `/tmp/lua-flushbytes-keep.log`, `/tmp/lua-restart1.log`.

## Tooling added

`Scripts/probe-mastervolume.swift` — a standalone SL Link probe that drives its own session with no
MainStage involved, reassembles SysEx split across CoreMIDI packets, runs a scripted read/write
sequence, prints a verdict table, and draws each step on the SL88's own screen. It is what proved
Master Volume works. Run it solo with MainStage quit; a run only means something if the probe was
explicitly selected on the keyboard during that run, because state carries between rapid runs.

---

# Update — 2026-09-12

Second session. The branch is now **stabilised and green at 245/245**, and Master Volume works well
enough to use, with one open defect.

## Landed since the first handoff

- The half-applied `controller_finalize` revert is finished and committed; the app stays in the APP list.
- Three stale claims in `docs/mainstage-integration.md` corrected (Master Volume "does not work"; the
  "no return path" claim; the same-id retry listed as untested).
- A logging defect fixed: a READ reply logged the local send-value instead of the received one, which
  would have made the safety-guard evidence unreadable.
- Five boundary gaps closed in the harness, each found by independent verification and each confirmed to
  fail on the mutation it guards.
- Master Volume: the never-write-until-confirmed guard was **removed** — see below. The value is now
  tracked locally from `MVOL_SEED_DEFAULT` (60), and popup entry always erases its full region.

## What the hardware taught us, and it overturned two assumptions

1. **The device only answers a READ while writes are in flight.** The "never write an unconfirmed value"
   guard could therefore never confirm: on hardware it left the encoder dead, polled forever, saturated
   the queue and got the app dropped. Safety has to come from *what* we write first (60), not from
   refusing to write.
2. **The READ reply does not report the device's output level.** It sat at a constant 71 through a sweep
   of writes 65→70→72 that audibly changed the volume. Seeding gestures from it dragged the value back on
   every pause. What it actually reports is unknown.

## The one open defect — for next session

**Not all write-backs reach the device: the sound card's volume steps unevenly.** Full analysis and the
three untested suspects are in `docs/config-lua-history.md`, section "Master Volume write-backs do not
all reach the device (2026-09-12)". Short version: per-region coalescing plus the one-message-per-flush
budget necessarily thin a fast sweep, and any fix must not reintroduce the queue saturation that drops
the app.

## Where the plan stands

Phases 1, 2 and 4 of the landing plan are done (green suite, verification pass, docs reconciled).
**Phase 3 (hardware acceptance) is partly done** — the finalize revert, per-instance ids, identification,
popup and Master Volume were all exercised; a full regression sweep (patch changes, zoom, CC mapping via
MIDI Message Monitor, standby/restart) was not. **Phase 5 (CHANGELOG + PR) is not started.**

The branch is still unpushed. `CHANGELOG.md`'s `[Unreleased]` still predates both sessions' work.

**On the version:** the release workflow will bump to 2.0.0 on merge, but for the wrong reason — the only
`!` commit in range (`e4ad0fa feat!:`) was itself reverted by `4b0cf4c`. Add a real `BREAKING CHANGE:`
trailer describing the relative-encoder switch before merging, so the major bump rests on something true.

## Housekeeping

`LUA_DEBUG` is on and a sniffer is running:

```
defaults write com.apple.mainstage3 LUA_DEBUG -bool false
pkill -f /tmp/sniffer
```

## Upstream: reply posted to sl-link issue #2 (2026-09-12)

Jeroen posted the reply drafted in `docs/upstream-reply-issue-2.md` to
<https://github.com/fatarsrl/sl-link/issues/2>. **We are now waiting on answers to four questions**, so
check the issue before investigating any of them locally:

1. Must a READ accompany a WRITE for the write to be honoured?
2. What does the READ reply report, given it lags far behind (returned 29 while writing 67)?
3. Is there a recommended minimum interval between Master Volume writes?
4. What does `IDENTIFICATION REJECTED` reason `00` mean for a freshly generated, never-used DeviceID?

**Question 3 is the one that would change the code**: a documented rate limit turns the uneven-stepping
defect into a one-line cadence cap, and would make the probe cadence experiment unnecessary. Worth
checking for a reply before building that experiment.
