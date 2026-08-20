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

## Open issues

- **The session drops after some time and must be re-picked from the SL88's APP list.** Observed
  2026-08-20, not yet diagnosed. First suspects, in order: MainStage loads the script **once per
  USB-MIDI interface**, so two instances currently identify with the *same* DeviceID (`03 6D`) and
  contend; and the keepalive path under the new display pacing has not been watched over a long idle
  period. Needs a long-running capture with timestamps before theorising further.
- **`BIG_CHARS_PER_LINE = 16` is an untested estimate.** The two-line patch name wraps at that count;
  it has not been calibrated against the real pixel width at `SIZE_BIG`.
- **The multi-row patch list is parked**, pending pacing calibration — a seven-row repaint costs
  ~0.7 s at one message per tick. The single-patch (zoom) screen is the working display.

## Historical record

[`archive/mainstage-integration-log.md`](archive/mainstage-integration-log.md) is the full
investigation log: every probe, several confidently wrong conclusions and their corrections, and the
dead ends (virtual endpoints, file-based transport via `io`, the `outport` sweep). Useful if you need
to know *why* something was ruled out, or to avoid re-running an experiment. Not needed for normal
work — much of it is superseded by the guides above, and it corrects itself repeatedly as it goes.
