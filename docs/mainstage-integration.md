# MainStage integration — status

The SL88 ↔ MainStage integration runs **entirely from the Lua device script**
(`MainStageScript/STUDIOLOGIC/SL.device/config.lua`). The Swift app is not part of this path.

## Where things stand

Working on hardware, with the helper app closed:

- The script matches the SL88 and MainStage invokes it with real patch data.
- It speaks SL Link directly: identifies, holds the session open, handles standby/restart.
- It draws the current concert, set and patch on the SL88's screen, updating live on patch change.

## How it works — read these instead

The reusable knowledge has been extracted into two guides. Prefer them over the historical record:

- **[`mainstage-device-scripts.md`](mainstage-device-scripts.md)** — writing MainStage Lua device
  scripts for any controller: install location, matching, callbacks, how to send MIDI, and the
  undocumented constraints (short `outport` name, one-shot timer, byte ceiling, absent `io`/`os`,
  multiple script instances).
- **[`implementing-sl-link.md`](implementing-sl-link.md)** — implementing the SL Link protocol from
  spec in Lua or Swift, including the four places real hardware disagrees with the published spec.

Next steps for the feature set are in
**[`full-functionality-plan.md`](full-functionality-plan.md)**.

## The three findings that cost the most

Recorded here because each looked like a dead end at the time:

1. **`outport` must be the short `kMIDIPropertyName`** (`'LINK'`), not the display name
   (`'SL LINK'`). The wrong name silently discards every message with no error anywhere. MainStage
   reports the right one as `controller_midi_in`'s `portName` argument.
2. **`settriggertimer` cannot re-arm itself** from inside `controller_timer_trigger`, so a script has
   no free-running clock. The session manufactures one by sending an Identification Query on every
   flush; its reply re-arms the timer.
3. **Never send Clear Screen.** With one at the head of a repaint, exactly one text line went missing
   every time — a *different* line between otherwise identical runs. Write Text overwrites the pixels
   it covers, so redrawing is self-cleaning and the clear is unnecessary.
4. **Display messages must be PACED — the SL88 silently drops ones sent too fast.** This is the
   general rule that finding 3 was a special case of. `controller_midi_in` flushes on every inbound
   frame, and the SL88 answers an Identification Query in ~2 ms, so every timer tick produced *two*
   flushes: one from the timer and one from the reply. Measured on 2026-08-20: 567 flushes against
   407 timer ticks. The panel painted the first of each pair and dropped the second. Proven with a
   seven-row calibration screen, each row a full-width Write Text in a distinct colour: rows 0, 2, 4
   and 6 rendered; rows 1, 3 and 5 never appeared at all. `FLUSH_SOON_MS` was **inert** before this —
   it governed only a fallback timer that inbound traffic continuously re-armed. The fix is
   `displayFlushReady`: at most one *display* message per timer tick, while protocol messages and the
   trailing Identification Query still flush immediately, because the session clock depends on that
   query going out.

## MainStage callback behaviour worth knowing

- **`controller_select_patch` is reused for non-patch selections, with the hierarchy shifted up one
  level.** Selecting a *set* delivers `patchname` = the set's name and `setname` = the *concert's*
  name. Selecting the *concert* delivers `patchname` = the concert name and `setname` = `""`. The
  arguments are not trustworthy as names on their own. The deliberate product decision (2026-08-20)
  is to display whatever the user selected rather than suppress it — do not "fix" this back without
  checking.
- **`patchlist` entry fields, confirmed on hardware:** `Label`, `IsPatch` (a real boolean),
  `SetIndex`, `PatchIndex`. Entries with `IsPatch == false` are **set header** rows; the flat list
  interleaves set headers with their patches.
- **`patchlist` is EMPTY on MainStage's first call**, before the concert has loaded. Any one-time
  introspection of it must wait for a non-empty list or it will burn its one shot on nothing.

## Verified on hardware (2026-08-21)

Tested against the SL88 with a real concert loaded, over three deploy rounds. Confirmed working:

- **Patch-change latency.** Was ~2s, now immediate. The cause was not message pacing: drain ticks
  measured 65-73ms apart, so `FLUSH_SOON_MS = 50` is honoured. The delay was that work queued just
  after an idle tick waited out the whole 3s keepalive one-shot, because `rearm_timer()` will not
  touch an already-pending timer. `request_quick_rearm()` shortens a LONG-armed outstanding timer
  when display work is queued. **`settriggertimer` is confirmed to re-arm from
  `controller_select_patch`, `set_display_mode` and `handle_zoom_button`** — every `quick-rearm` log
  line was followed by a tick ~55ms later instead of ~3s. It remains a confirmed no-op only from
  inside `controller_timer_trigger`.
- **Zoom screen layout** — all lines centred, patch name and NEXT line legible, `n/N` counting the
  patch within its own set rather than the flat list.
- **Mode switching** — no more surviving text from the previous screen.
- **Page-jump scrolling** and the smaller NEXT line, which together cut a list-mode patch change
  from 9 display messages to 3 for ~75% of steps.

### Clear Screen is un-banned in exactly one place

The project-wide ban stood on evidence that was actually the display-pacing bug `displayFlushReady`
fixed. `set_display_mode()` now sends a real Clear Screen — the full-screen black rect it replaced was
leaving remnants. It is sent **twice**, as two discrete flushes, because `flush_pending` always appends
an Identification Query to whatever it emits, so a lone clear always travels bundled with the query,
and a display message sharing an array with another message is a shape this project has measured as
unreliable. The clear is idempotent, so a dropped one costs ~65ms. Do not collapse it back to one.
Sending it alone without the query was considered and rejected: that flush can originate from a timer
tick, where `settriggertimer` is a no-op and the query's reply is the only thing that re-arms the
session clock — it would trade remnants for a dropout.

## Q1a closed (2026-08-22)

**Inbound substitution reaches MainStage and changes patch, but never through the patch selector.** A
disassembly-backed investigation of MainStage 3.7.1 found that the patch-selector parser MainStage
arms for `patchselector = true` scripts (see
[`mainstage-device-scripts.md`](mainstage-device-scripts.md#2-controller_info--the-items-table)) runs
only when `controller_midi_in` returns falsy. A table return — the only way a script can inject bytes
— diverts the event into MainStage's generic assignment/action layer instead, bypassing the parser
entirely. **No encoding, on any channel or byte order, with or without a Program Change, can reach the
patch selector through `controller_midi_in`'s return value.** The permutation ladder below is closed —
there is nothing left to permute on this path.

That also explains the spike result that originally opened this question: the injected bytes were
never seen as patch-selector traffic, so the "advance by one patch" behaviour was the generic
assignment layer's doing, not an artifact of our encoding. The spike wired joystick main SHORT
(BID `0x15`) to inject a Bank Select pair plus a Program Change for a hardcoded target:

```
441.403 SPIKE Q1a: injecting set=0 patch=0 "m.1 C07 Broad Strings" (no outport)
441.404 controller_select_patch: "m.26 C07 Strings"
457.903 SPIKE Q1a: injecting set=0 patch=0 "m.1 C07 Broad Strings" (no outport)
457.904 controller_select_patch: "m.54 C07 Strings"
```

The callback followed the injection by ~1ms every time — causally linked — but every press injected
the same target and MainStage landed on a different patch regardless. That is no longer mysterious:
the bytes never reached patch-selector logic to be addressed by in the first place.

The encoding tried in that round (MSB `0x00` before LSB `0x20`, channel 16, Program Change `0x00`, no
delay) turned out to be wrong on every axis per the binary — channel 1 not 16, no Program Change at
all, and LSB (not MSB) indexes the set, the inverse of what VAX77's header comment (and this doc, at
the time) claimed. None of that matters for Q1a's outcome: the parser this encoding targeted is
unreachable from `controller_midi_in` regardless of encoding.

**Caveats:** the branch polarity was inferred from control flow in the disassembly, not a named
symbol, and the parser's target class was not confirmed via `isKindOfClass:`. What would confirm it:
sending MSB-then-LSB on channel 1 with no Program Change from a **real** external MIDI port, not an
injected substitution.

## Still open

- **One session dropout observed** on the zoom screen during the first hardware round (a second
  `LOGIN` at t=1787334371.9 in that run's log). Keepalives were going out on every tick beforehand,
  so the cause is not known. Watch for it specifically next run; it has not recurred since.
- **Zoom centring is computed in Lua from estimated character widths**, because the protocol cannot
  centre text when the erase-path lines pass Max Width 0. It looked right on hardware, but the widths
  are eye-calibrated, not measured.
- **The live spec says SIZE_MEDIUM is 22px**, where this project's own notes estimate ~27px. Worth
  reconciling.
- **`FLUSH_SOON_MS` sweep** — 50 is confirmed honoured and good. 35 and 25 are untried; 100 is the
  last known-good fallback.

## Next stage

Phase 2 of `full-functionality-plan.md`: joystick navigation and patch selection. Q1a is now closed
(above): inbound substitution does change patch, but never through the patch-selector parser, which is
unreachable from `controller_midi_in`'s return value. Whatever Phase 2 does for patch selection has to
go through a different route than `patchselector`. Everything drawn so far is read-only; Phase 2 is
still the first time the script talks back to MainStage.

## Open issues

- **THE REAL PROBLEM: the SL88 discards draws from an app that is not selected on its display.**
  Established 2026-08-20 with unconditional instrumentation on the self-heal branch. An earlier entry
  here claimed the periodic self-heal repaint "never fires" — **that was wrong**, and was based on
  sampling an idle window that had not yet reached `REPAINT_EVERY_IDLE_TICKS`. Corrected by
  measurement:

  During a long drop-out the log shows the self-heal firing **348 times**, exactly every 10 idle
  ticks, each queueing a full 6-message repaint that is then flushed:

  ```
  selfheal ... idle=3485 lastPaint=3475 stale=false due=true
  paint queued (6 msgs) mode=zoom "m.62 C00 Brass + Bari"
  FLUSH #5574 regionId=zcnc bytes=36 queueDepthAfter=5
  ```

  Throughout, the session stayed `active` and identified (`7F 03 01`), with no rejection,
  re-identify, `STANDBY`, `RESTART` or `LOGOUT`. The screen stayed blank regardless, and only came
  back when the user re-selected the app on the keyboard.

  **Therefore redrawing cannot recover a de-selected app** — the hardware throws the draws away. Any
  fix based on repainting harder or more often is wasted effort, and the self-heal's real (and only)
  job is recovering from the SL88 wiping its screen *while we remain selected*.

  Still unknown, and where to look next: what causes the de-selection in the first place (it is
  silent — no protocol signal), and whether anything can get us re-selected without the user
  touching the keyboard. The one lever not yet tried is re-identifying from scratch mid-session to
  see whether that restores selection. Login Recall (`00 06`) would be the protocol-sanctioned route
  but needs a stored device icon, which is currently out of scope.


- **The session drops after some time and must be re-picked from the SL88's APP list.** DIAGNOSED
  2026-08-20 — it is *not* a keepalive or timeout problem. MainStage tears the script down and
  re-initialises it mid-session (4 finalize/initialize cycles in one run, while `state=active`). Each
  re-init resets `instanceID` to `SL_INSTANCE_START` (`0x6D`), but the SL88 still holds the previous
  incarnation's registration under `0x6D` because **no logout is sent on teardown** — a script can
  only transmit by returning MIDI from a callback, and `controller_finalize` has no return path. The
  keyboard therefore answers `IDENTIFICATION REJECTED (reason 00)`, the script bumps to `0x6E`, and
  re-registers **as a different app**, which is why the user's APP-list selection is lost. Two script
  instances (one per USB-MIDI interface) both starting at `0x6D` compound it.

  Untested fix to try first: on rejection, **retry the same instance ID after a pause of more than
  5 s** rather than immediately bumping. The SL88 drops a host that goes silent for ~5 s, so the
  stale registration should expire and the identity can be reclaimed instead of a new app being
  created. Deriving the instance byte from something stable per interface (the `portName` passed to
  `controller_midi_in`) would additionally stop the two instances colliding with each other.
- **`BIG_MAX_CHARS = 27` / `MEDIUM_MAX_CHARS = 36` are eye-calibrated estimates, not measured.** The
  zoom screen's patch name (`SIZE_BIG`) and set name (`SIZE_MEDIUM`) are truncated to these counts in
  the script rather than relying on the SL88's own Max Width truncation, which is confirmed broken at
  `SIZE_BIG`. Neither constant has been calibrated against the real pixel width.

  A shorter name replacing a longer one used to leave the old name's tail on screen — Write Text's
  opaque background at `maxWidth = 0` (required because Max Width truncation is broken at `SIZE_BIG`)
  only fills the glyphs actually drawn, not a fixed-width box. The first fix tried was padding every
  draw with spaces out to a constant character count (`pad_centered()`), so the background box would
  be a constant width. **This failed on hardware for two reasons and was removed**: the SLMK2 font is
  **proportional**, so N characters of space are pixel-narrower than N characters of the letters they
  replaced and still left a stale tail; and padding is symmetric in characters, not pixels, so it also
  broke `ALIGN_CENTER`'s actual centring. The real fix is `draw_text_with_erase()`: an explicit black
  `msg_draw_rect` over the full band, queued on a separate timer tick before each name's text, sized
  independently of glyph width. Cost: one extra message and a ~100 ms visible blank band per name
  change, accepted as the price of `maxWidth = 0`.
- **The multi-row patch list is parked**, pending pacing calibration — a seven-row repaint costs
  ~0.7 s at one message per tick. The single-patch (zoom) screen is the working display.

## Round 5: the soft-thru route is dead too (2026-08-22)

With `patchselector` unreachable from an injected return value, the remaining hope was to get the CC
pair to MainStage as *genuine* inbound MIDI from the scripted device. The script sent
`B0 00 <patch>` then `B0 20 <set>` outbound to the `LINK` port and logged every inbound CC 0 / CC 32.

**Nothing came back.** Across six presses cycling three well-separated targets, no inbound CC was ever
logged and no patch changed. The SL88 does not echo what we send it, so MainStage never sees it as
inbound MIDI on the scripted controller's port. Port discovery also showed only one port name ever
delivering events to the script: `LINK`.

### What is left, and it is known to work

MainStage's *assignment layer* does receive script-injected MIDI — that is what was stepping patches
erratically through rounds 1-4, hitting something already mapped in the concert. So the workable route
for relative navigation is deliberate rather than accidental: inject a distinct CC per direction and
assign each one in MainStage's Layout mode to its patch/set action. This is what Novation's Launchkey
script does, and it needs a one-time mapping per concert.

Jeroen scoped the feature to relative stepping — Up/Down one patch back/forward, Left/Right one set
back/forward — so absolute addressing is no longer required. Note only "next patch" has been observed
so far; "previous patch" and the set steps are unproven and depend entirely on what the assignment
layer offers.

## Historical record

[`archive/mainstage-integration-log.md`](archive/mainstage-integration-log.md) is the full
investigation log: every probe, several confidently wrong conclusions and their corrections, and the
dead ends (virtual endpoints, file-based transport via `io`, the `outport` sweep). Useful if you need
to know *why* something was ruled out, or to avoid re-running an experiment. Not needed for normal
work — much of it is superseded by the guides above, and it corrects itself repeatedly as it goes.

## Every control emits a mappable CC (2026-08-22)

Since MainStage's `patchselector` parser is unreachable from an injected `controller_midi_in` return
(see "Q1a closed" above), the script no longer tries to reach it at all. Instead every SL88 control —
every button, encoder turn and encoder press, short and long where it applies — emits its own distinct
CC on a dedicated channel (`CC_CHANNEL`, channel 16), for MainStage's own MIDI Learn / assignment layer
to map. This is the same pattern Novation's Launchkey script uses ("Round 5" above): inject a
recognisable MIDI event and let the user assign it in Layout mode, rather than trying to reach a
parser the script has no legitimate route into.

### CC map (34 gestures, CC 40–74, skipping 64)

Copied from `CC_MAP` in `config.lua`:

| CC | Gesture | | CC | Gesture |
|---:|:---|---|---:|:---|
| 40 | `JOY_UP_SHORT` | | 58 | `ENC4_PRESS_LONG` |
| 41 | `JOY_UP_LONG` | | 59 | `ENC1_TURN` |
| 42 | `JOY_DOWN_SHORT` | | 60 | `ENC2_TURN` |
| 43 | `JOY_DOWN_LONG` | | 61 | `ENC3_TURN` |
| 44 | `JOY_LEFT_SHORT` | | 62 | `ENC4_TURN` |
| 45 | `JOY_LEFT_LONG` | | 63 | `ENCB_TURN` |
| 46 | `JOY_RIGHT_SHORT` | | *64* | *(skipped — sustain CC)* |
| 47 | `JOY_RIGHT_LONG` | | 65 | `ENCB_PRESS_SHORT` |
| 48 | `JOY_PRESS_SHORT` | | 66 | `ENCB_PRESS_LONG` |
| 49 | `JOY_PRESS_LONG` | | 67 | `SEL1_SHORT` |
| 50 | `JOY_ROTATE` | | 68 | `SEL1_LONG` |
| 51 | `ENC1_PRESS_SHORT` | | 69 | `SEL2_SHORT` |
| 52 | `ENC1_PRESS_LONG` | | 70 | `SEL2_LONG` |
| 53 | `ENC2_PRESS_SHORT` | | 71 | `SEL3_SHORT` |
| 54 | `ENC2_PRESS_LONG` | | 72 | `SEL3_LONG` |
| 55 | `ENC3_PRESS_SHORT` | | 73 | `SEL4_SHORT` |
| 56 | `ENC3_PRESS_LONG` | | 74 | `SEL4_LONG` |
| 57 | `ENC4_PRESS_SHORT` | | | |

`64` is deliberately skipped — it's the conventional sustain-pedal CC, and while nothing else is
expected to be routed to channel 16, it wasn't worth the ambiguity of using it for something else if
it ever is.

### Mapping procedure

In MainStage: pick a target (a patch/set action, a channel-strip control, anything assignable), hit
**Learn**, then move or press the corresponding SL88 control once. One control, one mapping, done per
concert — no in-script navigation logic involved.

### Momentary buttons: the release is deferred a round, deliberately

Buttons read as momentary in MainStage — 127 then 0. The 0 is **not** queued immediately behind the
127: `queue_cc`'s own per-control coalescing means a second call for the same control before the first
flushes just replaces the pending value, so if the release were queued right behind the press, the
press (127) would never reach a batch at all — only the release (0) would. Instead only the 127 is
queued at press time; the control is remembered, and its 0 release is queued at the **start of the
next inbound SL frame** (in practice, usually within one Identification Query/reply round-trip, since
that heartbeat keeps inbound frames arriving even with no further user input) — before that frame's
own event is handled.

### Encoders send absolute position, not relative ticks

Encoders send their tracked value **absolutely**, 0–127, which MIDI Learns like an ordinary knob.
`CC_ENCODER_RELATIVE` exists in `config.lua` as a documented escape hatch to switch to relative
increments (65 = up one tick, 63 = down one) instead, but it is **not implemented** — flipping it
alone does nothing, since the accumulate-and-clamp path and `queue_cc`'s replace-in-place coalescing
both assume absolute values.

### Status: Confirmed on hardware (2026-08-22)

Deployed and tested against the SL88 with a real concert loaded. MainStage's MIDI Learn does accept a CC arriving by injection — Selector 1 (CC 67) was learned and responded on the first attempt, confirming the one assumption the whole design rested on. The `[sllink] CC batch: N CC(s), B bytes` log line confirms each injection round on the script side.

Not yet mapped, by choice — left for a later phase: Cancel, Apply, Global, DAW (Home/Zoom already has its own on-keyboard function, the list/zoom toggle).

### Sweep and mapping verification (2026-08-24)

Jeroen mapped joystick Up/Down/Left/Right, encoder B, and the long-press variant of the Cancel/Stop
button in MainStage, and confirmed all of them work. A sustained fast turn on encoder B produced 715
logged `CC batch` sends over the session, every one coalesced to a single CC - confirming `queue_cc`'s
per-control coalescing collapses a fast sweep to one send per flush round rather than flooding. No
session dropout occurred during or around the sweep; the session's few re-logins in this run were
minutes apart with the queue idle beforehand, consistent with reselecting the app on the keyboard
rather than anything code-induced. Closes the CC-mapping plan's outstanding verification step.

## Encoder value popup (2026-08-27)

Turning any mapped encoder (any `eid` present in `ENCODER_CC`) shows a full-screen popup on the SL88's
display, on the theory that the value and its wire CC number should be visible without a round-trip
through MainStage. Implemented in `config.lua` — search "MARK: - Encoder value popup".

- **A genuine third display mode**, not a floating overlay. `'popup'` sits alongside `'list'`/`'zoom'`
  as a `displayMode` value, entered and exited via `set_display_mode()` — the same
  double-Clear-Screen mode-switch machinery already hardware-proven for the list/zoom toggle, rather
  than an ad-hoc draw-over-the-top-and-invalidate pair. This also means the popup owns the whole
  screen while showing, so it never has to worry about overlapping list/zoom content underneath it.
- **Content**: `CC <n>` in small, dim text; the 0–127 value in bold white, centred inside a
  gauge-style ring — 20 segments swept over ~300° with a gap at the bottom (like a speedometer dial),
  orange for the lit segments up to the current value and light grey for the rest — inside a
  bordered black card. The look is modelled on the SL88's own native "Audio Master"/"Zone Levels"
  overlay screens, not on the Swift companion app's `SLLinkDemoScreen`.
- **No MainStage feedback involved.** `controller_midi_out` was confirmed on hardware to report
  `nil` name/valueString/color for the mapped CC itself (see the CC-mapping section above), so the
  popup never asks MainStage for anything — the CC number and value are both already known locally
  via `CC_MAP`/`ENCODER_CC`/`encoderValue`.
- **Dismissal**: automatic after ~1s of no further encoder activity. While the popup is active,
  `rearm_timer()`'s `popupActive` branch arms the shared session timer at `POPUP_TICK_MS` (~1s)
  instead of the normal ~3s keepalive cadence, so `POPUP_DISMISS_IDLE_TICKS` (1 tick) actually means
  about a second rather than about three. `check_popup_dismiss()`, run once per timer tick, then
  calls `dismiss_popup()`, which restores `displayMode` to whatever was showing before the popup
  (`popupPreviousMode`) via the same `set_display_mode()` path used to enter it.

**Status: confirmed on hardware (2026-08-28).** Shows and dismisses cleanly, with no leftover content
from the screen underneath. One observation worth recording, not a filed bug: the popup's initial
appearance was noted as "a bit slow" on this test — not investigated further this session.

## Encoder value popup: a STANDBY correlated with the dismiss repaint (2026-08-27)

The encoder value popup (`config.lua`, "MARK: - Encoder value popup") sends a burst of display
messages when `dismiss_popup()` fires (`invalidate_all()` + a full `paint_screen()`). A hardware test
this session captured that burst immediately followed by the SL88 itself sending a Standby
notification (`<- STANDBY`, decoded from `F0 00 20 1A 16 03 6D 00 04 F7`). Jeroen confirmed he had not
navigated the SL88's own menu away from the MainStage app at that moment, so this is not the ordinary
standby-on-app-switch case.

The session recovered on its own shortly after — the log shows `state=active` again a short time
later, ticking normally — so this is a transient, self-recovering dropout, not a permanent failure.

This looks like a recurrence of the unresolved dropout documented in the now-reverted joystick
browse/jump feature (`325218b`, later reverted in `10dbd2a`; superseded by this popup feature), which
was investigated exhaustively at the time — session tracking, instance ID, and macOS's own CoreMIDI
log all showed **no evidence of a software fault at any layer** — and never root-caused. It's now
resurfacing under a different trigger (a display repaint burst, rather than rapid encoder scrolling).

Per Jeroen's decision this session, this is being **shelved as a known open issue**, not chased
further right now — the visual redesign of the popup took priority. Not root-caused yet, not
"impossible" — the right diagnostic angle (rate-limiting repaint bursts, as the reverted feature's own
next-steps note suggested) just hasn't been tried here yet.

**Postscript (2026-08-28):** the popup was subsequently promoted to a full-screen mode (see "Encoder
value popup" above), which replaced the old ad-hoc dismiss path (`invalidate_all()` + a full
`paint_screen()`) with `set_display_mode()`'s proven double-Clear-Screen sequence. A hardware round
with this new dismiss path did not reproduce the STANDBY correlation. That is one clean test, not a
fix confirmed — this is **not** being called resolved, just not re-observed yet under the new
mechanism.

## Refactor verification: dead-code removal + comment triage (2026-08-28)

The `feature/lua-maintainability` refactor (dead-code removal + comment triage on `config.lua`) was
verified against the real SL88 MK2 with MainStage running a live concert ("Joseph key2", 163
patchlist rows). This is a **regression check, not new feature verification** — the dead-code phase
removed only unreachable code and the comment phases changed no executable line at all, confirmed by
diff. The result is the expected one: behaviour-identical on hardware.

Totals for the run: 345 timer ticks, 562 flushes, **0 Lua errors, 0 unhandled SL frames**.

Confirmed working:

- **Session lifecycle** — reached `state=active` unaided and held it for the entire run. The full
  session-clock chain worked on every tick: timer tick -> 10-byte Identification Query -> SL88 replied
  `F0 00 20 1A 16 03 6D 7F 03 01 F7` (identified) -> that reply re-armed the one-shot. Identified as
  `(03 6D)` on `outport=LINK`.
- **Patch changes** — 10 real `controller_select_patch` changes, each repainting.
- **Zoom button** — 4 SHORT presses, toggling list<->zoom in both directions (2 each way).
- **Popup** — raised once by an encoder, painted all 27 regions (`popupBg`, 4 border strips,
  `popupLabel`, `popupValue`, and all 20 of 20 ring segments), then auto-dismissed back to `list`,
  correctly restoring the pre-popup mode.
- **CC dispatch** — 22 CC batches, every one coalesced to exactly 1 CC / 3 bytes; nothing near
  `CC_BATCH_CAP`.
- **Queue** — drained to depth 0; no flush exceeded budget. The popup's ~30-message burst drained at
  one display message per tick as designed.
- **Region coverage** — across the three modes every drawable region in the file was exercised: all 8
  list rows plus the `ctx` bar, all 5 zoom regions (`zcnc`/`zset`/`zname`/`znext`/`zpos`), and the
  complete popup.

Not yet exercised, so treat as unproven — neither is a regression, both were already unproven before
this branch:

- **Zoom LONG press** (the force-full-repaint path in `handle_zoom_button`).
- **The re-identification wait path** (`STATE_REIDENTIFY_WAIT`, `handle_identification_rejected`) —
  needs a deliberate DeviceID collision.
