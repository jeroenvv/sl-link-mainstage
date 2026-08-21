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

Phase 2 of `full-functionality-plan.md`: joystick navigation and patch selection. The load-bearing
unknown is still Q1a — whether returning `{midi=...}` from `controller_midi_in` with no `outport`
makes MainStage change patch. Everything drawn so far is read-only; Phase 2 is the first time the
script talks back to MainStage.

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

## Historical record

[`archive/mainstage-integration-log.md`](archive/mainstage-integration-log.md) is the full
investigation log: every probe, several confidently wrong conclusions and their corrections, and the
dead ends (virtual endpoints, file-based transport via `io`, the `outport` sweep). Useful if you need
to know *why* something was ruled out, or to avoid re-running an experiment. Not needed for normal
work — much of it is superseded by the guides above, and it corrects itself repeatedly as it goes.
