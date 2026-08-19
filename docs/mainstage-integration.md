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

## Historical record

[`archive/mainstage-integration-log.md`](archive/mainstage-integration-log.md) is the full
investigation log: every probe, several confidently wrong conclusions and their corrections, and the
dead ends (virtual endpoints, file-based transport via `io`, the `outport` sweep). Useful if you need
to know *why* something was ruled out, or to avoid re-running an experiment. Not needed for normal
work — much of it is superseded by the guides above, and it corrects itself repeatedly as it goes.
