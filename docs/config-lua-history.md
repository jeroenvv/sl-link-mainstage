# config.lua: implementation history

`MainStageScript/STUDIOLOGIC/SL.device/config.lua` used to carry its own changelog inline — dated
hardware reports, rejected fixes, measurement traces, revision-by-revision narratives — until comments
outweighed code roughly 3:1. This document is where that reasoning now lives.

**Division of labour:** `config.lua` keeps the *operative constraint* — the thing a future edit must
not violate, stated tight and at the exact site where breaking it would be easy. This document keeps
the *story* — what was tried, what broke, what was measured, and why the constraint is what it is. If
you are about to change display pacing, the session clock/timer, or flush logic, read this first; the
short warnings in the code assume you already know why they're there.

Every dated entry below is a hardware finding against a physically attached SL88 MK2 (firmware 1.1.2),
observed through `LUA_DEBUG` output (`/tmp/lua.log`) unless noted otherwise. "The banner" means the SIX
RULES block at the top of `config.lua`.

---

## Display pacing and the alternating-row loss

### DEFECT A: the ungated flush drained at round-trip speed, not timer speed

Established 2026-08-19. `controller_midi_in` calls `flush_pending(true)` on every inbound SL frame —
and the Identification Query's own reply is one of those frames. Before `displayFlushReady` existed,
that meant a display item queued by handling one query reply's flush immediately flushed *again* on
that flush's own reply, whose reply flushed again, and so on: the queue drained at the SL88's ~2ms
round-trip time, not at `FLUSH_SOON_MS` (100ms at the time) as intended. `FLUSH_SOON_MS` only ever
governed the *fallback* timer's interval — it never paced the actual drain, so it was functionally
inert.

**Consequence, confirmed on hardware:** the SL88 cannot paint that fast, and silently drops a display
message that arrives while it is still painting the previous one. Two independent symptoms nailed this
down:

- A 7-row calibration screen (one saturated colour per row; a since-removed diagnostic-only screen)
  rendered rows 0/2/4/6 and left rows 1/3/5 black — every *second* message lost. Not a geometry bug
  (which would leave only the last row visible) — an every-other-message loss, which is the signature
  of a message arriving mid-paint.
- A 3-region zoom update (`zset`/`zname`/`zpos`, flushed back to back as FLUSH #148/#149/#150)
  reliably lost the *middle* one — the patch name, the one thing that screen exists to show.

This is also what had kept `displayMode` defaulting to `'zoom'` rather than `'list'` for a while: the
alternating-row loss looked at first like something specific to the list screen's repeated-row-geometry
shape. It wasn't — it reproduced with any content shape once display messages went out faster than the
SL88 could paint them.

**Fix:** `displayFlushReady`, set true once per timer tick by `controller_timer_trigger`. A display
message (`itemType IT_DISPLAY` — including the trailing sacrificial redraw, which has no `regionId` but
is still `IT_DISPLAY`) may be dequeued by `flush_pending()` only while this flag is true, and dequeuing
one clears it immediately. Protocol messages (identification, keepalive, logout — `regionId` nil) and
the trailing Identification Query are *not* gated by it: they go out on every flush regardless, because
the query's reply is the only thing that re-arms the session's one-shot timer (see
[The session clock](#the-session-clock-and-the-one-shot-timer)) — gating it too would stall the clock
the moment any display work was queued. The flag starts `true` so a display message queued before the
first timer tick isn't stuck waiting up to `KEEPALIVE_MS` for a tick that has nothing to do with it.

### DEFECT B: a keepalive stuck behind a display backlog

Established 2026-08-21. `flush_pending()`'s dequeue logic originally only ever looked at
`pendingMessages[1]`. During a repaint drain, a keepalive queued *behind* a display message sat stuck
there until the whole display backlog cleared — one message every `FLUSH_SOON_MS`. Combined with the 3s
keepalive cadence, a slow repaint could miss the SL88's ~5s host timeout and drop the session mid-
repaint.

**Fix:** if the head message can't go out this flush (it's `IT_DISPLAY` and `displayFlushReady` is
false), `flush_pending()` scans forward for the first *protocol* message (`itemType ~= IT_DISPLAY`) and
lets it jump the queue, removed from its own position with everything else left untouched. Display
messages never reorder relative to each other — only a protocol message can jump ahead of ones still
waiting on `displayFlushReady`.

### The `[display, query]` flush shape

Every shape that has ever rendered reliably on hardware looked like `[display, query]` — one display
message plus the trailing Identification Query, nothing else. The shapes that silently vanished were
the odd ones out: a lone display message with no query, a display bundled with the keepalive, two
displays together. Position in the repaint turned out to be irrelevant (moving the draw order just
moved which message failed), as did size and content. Rather than keep guessing at the underlying rule,
`flush_pending()` emits exactly the one shape that has never failed — at most one queued message per
flush, always paired with the query.

Cadence instrumentation was added to `flush_pending()`'s print (`tick=`, `regionId=`, `bytes=`,
`queueDepthAfter=`) and to `controller_timer_trigger`'s tick print, specifically so a captured
`/tmp/lua.log` could be read back as "tick N emitted region R, depth D" — flushes can also happen
off-tick (inbound-frame flushes in `controller_midi_in`, `controller_select_patch`), so a FLUSH whose
`tick=` repeats the previous FLUSH's is exactly one of those.

---

## The flush shape and byte ceiling

### The MainStage byte ceiling

Measured on hardware: a returned array of 78 bytes renders; one of 87 bytes renders **nothing at all**
— the whole array is discarded, not truncated. The SL Link spec itself has no such limit (Write Text is
`S(1)...S(N)` for arbitrary N; Max Width truncates visually in pixels), so this is purely a MainStage
transport constraint. `FLUSH_BUDGET` (72) sits comfortably below the known-good 78, since the exact
ceiling is only bracketed to `[78, 87)` and there's nothing to gain from running close to it.

### `FLUSH_SOON_MS` retuning and the sweep plan

Before DEFECT A was understood, `FLUSH_SOON_MS` was inert (see above) and sat at 100ms, untested as a
floor — just an untested holdover from before the pacing bug was fixed. Retuned to 50 on 2026-08-21 to
cut patch-change latency: a hardware report found switching patches could take up to two seconds, which
combined with the 3s keepalive cadence to approach the SL88's ~5s host timeout and drop the session (see
[the unconditional keepalive](#the-unconditional-keepalive) for the other half of that fix).

The planned sweep, one value at a time, each verified on hardware before moving on: 50 (current) → 35 →
25. Change only this one constant per hardware run (`test-mainstage-script`'s "one variable per run"
rule) and read `/tmp/lua.log`'s FLUSH/tick lines to confirm every expected region still renders. 100 is
the last known-good value if a step regresses — revert to the previous step in the list, and if 50
itself loses messages, revert all the way to 100. This sweep has not been run past 50 as of this
writing.

Reducing a captured log to a per-message interval table: `/tmp/lua.log` itself carries no
per-line timestamps (`restart-mainstage.sh` redirects stdout raw), so capture through a timestamping
filter first —

```bash
... | while IFS= read -r l; do printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$l"; done > /tmp/lua.log
```

(or moreutils' `ts '%H:%M:.S'` if installed) — then:

```bash
grep -E '\[sllink\] (FLUSH|timer tick)' /tmp/lua.log | \
  awk '{ts=$1; if (p!="") printf "%s -> %s  %s\n", p, ts, $0; p=ts}'
```

prints each FLUSH/tick line paired with the timestamp delta since the previous one; the `tick=`/
`pending=`/`queueDepthAfter=` fields already in each line then tell you how many ticks and how much
queue depth changed per interval, without needing a Lua-side clock (`os` is absent from the sandbox).

### `FLUSH_SOON_MS` retuned to 35 (2026-08-29)

Step one of the planned sweep, taken next because `FLUSH_SOON_MS` paces the tick interval for the
*entire* drain, not just content: a popup entry is roughly 13 ticks total, the 4 remaining dead ticks
before the first pixel (the two Clear Screens plus the `MODE_SWITCH_SETTLE_TICKS` guard on each) and
the ~8 content messages after it. Lowering the constant scales both halves together — at 50ms that's
~650ms per popup entry; at 35ms the same 13 ticks would be ~455ms.

**Confirmed on hardware 2026-08-29** (SL88 MK2 + MainStage, `LUA_DEBUG` capture): 307 ticks, 578
flushes, 22 patch changes, 2 popup entries, 10 mode switches, **0 Lua errors**. Every display region
was emitted and rendered — zoom (`zcnc`, `zset`, `zname`, `znext`, `zpos`), list (`ctx`, `row0`
through `row7`), popup (`popupBg`, `popupKnob`, `popupLabel`, `popupValue`). The user confirmed
visually: no missing regions, no blank rows, no stale tails on shorter patch names — neither of the
documented failure modes (a missing region, or a stale tail from a shorter name failing to fully
overwrite a longer one) appeared. Popup dead ticks stayed at 4, so at 35ms that's ~140ms instead of
~200ms, and a full pop-in ~455ms instead of ~650ms.

Revert ladder if a later step regresses: 35 -> 50 (previous confirmed-good) -> 100 (original floor,
last known-good) only if 50 itself turns out to lose messages.

### `FLUSH_SOON_MS` retuned to 25, backed out (2026-08-29)

Final rung of the planned sweep (50 -> 35 -> 25). 35 is confirmed good (previous section); this step
lowered the constant one more notch, on the same reasoning — `FLUSH_SOON_MS` paces the entire drain
interval, not just content, so a popup entry's 13 ticks would drop from ~455ms (at 35ms) to ~325ms.

**Backed out the same day.** At 25, the user reported the display "sometimes drops out while
playing" — otherwise everything worked. This is **not** the documented failure mode the sweep plan
was watching for (a missing region, or a stale tail from a shorter name failing to fully overwrite a
longer one); every display region rendered correctly.

Both values were exercised while playing: the 35 confirmation run (previous section) and the 25 run
both included the user playing sustained notes, not just changing patches, toggling modes and
exercising the popup. 35 held with no dropout; 25 dropped out. That makes the comparison clean, and
it is the sweep's main finding: **25 is below the usable floor on this hardware, and the failure mode
that establishes the floor is a display dropout while playing — not the missing-region/stale-tail
failure the sweep plan predicted.** The plan was watching for the wrong symptom.

What the captured log shows, and does not show, about *why*:

- One STANDBY/RESTART pair occurred during the 25 run. At that moment the session clock was
  **healthy**: timer ticks 23-28 were consecutive, Identification Query replies were arriving
  normally, the queue had just drained to depth 0, and `state=active` held right up to the SL88
  sending System/Standby (`00 04`) unprompted. Zero re-identifications, zero identification
  rejections, one LOGIN — the session was never lost and re-established.
- Therefore the captured STANDBY does **not** show keepalive starvation on its own, and may be
  unrelated to the dropout the user saw.
- **Notes are not logged.** `controller_midi_in` only prints for SysEx, so the playing itself is
  invisible in `/tmp/lua.log` — there is no record of note traffic to correlate against the dropout.
- **The log has no timestamps.** `restart-mainstage.sh` redirects stdout raw, so tick *intervals* —
  the thing that would reveal a starved timer — cannot be measured from this capture.

So while the empirical result is now clear (35 good, 25 bad, both tested the same way), the
*mechanism* is not pinned down. [Rule 6](#rule-6-notes-starve-the-clock) describes a symptom that
looks the same — display dropping out while playing — from `rearm_timer()` being starved by note
traffic, fixed by the `timerPending` gate. It is a **candidate** explanation for why a shorter
`FLUSH_SOON_MS` would make that worse, but it is **not confirmed** as the cause here; nothing in this
capture demonstrates it, for the reasons above.

**Verdict:** the sweep is **concluded, settled at 35**. 25 was tried and rejected on hardware
evidence (dropout while playing, reproduced against a clean 35-vs-25 comparison); there is no plan to
revisit it without a new reason.

**How to test this properly:** any future attempt at 25 or below needs a timestamped capture so tick
intervals can actually be measured, to pin down the mechanism behind the dropout. Pipe MainStage's
stdout through a timestamping filter before it reaches `/tmp/lua.log`:

```bash
... | while IFS= read -r l; do printf '%s %s\n' "$(date '+%H:%M:%S.%3N')" "$l"; done > /tmp/lua.log
```

then reduce it with the awk one-liner already recorded under
[the sweep plan](#flush_soon_ms-retuning-and-the-sweep-plan) to see whether tick intervals actually
stretch out while playing.

Revert ladder, unchanged from the original plan, if either the documented failure mode or this
dropout symptom reappears at a future step: 25 -> 35 (settled) -> 50 -> 100 (original floor, last
known-good).

### Per-region coalescing under rapid navigation

Measured on hardware: rapid patch navigation queued 4, 5, 6, 7, then 10 messages in a row — at one
message per ~100ms flush at the time, some rows were never painted before the next patch superseded
them, i.e. the black-rows bug. Fix: `queue_message()` coalesces by `regionId` — a newer paint for a
region already queued *replaces* the queued entry in place, rather than piling up behind it or (the
earlier approach) throwing everything away via `drop_queued_display()` and re-queuing from scratch,
which was its own treadmill under rapid changes. Position is preserved deliberately: the SL88 paints
strictly in message order with no layers, so an update to one region must not reorder relative to
regions queued around it (a row's backing rect before its text, for instance), or draw order could
invert.

---

## The session clock and the one-shot timer

### `settriggertimer` is a one-shot, and does not self-renew from inside the tick handler

Established on hardware 2026-08-19. `settriggertimer` does not re-arm when called from inside
`controller_timer_trigger` — that callback fired exactly once per script instance no matter what,
confirmed by testing it in isolation. It *does* re-arm when called from `controller_midi_in`,
`controller_select_patch`, `set_display_mode`, and the button handlers (the VAX77 reference
implementation, the one reference script using a repeating timer, arms it from `controller_midi_in` for
exactly this reason).

So the heartbeat the script relies on is: timer tick → send keepalive + Identification Query → keyboard
replies → that reply lands at `controller_midi_in` → re-arm → next tick. Without the query, there is
nothing to reply to, the chain stops after one tick, and the SL88 drops the host from its APP list after
~5s — the "showed up briefly, then disappeared" symptom. This is why `flush_pending(true)` always
reserves budget for the query and why the query is exempt from `displayFlushReady` gating.

### Rule 6: notes starve the clock

Established on hardware 2026-08-20. `controller_midi_in` calls `rearm_timer()` on *every* inbound MIDI
event, including every note on/off, not just SL frames. `settriggertimer` is a one-shot: each call
cancels and restarts whatever is already pending. While the user plays, notes arrive far faster than the
timer period, so an ungated `rearm_timer()` call there just kept cancelling and restarting the pending
timer — `controller_timer_trigger` never fired. No tick meant no keepalive, and the SL88 drops a host
that goes quiet for ~5s. This explained a symptom that had looked unrelated to timing: the display
dropping out *while playing* and recovering the moment playing stopped.

Fix: `timerPending`, gating every `settriggertimer` call. `rearm_timer()` only calls `settriggertimer`
when `timerPending` is false, and sets it true when it does. `controller_timer_trigger` clears it at its
own top (the one-shot has just fired, so nothing is outstanding). Every direct `settriggertimer` call
site keeps this flag honest:

| Call site | Sets `timerPending = true`? | Why |
|:---|:---|:---|
| `controller_initialize` | Yes | First arm for a fresh instance; nothing was outstanding before it |
| `controller_timer_trigger`'s own top-of-function call | **No** | Confirmed on hardware to be a no-op from inside itself — see above |
| `handle_identification_rejected`'s `REIDENTIFY_WAIT_MS` arm | Yes | Genuinely arms a fresh one-shot |
| `rearm_timer()` (all three branches) | Yes | The ordinary re-arm path |

### Quick-rearm (2026-08-21)

`timerArmedInterval` tracks which interval the *currently outstanding* one-shot was armed at
(`KEEPALIVE_MS`, `FLUSH_SOON_MS`, `POPUP_TICK_MS`, or `REIDENTIFY_WAIT_MS`). Measured in `/tmp/lua.log`:
a patch change queued right after an idle tick (session sitting on an outstanding `KEEPALIVE_MS` timer,
nothing to drain) waited a full ~2s for its first flush — `rearm_timer()` refuses to touch the timer at
all while `timerPending` is true, so display work queued right after that just sat until the long
one-shot expired on its own, even though `FLUSH_SOON_MS` (draining pace) is what it actually needed.

`request_quick_rearm()` is the fix: called once per queueing burst from the paths that queue display
work (`controller_select_patch`'s update, `set_display_mode`, the button handlers — deliberately *not*
`queue_message()` itself, which would fire it many times per repaint), it shortens an outstanding timer
to `FLUSH_SOON_MS` when currently armed at either long interval. Confirmed on hardware the same day:
`settriggertimer` genuinely re-arms when called from these sites (same as from `controller_midi_in`) —
every quick-rearm log line that day was followed by a timer tick ~55ms later, not ~3s. Cross-check via
`grep '[sllink] quick-rearm' /tmp/lua.log` against the following timer-tick line.

The `POPUP_TICK_MS` branch (2026-08-27) was a follow-on fix: without matching that interval too, a
second encoder move landing while a `POPUP_TICK_MS` wait was already pending (continued scrubbing
within the same ~1s dismiss window) would fail the guard and wait out up to ~1000ms instead of being
shortened — a responsiveness regression versus pre-popup-tick behaviour.

### The unconditional keepalive

Second fix from the same 2026-08-20 hardware session as rule 6. `controller_timer_trigger`'s keepalive
used to be gated on `not has_pending()`, on the theory that bundling a System Device Notification into
the same array as a Write Text makes the SL88 discard the drawing. That theory was correct — measured
repeatedly, a repaint drained as:

```
F1 [clear, text]            -> rendered
F2 [text, query 7F/03]      -> rendered
F3 [text, keepalive 00/00]  -> NOT rendered
```

— but gating the keepalive on an *empty* queue was the wrong fix for it. A display message paces at one
per tick (`displayFlushReady`), so a multi-message repaint can leave `has_pending()` true for several
ticks in a row — and for every one of those ticks, no keepalive went out either. That's a second,
independent route to the same ~5s APP-list timeout rule 6 fixes: a mid-repaint session could starve the
keepalive without a single note being played.

Fix: send the keepalive unconditionally on every keepalive-cadence tick. Safe because `send_keepalive()`
queues a protocol message (`regionId` nil), and `flush_pending()` never gates non-display messages
behind `displayFlushReady` — they dequeue every flush regardless (DEFECT B's scan-forward fix), jumping
ahead of any display backlog if necessary. `has_keepalive_queued()` guards against pile-up: protocol
messages are deliberately never coalesced (two Identification Queries must both survive), so without
this guard a keepalive queued-but-not-yet-flushed would get another one appended behind it on every
subsequent tick, growing without bound.

### Timer watchdog: a lost one-shot latches `timerPending` forever (2026-09-07)

Captured on hardware: a run stopped dead at `timer tick #352` and never ticked again, while 83 further
inbound SysEx frames were handled normally afterward (CC batches still went out). No keepalive followed,
so the SL88 dropped the app after its ~5s timeout, and the script could not recover on its own —
MainStage had to be restarted.

Mechanism, read from the code rather than guessed: at tick #352 the queue was still non-empty, so
`rearm_timer()` armed a `FLUSH_SOON_MS` one-shot and set `timerPending = true`. MainStage never
delivered that one-shot — for reasons outside this script's visibility, the same way rule 6 assumes
`settriggertimer` always fires but this run shows it sometimes doesn't. `rearm_timer()` returns early
whenever `timerPending` is true, and the ONLY place that clears it is the top of
`controller_timer_trigger`. With the one-shot lost, nothing was ever going to call that function again,
so `timerPending` stayed true permanently and every subsequent `rearm_timer()` call — from the 83 frames
that kept arriving — hit the early return and did nothing.

Ruled out: a Lua error inside the tick handler throwing before it finished. `timerPending = false` is
the first statement in `controller_timer_trigger`, before anything that could error, so an exception
anywhere later in that function would still have cleared the flag.

Fix: a frame-count watchdog, not a shorter timer (shortening `FLUSH_SOON_MS` would revive rule 6's
notes-starve-the-clock failure for legitimate cases where a one-shot is genuinely still outstanding).
`framesSinceTick` counts inbound events since the last tick, incremented at the top of
`controller_midi_in` (every event, not just SL frames, so it also counts while nothing decodes) and
reset to 0 by `controller_timer_trigger`. `rearm_timer()`'s `timerPending` guard now returns early only
while `framesSinceTick < TIMER_WATCHDOG_FRAMES`; past that it falls through, force-arms a new one-shot,
and resets the counter so it can't fire again on the very next frame.

`TIMER_WATCHDOG_FRAMES = 300` never fired on hardware — the threshold was far too high relative to what
actually separates the two regimes. A later pass across three captures measured the gap between
consecutive HEALTHY ticks directly: across roughly 2,100 tick intervals it never exceeded 4 inbound
frames. In the two captures where the clock died, 83 and 76 frames arrived after the final tick with no
tick ever following. Healthy and pathological are separated by more than an order of magnitude (4 vs.
76-83), so `TIMER_WATCHDOG_FRAMES` was retuned to **20** — comfortably above the observed healthy max,
far below the observed failure range.

Caveat that shapes the design: those counts come from log lines, and the script logs ONLY SysEx —
note/CC musical traffic is invisible in the log but DOES increment `framesSinceTick`. So the real
worst-case frame gap while the user is playing is unknown and could exceed 4. A threshold of 20 alone
would risk rule 6 (re-arming during dense play cancels-and-restarts the pending one-shot and starves the
clock) if a normal, still-outstanding one-shot ever coincided with that much uncounted note traffic.

The distinguishing signal that makes a low threshold safe is queued, undrained output: in BOTH freezes
there was queued display work (`pending=1`, `pending=2`) that could not drain — display messages are
gated behind `displayFlushReady`, which only a tick grants, so a dead clock leaves the queue stuck.
Playing notes with an idle display does not produce that state. `rearm_timer()`'s watchdog fallthrough
is therefore gated on `has_pending()` in addition to the frame count: it may only force a re-arm when
there is queued output stuck behind the dead clock. With nothing queued, the early return still applies
regardless of `framesSinceTick`, so a long run of uncounted note traffic during a legitimate outstanding
one-shot can never trip the watchdog.

The `STATE_REIDENTIFY_WAIT` early return in `rearm_timer()` sits ABOVE this guard and is checked first,
unconditionally — the watchdog must never shorten that wait (see `handle_identification_rejected`).

---

## Identification and instance-ID collisions

MainStage tears the script down and re-initialises it repeatedly (observed: init → finalize → init →
... within seconds, partly because the script is loaded once per matched USB-MIDI interface). A
MainStage-driven re-init resets `instanceID` back to `SL_INSTANCE_START` — and, historically, the SL88
kept holding the *previous* incarnation's registration under that same id regardless, because
`controller_finalize` sent no Logout Request. See
[`controller_finalize` sends no Logout Request](#controller_finalize-sends-no-logout-request) for the
current status — as of 2026-09-10 it sends one again, on the hypothesis that this collision source is
now fixed at the root rather than merely worked around by the wait/retry below.

The naive fix — bump the instance byte immediately on rejection — "solves" the rejection by registering
as a *different* app, which silently loses the user's APP-list selection: this was the actual cause of
an earlier symptom where the user's app choice on the SL88 kept getting lost.

### `REIDENTIFY_WAIT_MS` derivation

Instead: wait out `REIDENTIFY_WAIT_MS` (6000ms, comfortably longer than the keyboard's ~5s host
timeout) for the stale registration to expire on its own, then retry the *same* id — reclaiming the
script's own identity rather than creating a new one. Only after `MAX_SAME_ID_RETRIES` (2) failed
retries — by then plausibly a genuine collision, e.g. the *other* script instance loaded for the other
USB-MIDI interface, which is actually alive and keepaliving and will reject every retry — does it fall
back to bumping the instance byte, as before.

This is why the `STATE_REIDENTIFY_WAIT` timer must never be shortened: `rearm_timer()` and
`request_quick_rearm()` both special-case this state and refuse to touch the timer while it's pending,
specifically so nothing overwrites the wait with `FLUSH_SOON_MS`/`KEEPALIVE_MS` before the SL88's own
timeout has actually elapsed.

### `controller_finalize` sends no Logout Request

**Status (2026-09-10): reverted again, same day.** Retried sending the Logout Request (below) on the
hypothesis that per-instance DeviceIDs (see
[Per-instance starting id](#per-instance-starting-id-2026-09-10)) had fixed the root cause. On hardware
this made things worse: an instance was seen APPROVED and then immediately logging
`-> LOGOUT REQUEST from controller_finalize`, the app never appeared in the SL88's APP list, and the
Master Volume popup stuck on `--` with a dead encoder downstream of the session never registering
properly. Per-instance ids made the old failure mode worse, not better: a re-init used to reclaim the
same id, so the APP-list entry effectively returned after a spurious teardown; now each incarnation
derives a different id, so it never does. The *mechanism* is proven regardless — the device answered
`00 03` LOGOUT CONFIRMATION, disproving the original "no return path" claim below — it's the effect on
the APP list that fails. `controller_finalize` is back to sending nothing (see the function itself).

**Prior status (2026-09-10, superseded by the above): sends one again.** As of this date,
`controller_finalize` sends a Logout Request again — see
`msg_system(SYS_LOGOUT_REQUEST)` returned from that function. Confirmed on hardware the same day: real
identification traffic showed one incarnation APPROVED and its ghost's successor REJECTED, with the
rejected one doing all the real work under an id it didn't own — a direct, reproduced instance of the
collision this history section describes. This section's original claim that finalize "has no return
path with which to send a Logout Request" was simply wrong: the Launchkey MK3 reference script (see
`docs/mainstage-device-scripts.md` §10) returns MIDI from its own `controller_finalize` to leave DAW
mode, and works. The fix here follows the same mechanism.

**Original finding, and why the revert below no longer necessarily applies.** An earlier version of
`controller_finalize` sent a Logout Request. Because MainStage tears the script down and re-initialises
it repeatedly, every one of those spurious teardowns actively removed the app from the SL88's APP list
— guaranteeing the "showed up briefly, then disappeared" symptom on its own, independent of the timer
bugs above. Staying quiet let the APP-list entry survive a churn; if the script really was going away
for good, the keyboard's own ~5s keepalive timeout removed it anyway.

That revert happened while the session machinery was still broken: the keepalive was dying (see the
timer watchdog and rule-6 fixes above) and identification approvals were being lost in MainStage's init
window (see
[Identification approval and rejection are lost in MainStage's init window](#identification-approval-and-rejection-are-lost-in-mainstages-init-window-2026-09-10)),
so once a spurious teardown's logout removed the APP-list entry, nothing was left running to
re-establish it. Both of those are now fixed. Whether the original failure mode still reproduces is a
hypothesis, not a given — watch for the "showed up briefly, then disappeared" symptom specifically on
the next hardware run of this change, and revert again if it does.

### Single instance confirmed on hardware (2026-08-28)

The "loaded once per matched USB-MIDI interface" explanation above was carried as *the* cause of the
repeated `controller_select_patch` calls and the finalize/initialize churn. A full hardware session
(MainStage + SL88 MK2, logged to `/tmp/lua.log`) shows it did not hold on this run — the script ran as
exactly **one** instance:

- Only one `instanceID` was ever used (`03 6D`). A second concurrent instance would identify with the
  same `SL_INSTANCE_START` and get rejected; nothing was.
- **Zero** `IDENTIFICATION REJECTED` messages appear in the log.
- 3,593 timer-tick lines carry 3,593 *distinct* tick numbers. Two instances each own their own Lua
  globals, including `timerTicks`, so concurrency would show two independent counters' values
  interleaved — duplicates, not a clean sequence.
- `controller_initialize`/`controller_finalize` each fired exactly twice, matching the documented
  init → finalize → init churn pattern — one lifecycle churning, not two running side by side.

The SL88 exposes three port pairs (`SL CTRL`, `SL DAW`, `SL LINK` — confirmed by the sniffer
enumerating all three), which is exactly the situation §8 of `docs/mainstage-device-scripts.md` warns
can yield two or three script instances. It didn't here: all five `controller_info()` entries declare
`inport='LINK'`/`outport='LINK'`, so only the LINK pair ever matched.

This is one observation on one MainStage version, one macOS version, one keyboard USB mode — not proof
the multi-instance scenario can't happen elsewhere. The repeated calls and the finalize/init churn are
real regardless of instance count and still need their guards; only the *per-interface* explanation for
them is now unconfirmed. `SL_INSTANCE_START`'s bump-on-rejection, `REIDENTIFY_WAIT_MS`,
`MAX_SAME_ID_RETRIES` and the `controller_select_patch` early-out all stay as defence against a scenario
that simply didn't materialise this time.

---

## The scroll and page-jump derivation

### `SCROLL_MARGIN` and the worked example

`SCROLL_MARGIN = 2`, not 1. The requirement (Jeroen's): at least one patch *after* the current one is
always visible, so you can see what you're changing to. A margin of 1 isn't sufficient in a continuous,
interleaved list where set headers occupy rows: it could leave the single visible row below the current
patch being a set *header*, telling you the song ended but not what plays next. A margin of 2 guarantees
a real patch is visible even at a set boundary.

Worked example: consider a set boundary where the current patch is the last patch in its set, followed
immediately by the next set's header row, followed by that set's first patch. With `SCROLL_MARGIN = 1`,
the one row of context below the current patch could land exactly on the header row — no patch visible.
With `SCROLL_MARGIN = 2`, the window always carries the header *and* the next patch, satisfying the
requirement regardless of where the boundary falls relative to the window.

### `PAGE_OVERLAP` derivation and the oscillation trace

`PAGE_OVERLAP = 2 * SCROLL_MARGIN` (4, with `SCROLL_MARGIN = 2`) is derived, not picked. The landing
spot after a page jump is not a free choice once `SCROLL_MARGIN` and `ROW_COUNT` are fixed. Landing the
cursor right at the edge it jumped *to* (the smallest possible overlap, the first instinct) puts it back
inside the *opposite* margin's trigger zone.

A harness sweep (walking `cursorIndex` forward one row at a time over a synthetic list — the same shape
now codified as `Tests/lua/harness.lua`'s clamp_scroll test) caught this concretely: five page jumps
fired back to back, because a forward jump landing at row 0 is, by definition, within `SCROLL_MARGIN` of
the *top* edge — so the very next single-row step re-triggers a *backward* jump, landing at the last
row, within `SCROLL_MARGIN` of the *bottom* edge, re-triggering forward again. That oscillation is a
worse version of the exact bug page-jumping was meant to fix, not a smaller overlap.

The only landing spot safe from both margins at once is `SCROLL_MARGIN` rows in from the edge just
crossed, which forces `PAGE_OVERLAP = 2 * SCROLL_MARGIN` — 4 rows, not the 1–2 first assumed. With
`ROW_COUNT = 8` and `SCROLL_MARGIN = 2`, that's 4 safe single-row steps before the next trigger — roughly
one jump every five advances during ordinary monotonic browsing, not one every single advance.

### The one-row shift, abandoned

See [Rejected approaches](#rejected-approaches).

---

## Zoom-screen typography and truncation

### Settled facts: Max Width and the Write Text background box

Confirmed on hardware, and depended on throughout the file:

- **Max Width truncation works reliably at `SIZE_SMALL`.** Every list row (`draw_list_row`) trusts a
  real, non-zero `ROW_MAXW` and lets the SL88 truncate + ellipsize on its own.
- **Write Text's opaque background fills the entire Max Width box, not just the glyph run it actually
  draws.** Confirmed twice: an empty string drawn with a coloured background still painted a visible
  full-width bar, and a calibration screen's bands spanned the full screen width regardless of content.
  This is what makes every list row self-clearing at a constant `x`/`maxWidth` (no erase rect ever
  needed on the list screen — a row that goes blank still overwrites whatever was there), and what makes
  inverse-video row highlighting cost exactly one message with no backing rectangle.
- **At `maxWidth = 0` ("print it all"), the background box shrinks to just the glyphs actually drawn.**
  This is *not* a variant of the rule above — it's the reason `draw_text_with_erase()` exists at all;
  see [Max Width truncation broken at `SIZE_BIG`](#max-width-truncation-broken-at-size_big) below.

### Max Width truncation broken at `SIZE_BIG`

Found on hardware 2026-08-19: a long patch name at `SIZE_BIG` with `maxWidth = 304` rendered as a
**single letter** followed by `...`. The SL88's own Max Width truncation is unreliable at big size, so
the zoom screen's patch name (`zname`) and set name (`zset`) truncate themselves in Lua
(`truncate_text()`) and draw at `maxWidth = 0` instead of trusting the device.

A follow-up attempt on 2026-08-20 tried wrapping the name across two lines instead of truncating it —
this instead left stale text on the second line: a shorter name replacing a longer one did not fully
overwrite the old line's glyphs (a consequence of the `maxWidth = 0` background-box behaviour above,
before `draw_text_with_erase()` existed to fix it). Reverted to one truncated line.

`BIG_MAX_CHARS = 27` is hardware-calibrated by eye, not measured from real glyph metrics: "C05 Brassy
Trombones" (20 characters) was confirmed to render in full at `SIZE_BIG` across the zoom screen's width,
and 27 was chosen with margin beyond that. `MEDIUM_MAX_CHARS = 36` follows the same by-eye approach for
`zset` (the one remaining `SIZE_MEDIUM` user — `znext` moved to `SIZE_SMALL` + trusted Max Width on
2026-08-21, cutting it from 2 queued messages to 1 since it no longer needs character-count truncation).
Retune both by eye, against a name a few characters either side of the constant, if the screen geometry
or font ever changes.

### Manual centering at `maxWidth = 0`

Found on hardware 2026-08-21: every zoom-screen line was supposed to be centred, but `zset`/`zname`
rendered off-centre while lines drawn at a real `maxWidth` (`zcnc`, `znext`, `zpos`) looked right.
Confirmed against the pinned upstream spec (`sl-link/docs/display-messages.md`, fetched fresh at the
pinned commit rather than assumed): "In the selected area (the area between (X, Y) and (X + Width, Y))
the string can be justified to the left, right or centre..." — alignment is defined *relative to that
Width-wide area*. At `Width = 0` the area collapses to the single point X, leaving `ALIGN_CENTER`/
`ALIGN_RIGHT` nothing to justify within — which is exactly the observed symptom: the string draws pinned
at X regardless of the alignment byte, i.e. visually left-anchored.

`zname`/`zset` must keep `maxWidth = 0` — that's the whole reason `draw_text_with_erase()` needs an
explicit erase rect at all — so switching to a real `maxWidth` to get alignment "for free" would risk
reintroducing the `SIZE_BIG` truncation bug above. Centring is instead computed in Lua
(`estimate_text_width_px()`): estimate the string's rendered pixel width, pick an X that lands it in the
middle of the screen, and draw `ALIGN_LEFT` at that X — the one deterministic choice once `maxWidth` is
0.

### `CHAR_WIDTH` calibration

`CHAR_WIDTH_BIG = 11` is derived from `BIG_MAX_CHARS` itself (`floor(304 / 27)`), not picked
independently. `CHAR_WIDTH_MEDIUM` was originally scaled from it via the size table's pixel heights
(33px/22px), giving 7 — already flagged as narrower than the ~27px `docs/implementing-sl-link.md`
estimates for `SIZE_MEDIUM` — and confirmed too narrow on 2026-08-27: the Zoom-mode `zset` title
rendered slightly right-of-centre at 7, so it was retuned to 8 (closer to the un-floored
`7.33 = 11*22/33`). No real glyph-metrics table exists for this font; both constants are eye-calibrated
the same way as `BIG_MAX_CHARS`/`MEDIUM_MAX_CHARS` — retune together if geometry or font changes.

### Zoom-screen centring moved to the device (2026-08-29)

A hardware report: both `zset` (the set name) and `zname` (the patch name) rendered slightly too far
**right** on the zoom screen. `CHAR_WIDTH_MEDIUM` had already been retuned once for exactly this
symptom, from a derived 7 to an eye-calibrated 8 (see [`CHAR_WIDTH`
calibration](#char_width-calibration), 2026-08-27) — so a second retune of the same constants would
have been a third guess at the same estimate, not a fix. The arithmetic in
`estimate_text_width_px()`/`draw_text_with_erase()` was checked and is self-consistent: it always
places the *estimated* centre at `x=160`. That pins the bug on the per-character-width constants
themselves — the real glyphs are wider than either estimate — which is exactly the class of problem
an eye-calibrated guess can't close reliably: there was no way to know the next guess would be right
either.

**The fix: stop estimating.** `zset`/`zname` moved from `maxWidth = 0` (manual `ALIGN_LEFT` centring
at a Lua-computed X, the only option available at `maxWidth = 0` — see [Manual centering at `maxWidth
= 0`](#manual-centering-at-maxwidth-0)) to a real, non-zero `maxWidth` with the device's own
`ALIGN_CENTER`, matching the convention `znext` and every list row already use. No estimate, no
manual X — the device centres exactly, because centring within a real width-bound area is precisely
what `ALIGN_CENTER` is defined to do (see that same section's citation of the upstream spec).

**Evidence this works, from elsewhere in this same file:** the encoder value popup's `popupLabel` and
`popupValue` (`draw_popup_label()`/`draw_popup_value()`, both `SIZE_MEDIUM`) already draw with a real
`maxWidth` and `ALIGN_CENTER`, and were confirmed correct on hardware the same day (2026-08-29, see
[The Knob bitmap replaces the ring](#the-knob-bitmap-replaces-the-ring-2026-08-29)). `znext` and every
list row have likewise trusted a real `maxWidth` at `SIZE_SMALL` since before this fix, with no
reported centring or truncation complaint. Device-side centring was therefore already proven at the
sizes this migration needed; the zoom screen was the one holdout still estimating in Lua.

**Confirmed on hardware 2026-08-29** (SL88 MK2 + MainStage): `zset` and `zname` now render correctly
centred — the too-far-right symptom is gone. Long patch names truncate with a visible `...` and no
single-letter failure. `LUA_DEBUG` capture: 255 ticks, **0 Lua errors, 0 STANDBY, 0 identification
rejections**. All five zoom regions were emitted (`zcnc` 7, `zset` 14, `zname` 17, `znext` 17, `zpos`
16), and **zero** `regionId=z*:rect`/`z*:text` split-id messages appeared on the wire, confirming the
erase-rect path described below is gone. The same build carried `FLUSH_SOON_MS = 35` (see
[`FLUSH_SOON_MS` retuned to 35](#flush_soon_ms-retuned-to-35-2026-08-29)); the dropout-while-playing
seen at 25 did not recur.

**The durable win is the removed estimate, not the message count.** This fix deletes
`CHAR_WIDTH_BIG`/`CHAR_WIDTH_MEDIUM` outright (see "What this removed" below) — constants that had
already needed eye-recalibration twice (`CHAR_WIDTH_BIG` derived at 11; `CHAR_WIDTH_MEDIUM` retuned
from a derived 7 to an eye-calibrated 8, see [`CHAR_WIDTH` calibration](#char_width-calibration)) and
would, on this run's evidence, have needed a third guess to close the same right-of-centre symptom.
Trusting the device's own `ALIGN_CENTER` replaces that guess with exact centring instead of a better
guess — a stronger result than the two fewer flushes per repaint noted below.

**Truncation is a separate device feature, and stays broken — do not read this run as evidence
otherwise.** Max Width *truncation* (cutting a string to fit visually, appending `...`) is confirmed
broken at `SIZE_BIG` (a long name once rendered as a single letter plus `...` — see [Max Width
truncation broken at `SIZE_BIG`](#max-width-truncation-broken-at-size_big)). Max Width *centring*
(justifying a string that already fits within its box) is a different code path on the device and was
never implicated in that finding. So `truncate_text(patchName, BIG_MAX_CHARS)` /
`truncate_text(setName, MEDIUM_MAX_CHARS)` still run before every draw, belt-and-braces: pre-truncating
in Lua means the device is never asked to truncate a name itself, regardless of what its centring logic
does. The `...` seen in the 2026-08-29 confirmation run above is `truncate_text()`'s own ASCII ellipsis,
appended before the string ever reaches the device — pre-truncation is exactly what kept the device
from ever being asked to truncate, so this run says nothing about whether the device's own `SIZE_BIG`
truncation bug is fixed. It stays on the books as unresolved. **Revert path:** if a long patch name
ever renders on hardware as a single letter plus `...`, the device's own truncation is firing — go back
to `maxWidth = 0` with manual `ALIGN_LEFT` centring (this section's own git history has the removed
implementation), not another `BIG_MAX_CHARS` retune.

**What this removed.** `draw_text_with_erase()` existed only because `maxWidth = 0` leaves Write
Text's background box exactly as wide as the glyphs drawn, so a shorter name doesn't fully overwrite a
longer one underneath it — it queued an explicit black erase rect ahead of the text as two separate
messages, coalesced under one region id via an `id..':rect'`/`id..':text'` split. A real, non-zero
`maxWidth` makes Write Text's background box fill the *whole* box regardless of glyph run (the same
fact that makes every list row and `znext` self-clearing — see [Settled
facts](#settled-facts-max-width-and-the-write-text-background-box)), so that erase rect — and the
function that drew it — is gone along with `estimate_text_width_px()`,
`CHAR_WIDTH_BIG`/`CHAR_WIDTH_MEDIUM`, and the "MANUAL CENTERING for maxWidth=0 lines" comment block
that explained the old workaround. `base_region_id()` existed solely to unwind that `:rect`/`:text`
split back to the one `drawn[]` entry both halves shared, for `drop_queued_display()` — with nothing
left that produces a split regionId, `drop_queued_display()` now indexes `drawn[]` with `m.regionId`
directly and `base_region_id()` was removed too. `Tests/lua/harness.lua` lost the one test written
against that split-id behaviour and gained a `paint_zoom_screen()` test asserting the new message
shape and that `zset`/`zname` decode as `ALIGN_CENTER` at a non-zero `maxWidth` on the wire.

**Message-count saving.** Each of `zset`/`zname` drops from 2 queued messages (erase rect + text) to
1, so a full zoom repaint (`zcnc` + `zset` + `zname` + `znext` + `zpos`) falls from 7 queued display
messages to 5 — at one display message per flush (`FLUSH_SOON_MS`-paced), two fewer flushes' worth of
latency on every zoom repaint, on top of fixing the reported off-centre rendering.

### Typography substitutions: non-ASCII glyphs

The SLMK2 font covers only `0x20`–`0x80` (`append_text` clamps everything outside that range to a
space). Two design-doc mockups used characters outside it, both substituted with ASCII in the actual
implementation:

- The context bar's "concert · set" separator uses a plain ASCII hyphen (`ctx_text()`, `' - '`), not a
  middle dot (`·`) — a middle dot would render as two spaces.
- The zoom screen's "no next patch" line (`next_line_text()`) uses `'NEXT  --'`, not an em dash (`—`) —
  same reason.

---

## Mode switching and Clear Screen

### The Clear Screen ban and its lift

Clear Screen's original ban (rule 3 in the banner) came from an early finding: including it at the head
of an ordinary repaint reliably lost exactly one later text — a different one each run, even with
message order and flush shape held constant. That randomness read like a race (a full-screen fill
plausibly takes the SL88 longer than a text line, and text arriving mid-fill gets wiped) rather than a
rule about Clear Screen itself. It was later understood to in fact be [DEFECT A](#defect-a-the-ungated-flush-drained-at-round-trip-speed-not-timer-speed)
— the same display-pacing bug `displayFlushReady` fixed, not a property of Clear Screen.

`set_display_mode()` (2026-08-21) is the one deliberate, re-tested exception: with the pacing bug fixed,
a full-screen black `msg_draw_rect` covering a mode switch was found to leave visible text remnants of
the outgoing screen — either the SL88 ignores/drops a rect that large, or paints it too slowly for the
repaint that follows not to race it. Clear Screen was re-tried here specifically, queued as its own
discrete message with no `regionId` (never coalesced, never bundled into an array with a Write Text —
the old failure mode was always a clear bundled with drawing) and paired with a settle guard
(`displaySettleTicks`, since a full-screen clear plausibly takes longer to paint than a text line).
`MODE_SWITCH_SETTLE_TICKS` was raised from 1 to 3 on 2026-08-21 after a report that mode switches —
especially the first one — could leave stale text on screen; a single tick was only ~50–70ms
(`FLUSH_SOON_MS`) of quiet, evidently not enough.

If remnants or dropped lines return on hardware, the documented fallback is reverting to the full-screen
black `msg_draw_rect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 0, 0, 0)` this replaced.

### The double Clear Screen

Found 2026-08-21: mode switches intermittently — in *both* directions, not just the first switch — left
old text on screen. `/tmp/lua.log` traced this to `flush_pending()`: it always appends the
Identification Query to whatever it emits, so the Clear Screen went out bundled with the query in one
MIDI array (confirmed: FLUSH #268, tick=149, 13 Clear Screen bytes + 10 query bytes, one array). That's
the exact shape already on record as unreliable (see
[the `[display, query]` flush shape](#the-display-query-flush-shape) — `[text, keepalive]` in one array
was never rendered either, only `[display, query]` alone or `[display]` first). So the clear itself was
sometimes dropped by the panel, which read back as "old text remains" — a *delivery* problem, not a
settle-timing one (`MODE_SWITCH_SETTLE_TICKS` was already fine).

`flush_pending()` can't be made to emit this Clear Screen alone: the caller that ultimately drains it is
sometimes `controller_timer_trigger` itself, and that function's own `settriggertimer` call is a
confirmed no-op from inside itself — the query's reply landing at `controller_midi_in` is the *only*
thing that re-arms the session clock after such a tick. Dropping the query from that flush risks
stalling the clock for up to `KEEPALIVE_MS` with nothing to rescue it. So instead: queue the Clear
Screen **twice**, as two separate messages with no `regionId` (`queue_message` never coalesces without
one), each earning its own flush. It's idempotent, and a dropped copy costs nothing but one extra
~50–70ms flush. `flush_pending()`'s settle guard resets on every Clear Screen it emits, so the settle
window still lands after the *last* one.

### `MODE_SWITCH_SETTLE_TICKS` lowered to 1 (2026-08-29)

A hardware trace of a popup entry showed 8 ticks of dead time before the first pixel appeared:

```
tick 35  Clear Screen #1 (13 bytes)
tick 36,37,38   nothing drawn - settle guard withholding displayFlushReady
tick 39  Clear Screen #2 (13 bytes)
tick 40,41,42   nothing drawn - settle guard again
tick 43  popupBg  <- first real pixel
```

`set_display_mode()` queues two Clear Screens (see [above](#the-double-clear-screen)); `flush_pending()`
resets `displaySettleTicks` to `MODE_SWITCH_SETTLE_TICKS` on *each* one, so the guard gets paid twice per
switch. At `FLUSH_SOON_MS = 50` that's roughly 400ms of blank screen on every popup entry and again on
every dismissal - reported by the user as "it takes some time before screen redraw starts."

[The double-Clear-Screen entry above](#the-double-clear-screen) already traced the stale-text symptom
that motivated raising this constant from 1 to 3 to a *delivery* problem - the clear going out bundled
with the Identification Query, a flush shape already on record as unreliable - and states explicitly
that the settle timing "was already fine" at 1. The 2026-08-21 raise to 3 was therefore treating a
symptom whose real cause got fixed separately, by queueing the clear twice. The first clear's settle is
also nearly pure waste on its own terms: it only delays the *second* clear, which is itself gated by the
same guard.

Lowered `MODE_SWITCH_SETTLE_TICKS` from 3 to 1 on this basis. **Confirmed on hardware 2026-08-29**
(SL88 MK2 + MainStage, LUA_DEBUG capture, 210 ticks / 4 popup entries / 10 mode switches / 12 knob
bitmap draws / 0 Lua errors): dead time from the first Clear Screen to the first popup pixel dropped
from 8 ticks to 4, measured at every popup entry in the run (ticks 16->20, 83->87, 129->133 - all
exactly 4). At `FLUSH_SOON_MS = 50` that's roughly 400ms down to 200ms. No stale text was observed on
either the popup or the Zoom-button zoom<->list toggle, including the first switch after login - the
case the original raise to 3 was meant to protect. The reasoning above - that the double Clear Screen
already fixed the delivery bug the raise to 3 was compensating for, making the wider settle
unnecessary - is vindicated by this result.

Revert ladder, unchanged, if stale text or dropped lines ever reappear on a mode switch: try 2 first;
3 is the last known-good value.

### FIX 5 audit: the first-switch anomaly

See [Open questions](#open-questions).

---

## `drop_queued_display` and the memo-vs-screen divergence bug

Found on hardware. `draw_text`/`draw_rect` record `drawn[id]` the moment they *queue* a message, not
when it's actually sent — but `drop_queued_display()` can discard that same message before it ever goes
out (used when `set_display_mode()` switches modes: anything still queued for the outgoing mode cannot
be coalesced into anything the new mode will ever draw). Left alone, `drawn[id]` permanently claims the
region was painted, so it's never re-queued: the memo and the physical screen diverge for good.

This one bug explained three separate symptoms seen on the SL88, previously investigated as if they
might be unrelated: rows that should have reverted from orange (active) to grey (inactive) staying
orange forever; a re-selected row that looked like it "toggled" instead of just re-selecting; and rows
left blank/black after a repaint raced a drop.

**Fix:** `drop_queued_display()` undoes the memo for exactly the id(s) it discards
(`drawn[base_region_id(m.regionId)] = nil`), so the next paint re-queues them. `base_region_id()` exists
because `draw_text_with_erase()` splits one logical id into two queued messages (`id..':rect'` /
`id..':text'`) for its coalescing keys — `drop_queued_display` needs to find its way back to the single
`drawn[]` entry both halves share regardless of which suffix a given queued message carries.

---

## The trailing sacrificial redraw

Empirically, the **final** flush of a repaint never takes effect: whichever display message ends up
last is silently lost, and swapping the draw order just moves the loss to whatever is now last. It's not
about the message's content, size, position, or what it's bundled with — a lone 43-byte Write Text as
the last flush is dropped just the same as one paired with a keepalive. Anything with a further
transmission after it renders reliably.

Fix: end any real screen update with a harmless duplicate — re-drawing the concert line (`zcnc` in zoom
mode, the context bar in list mode) is idempotent (identical pixels, same coordinates), so it costs one
extra message and is safe to lose, which it duly is, while everything that matters now has something
following it.

This originally lived only at the end of `paint_screen()`'s full repaint, on the theory that only a
full, `invalidate_all()`-preceded repaint was at risk. That theory didn't hold — the drop was never
shown to depend on message count or size, only on being last in a flush — so `update_screen()` (ordinary
content-driven redraws) and `set_display_mode()` (mode switches) both needed the same insurance and now
carry it too. All three gate the call on having actually queued something real: an all-memoized no-op
call has no "last real message" that needs a harmless successor.

The message is built and queued directly, bypassing `draw_text()`, and deliberately with **no**
`regionId`. The real `ctx`/`zcnc` draw almost always sits earlier in this exact same paint's queue —
routing the sacrificial redraw through `draw_text('ctx', ...)` would hand it that *same* `regionId` and
coalesce it into the earlier entry instead of appending a distinct trailing message, collapsing the one
thing this mechanism exists to guarantee (a disposable duplicate strictly *after* everything real) back
into whatever position the real draw happened to queue at. A nil `regionId` always appends, which is
exactly "trailing".

---

## The encoder value popup: v1-v5

Turning any mapped encoder shows a transient panel with the CC number (small, dim) and the 0–127 value
(big, centred), ringed by a segmented LED-style dial, so both are visible without a MainStage round-trip.
`controller_midi_out` was confirmed on hardware to report `nil` name/valueString/color for the mapped CC
itself, so the popup never attempts to show a MainStage parameter name — only the CC number and value,
both already known locally via `CC_MAP`/`ENCODER_CC`/`encoderValue`. For the feature's current design and
hardware status, see `docs/mainstage-integration.md`'s "Encoder value popup" section; this is the visual
and structural history behind how it got there.

- **v1** — a ring with no centred value.
- **v2** (hardware-tested) — dropped the ring for a plain amber-filled rect with a centred number,
  copying the Swift companion app's `SLLinkDemoScreen` zone panels. Read as "screaming" at full-panel
  amber.
- **v3** — combined both: a calm black panel, an orange ring whose lit-segment count encodes the value
  at a glance from across the room, *and* the exact numeric value legible in the ring's centre.
- **v4** — visual pass to match the SL88's own native firmware overlays (its AUDIO MASTER/ZONE LEVELS
  screens) rather than v3's invented "12-segment full-circle dial" look: more, thinner segments
  (12→20, 6px→3px) for a smoother ring; a 60° gap centred at the bottom like a real gauge instead of a
  closed circle; a lighter unlit-track colour (was near-invisible dark grey, now visible light grey);
  a neutral light border colour instead of reusing the ring's orange. Lit colour stayed orange — that
  already matched the reference.
- **v5** — promoted from a small 160×160 card floating *over* list/zoom content to a genuine
  full-screen-takeover mode (`displayMode = 'popup'`, alongside `'list'`/`'zoom'`), modelled on the
  SL88's own native AUDIO MASTER overlay. This sidesteps the entire v1–v4 placement trade-off: with no
  content underneath to protect, `dismiss_popup()` can reuse `set_display_mode()`'s proven double-Clear-
  Screen/invalidate sequence instead of the old ad-hoc `invalidate_all()` + `paint_screen()` pair. Card
  grown to 280×200 (20px margin on a 320×240 screen) and the ring/value geometry re-derived for the
  bigger card (below).

The v1–v4 placement trade-off, now moot: centred on screen was chosen over a top-right corner because no
placement was free of both list-mode and zoom-mode's full-width erase rects — both screens' erase calls
span edge-to-edge — so overlap with underlying content was unavoidable either way, and a centred popup
at least read as a deliberate modal rather than a corner decoration. The accepted cost was that
`dismiss_popup()` only invalidated the popup's own ids, never the content it covered, so a stale panel
could linger until whatever sat underneath next redrew for its own reason. v5's full-screen-mode
approach removed the need for this trade-off entirely.

### Popup ring geometry derivation

Radius, segment size, count and sweep were chosen so that every one of the 20 segment positions clears
(a) the value text's bounding box, (b) the panel border's inner edge, and (c) the label's bottom edge —
checked programmatically for the exact numbers below (all 20 segment positions checked against both
boxes for rectangle overlap). Re-run that check if any of `POPUP_W`/`POPUP_H`/`POPUP_RING_RADIUS`/
`POPUP_SEG_SIZE`/`POPUP_SEG_COUNT` change.

The ring doesn't close a full 360°: `POPUP_SWEEP_DEG = 300` leaves a 60° gap centred at the bottom (90°,
6 o'clock), gauge-style, matching the SL88's native overlay screens. Segments are spaced evenly across
the sweep via `POPUP_SWEEP_DEG / (POPUP_SEG_COUNT - 1)` so the first and last segments land exactly on
the sweep's two endpoints (120°/60° from the top), keeping the gap exactly 60° wide and centred.

Radius grew 48→68 and segment size 3→5 for the bigger v5 280×200 card (v4's 12→20 count / 6→3 shape
change already fixed the segment shape; this scales the two size numbers up for the extra room).

Tightest clearances at the current numbers: segments 1 and 20 (angles 120°/60°, nearest the bottom gap)
clear the panel border's inner edge (x:24–296, y:24–216) by 15px. Segments 3 and 18 (~135.8°/~44.2°,
just above the value box's top corners) clear the value box (x:110–210, y:120–160) by 9px on the
separating axis — comfortably more margin than the old 160×160 card's 1px worst case, since the card
grew faster than the ring did. Every other segment clears both boxes by a wider margin still.

The ring/value vertical centre (`POPUP_CENTER_Y = POPUP_Y + 120`) is deliberately not the card's raw
midpoint (`POPUP_Y + POPUP_H/2 = POPUP_Y + 100`): shifted down so the label has headroom above the ring
without shrinking the ring to match a symmetric top/bottom margin it doesn't need — the label only ever
occupies the card's top, so the bottom margin can stay tighter than the top one.

Lit-segment count scales by `value / 127` (not `/ 128`), so `value = 0` lights zero segments and
`value = 127` — the actual maximum — lights all 20 exactly, rather than topping out at 19 the way a
`/128` divisor would (`127/128*20 = 19.84`, floors to 19).

### The Knob bitmap replaces the ring (2026-08-29)

v5's hand-drawn 20-segment ring is gone. Plot Bitmap and the Knob icon group (`BMP_GROUP_KNOB`,
icons `0x00`–`0x0C`, 61×54 px, a filling ring gauge with device-side gradient colouring) were
verified on hardware — see `docs/implementing-sl-link.md` §5 — closing the question the
`BITMAP_PROBE` scaffolding existed to answer, so that scaffolding (the constant, the probe grid
screen, the `handle_login` branch, the harness assertion pinning it false) is removed along with the
ring. The popup is now three stacked, non-overlapping bands: the control's name and CC number
(`SIZE_MEDIUM`, e.g. `ENC 1 - CC 59`) above a single centred Knob bitmap, and the 0–127 value
(`SIZE_MEDIUM`, white) below it — not inside it, because a 61×54 icon cannot host a legible
`SIZE_BIG` number the way the old ring's open centre could.

This collapses `paint_popup_screen()`'s message count from 27 (bg + 4 border strips + label + 20
ring segments + value) to 8 (bg + 4 border strips + label + knob + value) — a ~70% cut, all still
inside `FLUSH_BUDGET` per message. The value/knob-index mapping keeps the old ring's `/127`-not-
`/128` reasoning: `math.floor(value * (BMP_KNOB_LEVELS - 1) / 127)` so `value = 0` selects icon 0
(empty) and `value = 127` — the actual maximum — selects icon `0x0C` (full) exactly, the same
endpoint-correctness argument as the ring's lit-segment count above, just against 12 icon steps
instead of 20 segments.

This closes out the v1–v5 popup history above — the popup's visual design is now the Knob bitmap
described here, not the ring.

---

## Rejected approaches

**Space-padding to a constant character count** (found broken 2026-08-20; do not reintroduce). The fix
attempt for the `maxWidth = 0` stale-tail bug (see
[Max Width truncation broken at `SIZE_BIG`](#max-width-truncation-broken-at-size_big)): pad the
already-truncated string with spaces out to `BIG_MAX_CHARS`/`MEDIUM_MAX_CHARS` characters before
drawing, on the theory that a constant character count makes the background box a constant width.
Failed on hardware for two independent, both-confirmed-by-eye reasons:

1. The SLMK2 font is proportional. N characters of space are pixel-narrower than N characters of the
   letters they replaced, so a shorter name still left a stale tail — `"m.23 A32 Ready patch"` →
   `"m.31 A18 Flutes"` left `"tch"` on screen.
2. Padding is symmetric in *characters*, not pixels, so it also broke `ALIGN_CENTER`'s actual centring —
   the visible glyphs no longer sat centred in the box.

The real fix — an explicit black erase rect over the full band, sized independently of the string's
glyph width, drawn as its own message before the text — is `draw_text_with_erase()`.

**One-row edge-triggered scrolling** (abandoned 2026-08-21; do not reintroduce). The original
`clamp_scroll()` moved `scrollOffset` the *minimum* amount needed to restore `SCROLL_MARGIN` once the
cursor crossed it. A hardware-report-driven audit found that minimum is usually one row, and landing the
cursor with the minimum shift *always* puts it exactly `SCROLL_MARGIN` rows from the far edge — nowhere
else it could land and still satisfy the margin — one row short of re-triggering. During ordinary
monotonic browsing (advancing one patch at a time, the realistic gig pattern), that meant every single
step past the first couple of moves re-triggered another one-row scroll, and a scroll costs a full
`ROW_COUNT`-row repaint where an in-window cursor move costs 2 messages — so nearly every patch change
paid for a full-window redraw it didn't need. Replaced by the page-jump policy — see
[The scroll and page-jump derivation](#the-scroll-and-page-jump-derivation).

**Refuse non-patch selections** (reverted 2026-08-20; do not reintroduce without checking with Jeroen
first — this is a deliberate product decision, not an oversight). MainStage reuses
`controller_select_patch` for selections in Edit mode that aren't a patch — selecting a *set* or the
*concert* shifts the argument hierarchy up one level (the selected thing arrives as `patchname`, its
parent as `setname`: selecting a set gives `patchname="2. Jacob & Sons / Joseph's Coat"`,
`setname="Joseph key2"` where `setname` is actually the concert; selecting the concert gives
`patchname="Joseph key2"`, `setname=""`). An earlier version detected this shift (via
`currentSetIndex`/`currentPatchIndex` plus the patchlist's `IsPatch`/`SetIndex`/`PatchIndex` fields) and
refused to display anything for a non-patch selection, keeping the last real patch on screen instead.
Jeroen's decision: the selected value should show in the patch slot regardless of which level of the
hierarchy it came from — selecting a set shows the set's name, selecting the concert shows the concert's
name. `controller_select_patch` now trusts `patchname`/`setname`/`concertname` unconditionally.

**Bundling Clear Screen with a draw, or with the keepalive** (confirmed unreliable; do not reintroduce).
See [The double Clear Screen](#the-double-clear-screen) and
[the `[display, query]` flush shape](#the-display-query-flush-shape) — every bundled-with-a-draw or
bundled-with-keepalive shape tested has been unreliable on hardware; only `[display, query]` (or a lone
display message with nothing else in the array) has proven reliable.

**Gating the keepalive on an empty queue** (reverted 2026-08-20; do not reintroduce). See
[The unconditional keepalive](#the-unconditional-keepalive) — correct diagnosis (bundling), wrong fix
(starved the keepalive for the whole length of any multi-message repaint).

---

## Open questions

### The first-mode-switch anomaly

A 2026-08-21 hardware report: the *first* switch to list mode left old text on screen; later switches
were fine; switching to zoom was "not always" fine either. Two specific hypotheses were checked and both
came back clean, so they are **not** the cause:

- `invalidate_all()` (called at the top of `set_display_mode()`, before the repaint) unconditionally
  replaces `drawn` wholesale (`drawn = {}`), which every `draw_text`/`draw_rect`/`draw_text_with_erase`
  call consults by id — there is no path by which a list-screen region's memo could survive it.
- A blank list row draws an empty string at a real, non-zero `maxWidth` (`draw_list_row`'s `row == nil`
  branch, `ROW_MAXW`) — confirmed on hardware that an empty string with a coloured background still
  paints a visible full-width bar (see [Settled facts](#settled-facts-max-width-and-the-write-text-background-box)),
  so a row going blank does paint over whatever was there before; it does not silently no-op.

Raising `MODE_SWITCH_SETTLE_TICKS` from 1 to 3 was the concrete fix applied for the underlying race, but
*why* specifically the first switch differed from later ones was never pinned down — every switch runs
the identical function, and nothing in it branches on "is this the first one". The one candidate not yet
ruled out: the first switch follows `handle_login()`'s own `paint_screen()` (the initial zoom paint,
which — unlike `set_display_mode()` — sends no Clear Screen and has no settle gap before it) with no
guarantee that repaint has finished draining. `drop_queued_display()` only discards what's still
*queued*, not a message already flushed but possibly still mid-paint on the panel. Next hardware run:
capture `/tmp/lua.log` across a first-switch and a later-switch and compare `has_pending()`/draining
state (the timer-tick line already prints both) at the moment the Clear Screen for each switch is
queued — if the first one is queued while the login repaint is still draining and later ones aren't,
that timing difference is the lead to follow.

### The `screenDirty` history

`screenDirty` was an early flag, present from the script's first working versions, intended to trigger a
repaint from inside `controller_timer_trigger` (`if screenDirty then paint_screen() end`). It was never
set to `true` anywhere in the codebase at any point in its history — its repaint branch was unreachable
dead code for the script's entire life up to that point. It was carried, unused, through every rewrite
of the repaint path (the move to `update_screen()`/`paint_screen()`'s per-region memoization, the
`ID_QUERY` self-heal branch, the popup mode) without anyone noticing it had gone stale, until a dead-code
sweep on 2026-08-28 (commit `8fcc59e`, "Delete six dead symbols from config.lua") finally removed both
the declaration and the branch, alongside five other unused symbols (`invalidate()`, `POPUP_REGION_IDS`,
`popupControl`, `CC_ENCODER_RELATIVE`, `ZSET_TRUST_MAXWIDTH`). No behaviour changed by removing it — by
construction, it never fired. Left here as a reminder that a flag with no writer is worth grepping for
before trusting what a comment claims a code path does: `screenDirty`'s own comment ("Used to keep the
display self-healing") described intent, not actual behaviour, for the entire time it existed.

---

## Identification approval and rejection are lost in MainStage's init window (2026-09-10)

Established on hardware with byte-level flush logging plus an independent CoreMIDI source sniffer,
while chasing why Master Volume works from a standalone probe but not from the script.

**The observation.** MainStage's documented init → finalize → init churn sends *two* Identification
Requests, both as `03 6D`, because a re-init resets `instanceID` to `SL_INSTANCE_START` and
`controller_finalize` deliberately sends no Logout Request (see
[`controller_finalize` sends no Logout Request](#controller_finalize-sends-no-logout-request)). The
SL88 answered both — the sniffer recorded `7F 01 ...` (APPROVED) for the first and
`7F 02 00 ...` (REJECTED, reason 0 = id taken/reserved) for the second:

```
28 frames from the device, of which:
 1×  6D 7F 01 01 01 02 01 F7     IDENTIFICATION APPROVED
 1×  6D 7F 02 00 01 01 02 01 F7  IDENTIFICATION REJECTED (reason 0)
25×  6D 7F 03 01 F7              Identification Query replies
 1×  6D 00 01 F7                 Login Confirmation
```

**Neither the approval nor the rejection appears in `/tmp/lua.log`.** `controller_midi_in` logs every
inbound frame beginning `0xF0`, and it logged only the query replies and the login confirmation. The
frames reached the Mac and did not reach the script: they arrive in the window after MainStage has
wired up `outport` (the requests demonstrably went out) but before it begins delivering
`controller_midi_in`.

**The consequence is that the re-identification machinery is unreachable.**
`handle_identification_rejected` is only ever called from the `7F 02` branch, so
`STATE_REIDENTIFY_WAIT`, the derivation behind `REIDENTIFY_WAIT_MS = 6000`, and
`MAX_SAME_ID_RETRIES` are all dead in practice — not wrong, just never entered. This also explains the
long-standing note that `handle_login()` frequently never runs: the approval is lost the same way, and
the session limps into `STATE_ACTIVE` through the `ID_QUERY` self-heal branch instead. Both behaviours
had been attributed to the SL88 "remembering the host across runs"; the real cause is a delivery gap on
the MainStage side.

**Why this breaks Master Volume.** The live script believes it is identified as `03 6D`, while the
SL88's registration for `03 6D` belongs to the first, now-finalized incarnation. The device keeps
answering Identification Queries and sends a Login Confirmation for that id, but refuses Master Volume
for it. Evidence that the id itself is fine: `Scripts/probe-mastervolume.swift` run with `--id2 6D`,
solo with MainStage quit, got 6/6 reads answered and 4/4 writes confirmed by read-back. The same bytes
from MainStage, with the contested registration, are ignored — the device never sends a `0x07` frame at
all, confirmed by the sniffer, so this is a refusal at the device and not a decode gap on our side.

**Rejected fix (at the time): send a Logout Request from `controller_finalize`.** Already tried and
reverted for an independent reason recorded above — every spurious teardown then deletes the app from
the SL88's APP list. Retried 2026-09-10 now that the delivery-gap fix above and the timer watchdog have
landed — see
[`controller_finalize` sends no Logout Request](#controller_finalize-sends-no-logout-request) for
current status.

**Chosen fix: stop treating an Identification Query reply as proof of identification.** The script
re-sends the Identification Request until it sees an explicit `7F 01` approval. The point is not the
resend by itself but that a resend lands *after* MainStage's inbound path is live, so whichever answer
comes back is actually delivered — an approval promotes the session honestly, and a rejection finally
reaches `handle_identification_rejected` and runs the recovery that was designed for it.

**Fallback floor: revert to query-reply promotion once the resend budget is spent.** If
`MAX_IDENTIFY_RESENDS` resends all go unanswered by an explicit `7F 01`, the fix above leaves the
session stuck in `STATE_IDENTIFYING` with no keepalive going out — a silent, permanent failure of the
whole integration. A dead session is worse than one missing Master Volume, so `identifyFallback` sets
once the budget is exhausted and, from then on, restores the exact pre-fix behaviour: the timer branch
resumes `send_keepalive()` and an `ID_QUERY` reply promotes a `STATE_IDENTIFYING` session via
`enter_active_session()`. The `[sllink] identification never approved - falling back to query-reply
promotion` log line is how to tell, from a hardware capture, which path a given run actually took.

---

## Master Volume writes go out unpaired (2026-09-10)

`Scripts/probe-mastervolume.swift` gets every Master Volume read/write answered, sending each message
alone. `flush_pending` never does that - it bundles the queued message with a trailing Identification
Query into one array (see [the display/query flush shape](#the-display-query-flush-shape)), so a Master
Volume write leaving `config.lua` is always paired with the query, unlike the probe's. The same
"bundling drops a display message" failure mode is already established for Clear Screen (see
[the double Clear Screen](#the-double-clear-screen)); worth eliminating for Master Volume too even
though the identification-window fix above may already have been the real cause of the original symptom.

**Change:** `flush_pending` omits the query when the message it is about to emit is `IT_MASTER_VOLUME`,
so a write goes out alone, matching the probe.

**Why the clock is safe.** Master Volume writes are queued under a single `'mvol'` regionId
(`queue_message`'s per-region coalescing - see EID_A's handler), so at most one is ever waiting; a fast
encoder sweep produces a replacement write per tick, not a growing backlog. Every encoder tick is
itself an inbound SL frame, and `controller_midi_in` calls `rearm_timer()` unconditionally on every
inbound frame (rule 6) - not just on query replies - so the sweep's own traffic keeps the clock running
independent of the query. `flush_pending` also calls `request_quick_rearm()` whenever it drops the
query for a Master Volume write: effective when `flush_pending` runs from `controller_midi_in`'s call
chain (confirmed working, see [Quick-rearm](#quick-rearm-2026-08-21)), a harmless no-op when it runs
from inside `controller_timer_trigger`, whose own `settriggertimer` call is already established as a
no-op from that context.

**Residual edge case, not newly introduced.** If a CC batch backlog (`CC_BATCH_CAP` overflow) leaves a
Master Volume write stranded in `pendingMessages` until `controller_timer_trigger`'s own flush dequeues
it, that flush has no fallback re-arm (same limitation as the double Clear Screen finding) and now sends
no query either. This interaction predates this change - today it would ship the same stranded write
bundled with the query, itself suspected undeliverable per the bundling pattern above - and only matters
if the user goes completely idle immediately afterward. Not fixed here; flagged for anyone chasing an
unexplained APP-list drop following a heavy multi-encoder sweep.

**Reverted (2026-09-10).** Confirmed on hardware: pairing every Master Volume write with a READ (see
[the section below](#master-volume-drop-detection-read-rate-limiting-and-the-mid-gesture-guard-2026-09-10))
is what actually made the device answer - not this unpairing. Once the READ was added, the unpairing
became actively harmful: during an A-encoder sweep most flushes ARE Master Volume messages, so dropping
the query on each one crowded out the keepalive and the SL88 dropped the app after ~5s. `flush_pending`
now always appends the
query when `includeQuery` is true, Master Volume included, and the `request_quick_rearm()` call this
change added is gone with it - the paired query is itself the re-arm mechanism.

---

## Reading instance tags from a log: dead incarnations, not concurrent instances (2026-09-10)

Jeroen's observation while diagnosing the finalize/Logout Request issue above: a MainStage controller
restart mid-test-session produces more than one instance tag in `/tmp/lua.log`, same as a genuine
multi-instance scenario would. A tag count alone can't tell the two apart - a restarted controller's
old tag is simply dead, not a second instance running concurrently with the first. Corroborate with
`controller_initialize`/`controller_finalize` call counts and tick-number continuity (see
[Single instance confirmed on hardware](#single-instance-confirmed-on-hardware-2026-08-28) for the
method) before reading a log's tag count as a live instance count.

**The tag itself is not collision-proof either.** `instanceTag` (`compute_instance_tag` in
`config.lua`) mixes several object addresses and `collectgarbage('count')` because a single table
address collided across separately-loaded Lua states often enough to make the harness test flaky.
Mixing sources lowers the odds but cannot guarantee uniqueness - MainStage's sandbox has no clock and
no seedable RNG, so two instances that reach the tag line via an identical allocation history could in
principle still mix to the same value. Treat two identical tags in a log as weak evidence, not proof,
that they're the same instance; corroborate as above.

---

## Per-instance starting id (2026-09-10)

A hardware run caught two script instances both APPROVED as the same id, `03 6D` - distinguishable
only by `instanceTag` in the log, indistinguishable to the SL88 itself: one DeviceID, two independent
senders, both keepaliving it. Root cause: `SL_INSTANCE_START` was one fixed constant (`0x6D`), used
both for a fresh instance's very first attempt and for the value `controller_initialize` resets
`instanceID` to on every MainStage-driven re-init - every incarnation, concurrent or sequential,
started identification from the exact same byte. A re-initialised incarnation racing its own
still-registered ghost is the same failure by the same cause.

**Change:** `instanceID`'s starting value is now `derive_instance_start(instanceTag)` - `instanceTag`
mapped into `[SL_INSTANCE_MIN, SL_INSTANCE_MAX]` (`0x10`-`0x7E`, the same range
`handle_identification_rejected`'s bump already wrapped within) by `n % (MAX - MIN + 1)`, offset by
`MIN`. Both use sites (the module-level initial assignment and `controller_initialize`'s reset) call
it, so a fresh incarnation - a genuinely new Lua state, per the "dead incarnations" finding above -
gets a new `instanceTag` and therefore ordinarily a different starting id than its predecessor's
ghost, and two concurrently-loaded instances ordinarily don't start identification from the same byte
either.

**Residual risk, not eliminated.** `instanceTag` was already established above as lowering collision
odds without ruling them out; mapping it through a mod-111 reduction narrows the id space further and
so cannot do better than the tag itself. `handle_identification_rejected`'s existing wait/retry/bump
path - retry the SAME id after `REIDENTIFY_WAIT_MS`, only bump after `MAX_SAME_ID_RETRIES` failed
retries - is unchanged and remains the backstop for the case two instances still land on the same
derived id.

**Logout Request becomes effective, not just transmitted - unconfirmed on hardware.**
`controller_finalize`'s Logout Request (see the finalize entry above) was observed transmitted and
confirmed (`00 03`) on the wire yet ineffective, because another live instance sharing the *same*
DeviceID kept the registration alive with its own keepalives. With each instance now ordinarily
holding a distinct DeviceID, nothing should be left to keep a finalized instance's registration alive
after its Logout Request lands - so the request should now actually kill the registration, not merely
be acknowledged. This is a claim about the SL88's registration table, which the offline harness cannot
observe (it stubs `settriggertimer`/MIDI plumbing, not the keyboard); it needs a hardware run. Confirm
by: (a) two concurrently-loaded instances' log lines showing different `instanceTag`s AND different
starting `instanceID`s, and (b) a finalize -> re-init cycle whose next Identification Request is
APPROVED on the first try with no REJECTED at all - repeated across several cycles - where today's
bug would instead show a `03 6D`/`03 6D` collision and at least one REJECTED before the retry clears
it.

---

## Master Volume drop detection, read rate limiting, and the mid-gesture guard (2026-09-10)

Sending a Master Volume READ alongside every WRITE (`queue_master_volume_read('mvolRead')` in the
`EID_A` handler) is what makes the SL88 answer - confirmed on hardware: READ replies started arriving
(`<- MASTER VOLUME 67`) and the volume actually moved. This run also surfaced three problems, fixed
together:

**Superseded (2026-09-13).** The claim that pairing a READ is what makes writes take effect is wrong -
see [the four-phase probe result](#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13).
Writes work identically with no read in flight; what the READ actually did on this hardware was give
the write a companion message that happened to change flush/timing behaviour, not confirm or enable it.

**1. Query/Master-Volume pairing reverted** - see
[Master Volume writes go out unpaired](#master-volume-writes-go-out-unpaired-2026-09-10)'s own
"Reverted" note. The READ was the fix, not the unpairing; the unpairing became actively harmful once
combined with it.

**2. Active session drop detection.** Once the SL88 drops an app from its list, nothing previously
noticed - the script kept believing it was `STATE_ACTIVE` and transmitted into the void forever.
`controller_timer_trigger` now accumulates `timerArmedInterval` into `activeMsSinceQueryReply` on every
tick while `STATE_ACTIVE`; any Identification Query reply resets it to zero
(`handle_sl_frame`'s `ID_QUERY` branch). If it reaches `ACTIVE_QUERY_DROP_MS` (`2 * KEEPALIVE_MS`,
6s) with no reply seen, the tick falls to `STATE_IDLE`, which the existing branch immediately below
turns into a fresh `start_identification()` - reusing that path rather than calling it twice in the
same tick.

Accumulating *time* (via `timerArmedInterval`) rather than counting raw ticks matters because tick
pacing is not constant: while a repaint or an encoder sweep drains, `rearm_timer()` picks
`FLUSH_SOON_MS` (35ms) instead of `KEEPALIVE_MS` (3s) - see [the session
clock](#the-session-clock-and-the-one-shot-timer). A tick-count threshold would either fire almost
instantly during a fast sweep (false positive) or take far too long during idle keepalive pacing. In
practice this is not even a risk during a *healthy* sweep: every tick's flush carries its own query
(fix 1 above), so a connected keyboard answers almost immediately (~2ms round trip) and the
accumulator resets before the next tick regardless of how fast ticks are arriving. Two consecutive
full misses (6s) is not reachable by jitter alone; it means the keyboard has gone genuinely silent.

Threshold reasoning: the SL88 drops a silent host after ~5s. One missed reply could be a single lost
packet, so the detector waits for a second consecutive miss - `2 * KEEPALIVE_MS` = 6s - before
concluding it's a real drop. This is the same margin-over-5s idea `LOGOUT_SILENT_TICKS` already uses
(3 ticks, ~9s) but shorter, since here the goal is fast recovery from an already-confirmed problem
rather than deliberately waiting out the drop.

**3. Master Volume READ rate limiting.** Every `EID_A` tick used to queue both a write AND a read; with
one message per flush the read queue was permanently backlogged, making the control feel sluggish.
`mvolReadPending` now gates it: an `EID_A` tick only queues a new read if none is outstanding, or if
`MVOL_READ_TIMEOUT_FRAMES` (10) SL frames have passed since the outstanding one was sent with no reply
(a lost reply must not wedge the guard shut forever). The reply clears the flag
(`handle_sl_frame`'s `IT_MASTER_VOLUME`/`MVOL_READ` branch). Counted in SL frames
(`slFrameCounter`, incremented once per `handle_sl_frame` call) rather than ticks, for the same
pacing-independence reason as fix 2.

**4. Mid-gesture guard against a stale READ reply.** Hardware log showed masterVolume oscillating
during a sweep (`07 01 42, 07 01 41, 07 01 42, 07 01 41`): a READ reply answering an OLDER request
was landing after the `EID_A` handler had already applied a NEWER local delta, and clobbering it back
down. `masterVolumeRead` (the device-reported value the popup displays) must keep updating from every
reply regardless - that's the point of the READ - but `masterVolume` (the value being written) must
not.

Fix: `mvolLastGestureFrame` records `slFrameCounter` at the last `EID_A` tick. A `MVOL_READ` reply only
overwrites `masterVolume` if `slFrameCounter - mvolLastGestureFrame > MVOL_GESTURE_WINDOW_FRAMES` (5) -
i.e. at least 5 SL frames of quiet since the last local delta. "Mid-gesture" is defined purely as this
short window since the last `EID_A` tick, deliberately simple: it doesn't try to match a reply to the
specific request it answers, it just distrusts ANY reply landing soon after a local delta, which is
exactly the situation that produced the oscillation. The window needs to survive a few more encoder
ticks and their own (still in-flight) read replies arriving interleaved and out of order during
continuous rotation, while opening quickly once the user actually stops so the display can resync -
5 frames was chosen as a small multiple of that, not measured on hardware; retune here if a future
capture shows it too short (residual oscillation) or too long (sluggish resync after stopping).

**Fix 2 removed the same day.** A build containing the drop detector left MainStage feeling frozen,
with audio pops, while completely idle - no user interaction at all. The re-identify loop (drop to
`STATE_IDLE` -> `start_identification()` -> possible IDENTIFICATION REJECTED -> wait/retry/bump) is
the suspected mechanism - the hardware log showed `re-identify retry 1/2` and `2/2` firing - but this
is suspected, not proven: the debug capture for that run was lost when MainStage was restarted
manually. `ACTIVE_QUERY_DROP_MS` and `activeMsSinceQueryReply` were removed entirely; fixes 1, 3, and
4 above are unaffected. Consequence: the app no longer recovers on its own if the SL88 drops it from
its APP list.

---

## Master Volume popup: seed from READ, track the write value (2026-09-10)

Fix 4 above (the mid-gesture guard) kept `masterVolume` itself from oscillating, but the A popup
displayed `masterVolumeRead` directly - the device's own last READ reply, not the value actually
being written. On hardware this looked jumpy and unsmooth: the number on screen only moved when a
reply happened to land, so its update rate depended on round-trip timing rather than the encoder.

**Change:** the popup now shows `masterVolume` - the value being sent - on every tick, not
`masterVolumeRead`. `masterVolumeRead` still updates from every READ reply as before, but now only
feeds one thing: reseeding `masterVolume` at the *start* of a new gesture, so a turn still begins
from the device's real value rather than a possibly-stale local guess. This also makes fix 4's own
guard unnecessary - it existed only to keep a READ reply from clobbering `masterVolume` mid-gesture,
and now READ replies never touch `masterVolume` at all, at any time. `mvolLastGestureFrame`/
`MVOL_GESTURE_WINDOW_FRAMES` are removed.

**Gesture boundary.** The script has no clock, so "start of a new gesture" is approximated the same
way the popup's own idle-dismissal already is: `idleTicks`, incremented once per timer tick while
nothing is draining, paced at `POPUP_TICK_MS` (~1s) whenever the A popup is active and idle (see
`rearm_timer`'s `popupActive` branch and `check_popup_dismiss`). `mvolLastActivityIdleTick` records
`idleTicks` at the last `EID_A` tick; a new tick counts as a new gesture once
`idleTicks - mvolLastActivityIdleTick >= MVOL_GESTURE_IDLE_TICKS` (1). This reuses an existing,
already-hardware-paced clock rather than adding a second one - the same reasoning `POPUP_DISMISS_IDLE_TICKS`
already relies on. Real-time accuracy: while idle it lands close to 1s (one `POPUP_TICK_MS` period
plus whatever small drain delay preceded it, typically tens of ms); it is not a raw tick or frame
count that would otherwise run fast during an active sweep, since `idleTicks` deliberately does not
advance while `has_pending()` is true.

**No-reply-yet fallback.** If a gesture starts before any READ reply has ever arrived
(`masterVolumeRead == nil` - plausible, since the READ queued at login is asynchronous),
`masterVolume` keeps its current value instead of seeding to nil: `masterVolume = masterVolumeRead or
masterVolume`. In practice this is the default 100 or whatever a previous gesture already
accumulated.

**Corrected (2026-09-10) - this fallback was the bug, see below.** It let the first tick WRITE the
invented default.

---

## Never write an unconfirmed Master Volume (2026-09-10)

Hardware log: the login-time Master Volume READ was never answered, but the very first A-encoder tick
still wrote `masterVolume` (the hardcoded default, 100) to the device, jumping the audio board to full
volume:

```
-> MASTER VOLUME READ  (sent at login - never answered)
-> MASTER VOLUME WRITE ... 07 01 64      <- 0x64 = 100
<- MASTER VOLUME 100
```

The trailing READ reply reported 100 only because the write had just put it there - not because 100
was ever the device's real value. Confirmed on this hardware: the login-time READ goes unanswered,
while READs issued during an EID_A gesture (`queue_master_volume_read('mvolRead')`) do get replies -
so `masterVolumeRead` reliably becomes known within a tick or two of the user actually touching the
encoder, just not before.

**Fix.** The EID_A handler now branches on `masterVolumeRead == nil`: while unknown, it sends NO
write at all (only keeps polling, same rate limit as before) and the popup shows the `--` placeholder
(`popupValue = masterVolumeRead and masterVolume or nil`) rather than a guessed number. The
[no-reply-yet fallback](#no-reply-yet-fallback) above - keep accumulating from the local guess - is
removed; the old default value in `masterVolume` is never allowed to reach the wire while unconfirmed.

**Suppressed deltas are discarded, not replayed.** Ticks while unknown update nothing - not even a
local accumulator - so once `masterVolumeRead` arrives there is nothing queued up to apply. A new
`mvolNeedsSeed` flag (true until the first known-value tick) forces that tick to seed `masterVolume`
from `masterVolumeRead` regardless of `MVOL_GESTURE_IDLE_TICKS`, then clears; normal write behaviour
resumes from there. Rejected alternative: apply the accumulated suppressed delta on top of the fresh
device value once known. Discarding is safer - a delta computed against an invented starting point is
itself meaningless, and the user simply turns the encoder again once the number appears.

`MVOL_GESTURE_IDLE_TICKS` (the gesture re-seed boundary, still 1) and `POPUP_DISMISS_IDLE_TICKS` (the
popup's own idle-dismiss threshold) are separate constants compared independently against `idleTicks`
in unrelated call sites - this fix touches neither.

---

## Popup dismiss doubled to 2s (2026-09-10)

`POPUP_DISMISS_IDLE_TICKS` raised from 1 to 2 (at `POPUP_TICK_MS` ~1s each, so ~1s -> ~2s) - the popup
was disappearing too quickly to read. `MVOL_GESTURE_IDLE_TICKS` (the Master Volume gesture re-seed
boundary) is a separate constant, confirmed correct at 1 and left unchanged - see [Never write an
unconfirmed Master Volume](#never-write-an-unconfirmed-master-volume-2026-09-10) above.

---

## Seed Master Volume at 60 instead of refusing to write (2026-09-12)

[Never write an unconfirmed Master Volume](#never-write-an-unconfirmed-master-volume-2026-09-10)
traded one hazard for another. Hardware log from the very next run: 16 A-encoder frames reached the
script, the guard correctly suppressed all 16 writes, but the accompanying READ - sent 4 times - was
never answered either, `masterVolumeRead` stayed `nil` for the whole session, and the encoder was
permanently dead (no write ever went out, so no popup value, and the keyboard eventually dropped the
app). Cross-referencing every run on record: a Master Volume READ only ever gets answered while
writes are also flowing - the login-time READ and this guard's READ-only polling both went
unanswered, but READs during an ordinary write-carrying gesture always came back. The guard's own
premise - wait for a confirmation - could only ever be satisfied by the thing it was refusing to do.

**Fix.** `mvolNeedsSeed`'s branch is gone. The EID_A handler is back to one path: on a new gesture
(same `MVOL_GESTURE_IDLE_TICKS` boundary as before - always true on the very first tick, since
`mvolLastActivityIdleTick` starts far in the past) it seeds `masterVolume = masterVolumeRead or
MVOL_SEED_DEFAULT` and writes unconditionally. `MVOL_SEED_DEFAULT = 60` is the user's choice of a
safe mid-scale starting point - not 100, where a single click could have slammed the audio board to
full output, the exact hazard the original guard existed to prevent. The popup shows `masterVolume`
directly now (never the `--` placeholder in normal operation); `draw_popup_value(nil)` stays as
defensive dead code for a caller that no longer exists.

`mvolNeedsSeed` was removed rather than repointed at the new default: with the reseed condition
already true on the very first tick (the idle-tick sentinel forces it independently, per its own
"belt-and-suspenders" comment), the flag never changed observable behaviour even before this fix -
confirmed by re-reading its own declaration comment, not just by inspection here.

---

## Popup entry skips Clear Screen (2026-09-12)

Companion fix to the seed change above, same hardware run: a single A-encoder tick queued 11
messages at once (2x Clear Screen + `popupBg` + 4 border strips + `popupLabel` + `popupKnob` +
`popupValue` + the trailing sacrificial redraw, from `set_display_mode('popup')`, plus the Master
Volume READ), and the SL88 dropped the app mid-drain of that burst.

The popup's own content was never the avoidable part - a first paint has nothing in `drawn[]` to
compare against, so `paint_popup_screen()` queuing all of it once is correct, not a memoization bug.
The double Clear Screen and `invalidate_all()` are the actual excess: they exist for
`set_display_mode()`'s list<->zoom switches, where the outgoing screen's content differs in ways
Write Text's own self-clearing background box can't guarantee to fully cover. The popup is not that
case - `popupBg` plus the 4 border strips are opaque and together cover exactly the popup's own
rect, so nothing underneath needs erasing, and `invalidate_all()` on entry is provably a no-op for
the popup's own region ids either way: they are unset on the very first popup ever, and the memo
returns to unset every time `dismiss_popup()`'s own `set_display_mode()` call invalidates everything
on the way out.

**Fix.** New `enter_popup_mode()` (used by both `show_popup()` and `show_master_volume_popup()`'s
first-call branch) sets `displayMode`, drops stale queued display work for the outgoing mode, calls
`paint_popup_screen()`, and still ends with the trailing sacrificial redraw and `request_quick_rearm()`
- everything `set_display_mode()` did except the double Clear Screen and `invalidate_all()`. First-tick
burst: 11 -> 9. `dismiss_popup()` is unchanged - it still needs `set_display_mode()`'s full treatment
to properly restore whatever mode the popup was covering.

---

## Master Volume READ reply does not track writes (2026-09-12) — OVERSTATED, SEE CORRECTION BELOW

Hardware log, consecutive lines from a live session:

```
<- MASTER VOLUME READ reply vol=71 (masterVolume=66)
-> MASTER VOLUME WRITE ... 07 01 41   (65)
<- MASTER VOLUME READ reply vol=71 (masterVolume=65)
-> MASTER VOLUME WRITE ... 07 01 46   (70)
<- MASTER VOLUME READ reply vol=71 (masterVolume=72)
```

The device answered a fixed `vol=71` on every single READ while the writes swept 65 -> 70 -> 72, and
the user confirmed the audio output audibly changed with each write. So the READ reply is not the
device's current output level - what it actually reports is unknown and is now an open question.
[Master Volume popup: seed from READ, track the write value](#master-volume-popup-seed-from-read-track-the-write-value-2026-09-10)
and [Seed Master Volume at 60 instead of refusing to write](#seed-master-volume-at-60-instead-of-refusing-to-write-2026-09-12)
both fed `masterVolume` from this reply at a gesture's start - seeding from a value that doesn't
track our own writes drags the displayed/written volume back toward 71 whenever the user pauses and
resumes, which is exactly the reported symptom.

**Fix.** `masterVolume` is now tracked locally only: it starts at `MVOL_SEED_DEFAULT` (60) and
thereafter changes ONLY by accumulated `EID_A` deltas, clamped to 0-100 - never reseeded from
`masterVolumeRead`, at a gesture start or any other time. The popup shows this locally tracked value,
same as before. The READ itself is still sent every `EID_A` tick (rate-limited as before) - it is
what makes the device answer writes at all on this hardware, and `masterVolumeRead` still updates
from every reply and stays in the log line, purely as a diagnostic now.

**Superseded (2026-09-13).** "It is what makes the device answer writes at all" is wrong - see
[the four-phase probe result](#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13):
a 121-write sweep with zero reads took effect exactly. `config.lua` has since dropped the per-tick READ
poll entirely (Change 1, same date); the single login-time READ is kept as a diagnostic only.

**Removed as dead.** `mvolLastActivityIdleTick` and `MVOL_GESTURE_IDLE_TICKS` existed only to detect
a gesture's start for the reseed above; with no reseed left, nothing reads either, so both are
deleted rather than left as unused state.

---

## Popup entry always erases its full region first (2026-09-12)

Same hardware run as the fix above: with Clear Screen skipped on popup entry
([Popup entry skips Clear Screen](#popup-entry-skips-clear-screen-2026-09-12)), the popup's own
`popupBg`/border/label/knob/value messages are queued together but drain one per timer tick (the
project's own display pacing rule). Part of the patch screen stayed visible under the popup while
that queue was still draining - `popupBg` plus the 4 border strips are only opaque once every one of
those five messages has actually reached the device, and until then whatever was on screen before is
still there in the ids that haven't landed yet.

**Fix.** New `draw_popup_erase()`, called first thing in `enter_popup_mode()` (the shared entry path
for both `show_popup()` and `show_master_volume_popup()`, so every current and future popup gets it
for free): one filled Draw Rectangle over the WHOLE panel, `POPUP_X`/`POPUP_Y`/`POPUP_W`/`POPUP_H`
(border included), in `POPUP_BG_COLOR`. Queued as its own message, first, so the panel is fully black
from the very first message of the burst - nothing underneath can show through the border/label/
knob/value messages that follow while they drain.

**Memoization interaction.** `draw_rect()` memoizes by id, and the erase rect's own parameters never
change between openings, so a naive `draw_rect('popupErase', ...)` call would be skipped as
"unchanged" on the second and every later popup opening - the exact bug this fix exists to prevent,
just moved one level up. `draw_popup_erase()` clears `drawn['popupErase']` and every id it overlaps
(`popupBg`, the 4 border ids, `popupLabel`, `popupKnob`, `popupValue`) immediately before drawing, so
all of them unconditionally resend on every popup entry regardless of prior state - the NON-OVERLAP
RULE's own documented escape hatch for a caller that can't avoid overlap (see MARK: - Per-region
memoization in `config.lua`). In the current control flow `dismiss_popup()`'s own
`set_display_mode()` call already runs `invalidate_all()` on the way out, which would have cleared
the same ids anyway - but `enter_popup_mode()` no longer depends on that as a side effect of a
different function; the guarantee is now local and self-enforcing. Test 54 in the Lua harness proves
this directly: it calls `enter_popup_mode()` twice in a row with `drawn[]` deliberately left
unchanged in between, and asserts the erase and its overlapping ids resend both times.

**Message budget.** The popup-entry burst goes from 9 to 10 (erase + `popupBg` + 4 border strips +
label + knob + value + sacrificial redraw); the full first `EID_A` tick (popup entry plus the Master
Volume write and read) goes from 11 to 12. Harness section 53's ceiling is raised accordingly - a
deliberate, one-message increase, not a silently-widened bound.

---

## Master Volume write-backs do not all reach the device (2026-09-12) — OPEN, HYPOTHESIS 3 DISPROVED 2026-09-13

**Update (2026-09-13).** Hypothesis 3 below is disproved -
[the four-phase probe result](#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13)
found a dense 10ms write stream, with no reads at all, sounds smooth on the device. The device is not
the bottleneck at any density tested. Hypothesis 2 (one message per flush shared with the popup's own
redraws) is now the leading explanation - see that section's Change 1, which drops the per-tick READ
poll to free a flush slot for writes.

Reported from hardware after the local-tracking and popup-erase fixes: the popup itself is smooth and
shows the right value, but **the sound card's actual volume does not change smoothly** — it steps
unevenly, as though only some of the writes land.

**What is established:** the popup tracks `masterVolume` continuously and correctly, and `masterVolume`
changes by one delta per encoder tick. So the gap is between what the script *intends* to send and what
the device *acts on* — not a display or accumulation bug.

**Leading suspects, none tested:**

1. **Per-region coalescing drops intermediate values.** Master Volume writes are queued under the
   `'mvol'` region id, which replaces-in-place. During a fast twist, many ticks coalesce into a single
   queued write carrying only the newest value, and every intermediate value is discarded by design.
   That is correct for keeping the queue bounded, but it means the device sees a coarse sequence of
   jumps rather than every step — which would sound exactly like "not smooth".
2. **One message per flush is too slow for the tick rate.** At `FLUSH_SOON_MS` (35ms) the drain rate is
   ~28 messages/sec, shared with the popup's own redraws. A brisk encoder sweep generates ticks faster
   than that, so writes are necessarily thinned.
3. **The device may rate-limit or ignore closely-spaced writes.** **Disproved 2026-09-13** - a 10ms
   write stream with no reads sounds smooth on the device; see
   [the four-phase probe result](#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13).

**Note the tension with the session-safety work:** coalescing and the one-per-flush budget are what
stopped the queue saturating and getting the app dropped from the APP list. Any fix that sends *more*
writes must not reintroduce that. The interesting direction is probably sending *fewer but better-timed*
writes — e.g. a fixed-rate write of the latest value (~10/sec) rather than one per tick — so the device
gets an even cadence instead of a burst-then-gap.

**Related open question from the same day:** the READ reply is pinned at a constant (71 observed) and
does not track writes, so it cannot be used to confirm what the device actually received. Until that is
understood, there is no in-band way to verify which writes landed — the sniffer plus Jeroen's ear are
the only observation path.

**Resolved (2026-09-13).** The READ reply does track writes exactly (staleness 0, ~1ms) when probed
directly against the device - see
[the four-phase probe result](#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13).
The staleness above was a MainStage host-path artifact, not a device limitation.

### Next step: confirm the read-back against the probe (planned 2026-09-12)

Jeroen's instruction for the next round: **use the Swift probe to establish whether the read-back is
genuinely faulty**, rather than continuing to reason about it from the script's own log.

This is sharper than it first appears, because the probe has already produced the *opposite* result on
the same hardware. `Scripts/probe-mastervolume.swift`'s scripted sequence wrote 20, 60, 90 and 45, and
each read-back returned exactly that value — 4/4, with the `07 00 <vol>` shape correctly failing as a
negative control. Yet the script, on the same keyboard, logs a constant `vol=71` across a sweep of
writes 65→70→72 that audibly changed the volume. Both cannot be describing the same device behaviour.

**Already ruled out — byte position.** `midiEvent` is 0-indexed in MainStage's Lua host, the frame is
`F0 00 20 1A 16 <id1> <id2> 07 00 <VOL> <MUTE> F7`, so `e[9]` is VOL; the probe's `payload.first`
resolves to the same byte. Both parse correctly, so a decode off-by-one is not the explanation.

**What the probe run should establish:**

1. Does the read-back still track writes from the probe today, reproducing the earlier 4/4 result? If it
   does, the divergence is real and specific to the script's session.
2. If it does, what differs? Candidates not yet eliminated: the write cadence (the probe pauses ~500ms
   between steps, the script writes on every encoder tick and coalesces), and whether a read issued
   while several writes are still queued returns a pre-write value.
3. Cadence is the most testable: add a mode to the probe that writes at the script's rate rather than
   with pauses, and see whether the read-back goes constant. That would tie the constant reply and the
   uneven volume stepping to a single cause — the device not keeping up with burst writes — which is
   also the leading suspect for "not all write-backs arrive".

Run the probe solo with MainStage quit, and remember that a run only means anything if the probe was
explicitly selected on the keyboard during it: state carries between rapid successive runs.


---

## Correction: the read reply is sparse and stale, not constant (2026-09-12) — PARTIALLY SUPERSEDED, SEE BELOW

The earlier section claiming the READ reply is "pinned at 71 and does not track writes" was **wrong, and
wrong because of how it was measured** — it generalised from a `tail -12` window of one run that happened
to sit in a run of identical values. A full-log check of the following run shows otherwise.

**What the complete log actually shows:**

- **Frames arrive whole.** Every inbound frame is a complete 11- or 12-byte `F0 … F7`. There are no
  truncated fragments, so the CoreMIDI packet-splitting that broke the standalone probe earlier is NOT
  happening in MainStage's Lua host. (Jeroen raised this as a hypothesis; it is ruled out.)
- **Reply values vary widely** across a run: 15, 23, 29, 52, 64, 71, 96, 98.
- **Replies are rare and badly stale.** Only a handful arrive across thousands of lines, and one reports
  `vol=29` while `masterVolume` is 67.
- **Writes are NOT being coalesced away.** Consecutive writes go out with no gaps —
  `36 37 38 39 3A 3B 3C 3D 3E 3F 40 41 42 43 44 45` on the way up (54→69) and every step back down again.

**This inverts the diagnosis of the uneven-stepping defect.** The leading suspect was per-region
coalescing discarding intermediate values; the log disproves it. The script emits a clean, complete,
dense stream and the device's audible response is still uneven, while its read replies lag far behind.
That points at the **device** not keeping up with densely-spaced writes, not at our queue dropping them.

**Superseded (2026-09-13).** Wrong again, same lesson as the method note below: measured through
MainStage, not against the device. Probed directly, the device answers every read exactly and in
~1ms even under a 10ms write stream - see
[the four-phase probe result](#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13).
The sparse/stale replies seen here were a MainStage host-path artifact.

**Consequence for the fix direction:** sending writes *more* reliably cannot help — they are already all
being sent. The promising direction is the opposite: write *less often* at an even cadence (e.g. the
latest value ~10 times a second instead of once per encoder tick) and give the device time to act on
each one. That also costs less queue pressure, so it does not fight the session-safety work.

**Still open:** what the READ reply actually reports, given it lags this far behind. It may be a value
sampled well before our recent writes, which would make it useless as a live reading but harmless as the
in-flight companion that makes writes work at all.

**Resolved (2026-09-13).** It reports the exact current value, with ~1ms latency, when probed directly -
see [the four-phase probe result](#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13).
It is not, and never was, needed as an "in-flight companion" for writes to work.

**Method note.** Two findings in one day were overstated from narrow log windows — this one, and an
earlier "vacuous assertion" call that turned out to be a mutation landing in a comment. Check a whole
capture, or the complete set of distinct values, before writing a characterisation into this file.

### The cadence experiment, for the probe (planned 2026-09-12) — RUN 2026-09-13, SEE RESULT BELOW

Jeroen's question: can the "device cannot keep up with a dense write stream" hypothesis be tested with
the Swift probe? Yes, and better than through MainStage, because the probe controls the one variable
that matters — the interval between writes — while MainStage's rate is dictated by encoder ticks and
the flush budget.

**Design.** Add a sweep mode to `Scripts/probe-mastervolume.swift`: walk the volume across the same
range twice in one session, changing only the inter-write interval.

- **Dense phase:** a write every ~10ms, approximating the encoder tick rate the script produces.
- **Paced phase:** the same values, a write every ~100ms.

**Observation is Jeroen's ear** — smooth versus stepped — since the read reply lags too far behind to
serve as the measurement. Two supporting signals the probe should record itself:

1. **Measured elapsed time between sends**, logged per phase. The cadence must be verified, not assumed;
   a "10ms" loop that actually runs at 40ms would invalidate the comparison.
2. **Read replies received per phase.** The script's capture suggests replies become rare under dense
   writes. If the probe reproduces that, it is a second independent signal pointing at the same cause,
   and it does not depend on anyone's hearing.

**Outcomes and what each means:**

- Dense stepped, paced smooth → hypothesis confirmed; the fix is a write-cadence limit in `config.lua`
  (send the latest value at a fixed rate rather than once per encoder tick), which also lowers queue
  pressure and so does not fight the session-safety work.
- Both smooth → the device is NOT the bottleneck, and the uneven stepping lives somewhere in MainStage's
  own send path. That is a different investigation, and worth knowing before spending effort on pacing.
- Both stepped → the steps are inherent to the audio board's volume resolution, not to timing at all;
  nothing to fix in the script.

**Positive control already in hand:** the probe's existing scripted sequence proves writes take effect
and read-backs can track them, so a null result cannot be dismissed as "the probe was not working".

Run it solo with MainStage quit, and select the probe on the keyboard during the run — state carries
between rapid successive runs.

---

## Master Volume writes take effect without a paired read (probe four-phase result) (2026-09-13)

This is the cadence experiment above, actually run with `Scripts/probe-mastervolume.swift --cadence`,
standalone against the SL88 with a confirmed Login Confirmation, no MainStage involved. Four phases:

- **Phase A/B (write+read sweeps, ~100ms and ~10ms cadence):** 121/121 reads answered in both; reply
  latency ~1ms; staleness 0 — the reply always reports exactly the value last written.
- **Phase C (reads only, no writes at all):** 8/8 answered.
- **Phase D (writes only, no reads at all):** 121 writes swept 20→80→20; a read issued afterward
  matched the sweep's end value exactly.
- Jeroen confirmed both sweeps, and a denser ~10ms cadence (three times MainStage's own encoder tick
  rate), sound smooth through the SL88's audio board.

**Outcome: "Both smooth"** from [the cadence experiment's own predicted
outcomes](#the-cadence-experiment-for-the-probe-planned-2026-09-12-run-2026-09-13-see-result-below) —
the device is not the bottleneck at any density tested, and the uneven stepping heard through
MainStage lives in MainStage's own send path.

**This also disproves the write-needs-read belief** that has run since [the mid-gesture guard
section](#master-volume-drop-detection-read-rate-limiting-and-the-mid-gesture-guard-2026-09-10):
Phase D shows a write takes effect with no read anywhere near it, in flight or otherwise. Every
"the READ is what makes writes work" claim in this file predating 2026-09-13 is wrong; it was a
MainStage host-path artifact.

**New leading hypothesis for the uneven audible stepping:** irregular write spacing, from
one-message-per-flush contention between Master Volume writes and the popup's own redraws (see [the
open write-backs section](#master-volume-write-backs-do-not-all-reach-the-device-2026-09-12-open-hypothesis-3-disproved-2026-09-13))
— not device saturation, which is now ruled out. First step against it: `config.lua` no longer issues
a Master Volume READ on every `EID_A` tick (it cost a flush slot for a diagnostic that was never
required for the write to work); the single READ on entering an active session is kept, since it
costs one message per session and remains useful for logging.

**Caveat.** A run only means anything if the probe was actually selected on the keyboard during it —
a run that returned 0 replies across every phase was discarded on exactly this basis, since phases
already known to work also returned nothing that time.

---

## Master Volume write pacing: one per tick (2026-09-13)

Confirms the hypothesis above and closes it out. A captured flush log during an A-encoder sweep showed
four Master Volume writes leaving in a single timer tick, then a gap until the next:

```
FLUSH #359 tick=188 regionId=mvol
FLUSH #360 tick=188 regionId=mvol
FLUSH #361 tick=188 regionId=mvol
FLUSH #362 tick=188 regionId=mvol
```

Cause: `flush_pending` is called both from `controller_timer_trigger` and once per inbound SL frame from
`controller_midi_in`. A fast twist produces several inbound frames per tick, and a Master Volume WRITE
was never gated the way a display message is - each of those calls dequeued the 'mvol' entry the
instant a new one coalesced in, so the writes left in a burst rather than spread across the tick period.

The device itself is not the bottleneck: the four-phase probe result above already showed 121/121
writes landing correctly at a dense, EVENLY SPACED ~10ms cadence, and Jeroen confirmed that sweep sounds
smooth. **The same number of writes, delivered in bursts instead of spread out, sounds stepped. This is
about spacing, not throughput — sending more writes faster does not fix it, and should not be tried
again as an "optimisation".**

**Fix:** `mvolFlushReady`, a second pacing flag mirroring `displayFlushReady`'s existing shape (see the
"Display pacing" entry above) - granted once per timer tick by `controller_timer_trigger`, consumed by
`flush_pending` the instant it emits a Master Volume WRITE. The Master Volume READ and every protocol
message (identification, keepalive, logout) are deliberately left ungated, same as they are for the
display gate - the read is rare and diagnostic-only, and starving protocol traffic is what gets the app
dropped from the SL88's APP list. Coalescing under the existing 'mvol' regionId is unchanged: a burst of
encoder ticks still collapses to the newest value, which is exactly what the paced flush then sends.

**Effective tick rate during a gesture.** A per-tick gate is only as responsive as the ticks are
frequent. `show_master_volume_popup()`'s repeat-call branch (every EID_A tick after the first) calls
`request_quick_rearm()` unconditionally, which shortens an outstanding `KEEPALIVE_MS`/`POPUP_TICK_MS`
one-shot to `FLUSH_SOON_MS` (35ms) - confirmed by reading the code path, not assumed. So a gesture
already ticks at ~35ms, not the ~3s keepalive cadence; pacing Master Volume to one write per tick paces
it to roughly one write per 35ms, which is well within the dense cadence the probe proved sounds smooth.

---

## Recovering a silently dropped active session, bounded (2026-09-13)

Hardware evidence, captured mid-session: the SL88 stopped answering Identification Queries entirely -
no `7F 03 01` replies - while still sending unrelated traffic (`03 05 3F` encoder frames). No Logout
Request, no Standby, no Rejection; the app's registration was simply gone from the keyboard's side.
Because the session clock depends on the query's reply to re-arm the one-shot timer (see "The session
clock and the one-shot timer" above), the script then went silent permanently - Jeroen's report: "app
dropped out and did not come back". Root cause (why the keyboard de-selects the app) is still open;
this only makes the script recover once it happens.

**History.** A first version of this detector existed and was removed the same week - see "Master
Volume drop detection..." above. It fell straight to `STATE_IDLE` after 6s of silence with no cooldown
and no cap, and was pulled after a build containing it left MainStage feeling frozen with audio pops
while idle. That capture was lost to a manual restart, so the mechanism is suspected, not proven, but
credible: dropping to `STATE_IDLE` re-identifies, re-identifying can draw a Rejection, a Rejection
retries/bumps, and with nothing bounding the cycle it can spin.

**This version is bounded three ways, all designed to make that spin impossible:**

1. **Threshold raised to `ACTIVE_QUERY_DROP_MS` = 10s** (was 6s). One missed reply at the ordinary
   `KEEPALIVE_MS` (3s) cadence is normal jitter, not a drop; 10s is roughly 2x the SL88's own ~5s host
   timeout, comfortably past a single miss without waiting so long that a real drop sits unnoticed.
2. **`RECOVERY_COOLDOWN_MS` = 15s minimum between attempts.** Longer than the worst-case identify
   cycle (`MAX_IDENTIFY_RESENDS` resends at `KEEPALIVE_MS` cadence, ~9s), so a fresh attempt is never
   cut short by another trigger mid-cycle, and a recovery that does not stick cannot re-fire
   immediately - the exact shape of the suspected freeze.
3. **`MAX_RECOVERY_ATTEMPTS` = 3.** After three consecutive attempts with no intervening return to
   `STATE_ACTIVE`, the detector latches `recoveryGivenUp` and logs it, then stays silent for the rest
   of that script instance rather than retrying forever. A successful return to `STATE_ACTIVE`
   (`enter_active_session`) resets the count - the cap tracks attempts that never worked, not how many
   times a flaky link drops and recovers.

**Mechanism.** `activeMsSinceQueryReply` accumulates `timerArmedInterval` (real elapsed ms, not a tick
count - see `timerArmedInterval`'s own comment on why pacing is not constant) each tick while
`STATE_ACTIVE`, and resets to 0 on any Identification Query reply (`handle_sl_frame`'s `ID_QUERY`
branch resets it before even checking the result byte - a reply proves the round trip alive whatever
it says) or on entering `STATE_ACTIVE`. On firing, `controller_timer_trigger` sets `state = STATE_IDLE`
and lets the existing branch immediately below (`if state == STATE_IDLE then start_identification()`)
take it from there, rather than calling `start_identification()` a second time from two places.

**Does not fight the timer watchdog (`TIMER_WATCHDOG_FRAMES`).** That watchdog and this one watch
different signals for different failures: `TIMER_WATCHDOG_FRAMES` counts inbound MIDI *frames* to
detect MainStage losing the local one-shot itself (`rearm_timer`'s own watchdog), and its fix is to
re-arm the same timer. This detector counts elapsed *milliseconds* while `STATE_ACTIVE` to detect the
remote keyboard going silent, and its fix is to re-identify - it never touches `timerPending`,
`framesSinceTick`, or calls `settriggertimer` at all, so the two cannot double-fire or race each
other.

## Recovery did not fire; MainStage's churn masked it (2026-09-13)

First hardware run with the bounded recovery watchdog. The session dropped and the app came back — **but
not because of the watchdog.** The log contains no `recovery watchdog` lines at all.

What actually happened: MainStage tore the script down and re-initialised it, as it routinely does. Four
distinct instance tags appear in one run (`c805ac/7B`, `bd422c/78`, `42f32c/24`, `2a7a4c/43`), each a
fresh Lua state deriving a different instance byte from its own tag, each identifying successfully. The
user saw two APP-list entries at once, then the app working again under a new id.

**Why the watchdog didn't fire:** the dropped instance was almost certainly finalised by MainStage before
`ACTIVE_QUERY_DROP_MS` (10s) elapsed, so it never reached the threshold. The watchdog is not disproved —
it was never exercised. Treat it as untested on hardware, not as working.

**Newly visible cost of per-instance DeviceIDs.** Deriving the instance byte from `instanceTag` means
**every re-initialisation registers as a new app**, so the SL88's APP list accumulates entries across
MainStage's ordinary churn. Before per-instance ids, every incarnation collided on one id — bad for
identification, but it did yield a single entry. This is the same trade-off recorded under "Identification
and instance-ID collisions": bumping the instance byte registers as a different app and loses the user's
selection.

**The unexplored option remains the one noted there:** derive the instance byte from something stable per
*interface* rather than per Lua state — the `portName` passed to `controller_midi_in` is the obvious
candidate, since it differs between the two matched USB-MIDI interfaces but is identical across
re-initialisations of the same one. That would give distinct ids to genuinely concurrent instances while
keeping one entry per interface across churn. Not attempted; `portName` is only available once the first
inbound frame arrives, which is after identification is first sent, so it needs thought.

User's assessment of the current state: "workable for now."

### Concurrent instances: no action, they self-clean (decided 2026-09-13)

The run above showed **4 `controller_initialize` calls and 0 `controller_finalize`** — four concurrent Lua
states, each with its own derived DeviceID, all identifying successfully. Two drove real sessions (2482
and 509 log lines); two did almost nothing (6 and 4 lines).

Per-instance DeviceIDs are what made this visible: previously every instance collided on one id, so
exactly one was approved and the rest stayed inert. Unique ids fixed the collision and let all of them
register.

**Decision: leave it.** Jeroen's call, from watching the keyboard: the idle instances stop ticking, stop
keepaliving, and the SL88 drops them from the APP list on its own once it considers them dead. The
duplicate entries are transient. The "elect one active instance, others stay passive" option (the
`portName` discriminator, and CLAUDE.md's standing "decide whether the second instance should stay
passive" question) is therefore NOT being implemented — revisit only if duplicate entries or contention
become a real problem in use.

## v2.0.0 verified on hardware (2026-09-14)

The released v2.0.0 build was installed from `main` and exercised on the SL88 by Jeroen: **works fine.**
This is the first release of the relative-CC behaviour, the identification-resend fix, per-instance
DeviceIDs and log tags, and Master Volume driven from the A encoder.

Two things remain untested rather than proven, and should not be read as working because the release
was accepted:

- **The bounded session-recovery watchdog** (`ACTIVE_QUERY_DROP_MS` / `RECOVERY_COOLDOWN_MS` /
  `MAX_RECOVERY_ATTEMPTS`). It has still never fired. The run that exercised a genuine drop recovered
  through MainStage's own re-initialisation churn instead, before the 10s threshold elapsed.
- **The residual volume stepping on fast encoder turns.** Writes are evenly paced at one per tick, so
  the remaining coarseness is the ~35ms tick rate, not spacing. Improving it means going below the
  `FLUSH_SOON_MS` floor that previously caused display drop-outs.

## Value moved inside the ring (2026-09-14)

The popup's value moved from a band **below** the Knob bitmap to **inside** the ring, the label moved
below the ring, and the panel shrunk (`POPUP_H` 200 → 140) to reclaim the freed row. Shared by both
`show_popup()` and `show_master_volume_popup()` via the one `paint_popup_screen()` component.

**Supersedes the 2026-08-29 reasoning** behind the old layout
([the Knob bitmap replaces the ring](#the-knob-bitmap-replaces-the-ring-2026-08-29)), which put the
value below on the judgement that "a 61x54 icon cannot host a legible `SIZE_BIG` number." That call only
ever ruled out `SIZE_BIG` - it was never evidence against `SIZE_MEDIUM`, which the popup actually uses
and which is what now sits inside the ring.

**The non-overlap trap.** `popupValue` now sits inside `popupKnob`'s rectangle, breaking the NON-OVERLAP
RULE (`config.lua`, MARK: - Per-region memoization) on purpose. The Knob bitmap fully replaces the
pixels beneath it (no alpha), and it only has 13 fill levels against 128 possible values - so a knob
redraw is a much rarer event than a value change, meaning **every knob redraw is a value change, but not
every value change is a knob redraw.** Left alone, a knob repaint at an unchanged value's text would
wipe the number from the centre of the ring and leave it blank until the value next changed. `config.lua`'s
`draw_popup_knob()` compares the icon it is about to draw against the last one it actually drew
(`drawn['popupKnob'][4]`, the icon field of `draw_bitmap`'s own memo tuple) and clears
`drawn['popupValue']` whenever they differ - the same "clear the overlapping ids' memos together"
escape hatch used by `draw_popup_erase()`. `paint_popup_screen()` keeps queuing the knob before the
value, so the corrective resend lands in the same flush burst. Lua harness section 60 pins this
directly: draws the knob at same-icon and different-icon values and asserts the value's memo only
clears on the icon change.

**The text-background trap.** Write Text's background box fills its whole `maxWidth`, not just the
glyphs (confirmed on hardware). The value's box (`POPUP_VALUE_W`) is a new constant, deliberately
narrower than the ring's hole rather than reusing `POPUP_CONTENT_W`, so it can't paint an opaque bar
through the ring's sides. Harness section 59 asserts the value's box lies entirely within the knob's
rectangle on all four edges.

**Two numbers are still estimates, not measurements**, same as before: the Knob icon's inner hole width
(`POPUP_VALUE_W = 45`) and `SIZE_MEDIUM`'s glyph height (`POPUP_VALUE_GLYPH_H = 27`, the same
interpolated figure `config.lua`'s `SIZE_MEDIUM` comment already flags). Settling both is a hardware
task, not something the offline harness can prove - if a hardware look finds the number wrong, retune
the constant, not the reasoning above it.

## Sacrificial redraw painted the list line under a popup (2026-09-14)

**Pre-existing bug, exposed (not introduced) by the popup-in-ring rework.** `queue_sacrificial_redraw()`
branched directly on `displayMode`, so while a popup was showing (`displayMode == 'popup'`) it always
took the else branch and queued the LIST screen's ctx-bar duplicate - even when the popup was covering
the ZOOM screen. Confirmed on hardware: the patch list's top line appeared drawn over the zoom screen
whenever a popup was up. Fixed by branching on `popupPreviousMode` (what the popup covers) whenever
`displayMode == 'popup'`, falling back to `'zoom'` - matching `displayMode`'s own declared default - if
`popupPreviousMode` is somehow unset. Pinned by Lua harness section 61, both directions plus the
fallback.

## Popup value tuned on hardware: position and box width (2026-09-14)

Two eyeball corrections from a hardware run of the value-in-ring popup (the position and box-width
numbers were flagged as unmeasured estimates above; this is that hardware feedback, not a
measurement of either underlying value):

- **Position:** the value sat too high in the ring. Added `POPUP_VALUE_Y_NUDGE = 5`, applied on top of
  `POPUP_VALUE_Y`'s existing centring math, rather than changing what `POPUP_VALUE_GLYPH_H` means -
  the high position suggests the real glyph box differs from that 27px estimate, but this nudge doesn't
  resolve that, it just compensates for it. Containment (harness section 59) still holds with 9px of
  slack at the bottom edge.
- **Box width:** `POPUP_VALUE_W` tightened from 45 to 38 - at 45 the text background painted a visibly
  wide black bar inside the ring. 3-digit values were confirmed fine at 45, so there's some headroom
  left at 38, but this is untested on hardware for clipping at the new width.

## Dead-clock instrumentation and two recovery backstops (2026-09-14)

**Hardware evidence.** Turning encoders killed the session twice; the second time it never recovered.
The capture shows: last `timer tick #239` (`pending=2 draining=true`); afterward 28 inbound SL frames
arrived and were processed normally (CC batches still went out, so `controller_midi_in` was running and
reaching `rearm_timer()`); no tick ever fired again, and neither the timer watchdog
(`TIMER_WATCHDOG_FRAMES`) nor the recovery watchdog (`ACTIVE_QUERY_DROP_MS`) logged anything; the SL88
eventually stopped sending entirely, having dropped the app for want of a keepalive.

**Cause not determined.** Neither watchdog's decision inputs were logged, so the silence is ambiguous:
each may have correctly declined to fire, or wrongly declined - there was no way to tell which from the
capture alone. This work does not identify why MainStage stopped delivering the one-shot; it makes the
*next* occurrence legible, and closes two structural gaps that stopped the existing defences from ever
having a chance to run.

**Structural flaw: the recovery watchdog could not run in the case it was built for.**
`ACTIVE_QUERY_DROP_MS` recovery (see "Recovering a silently dropped active session" above) lived
entirely inside `controller_timer_trigger`, accumulating *elapsed ms* once per tick. A dead session
clock is precisely the condition it exists to recover from, and precisely the condition under which
that accumulation cannot advance - consistent with it never having fired across three prior hardware
sessions despite genuine drops (see "Recovery did not fire" and "v2.0.0 verified on hardware" above).

**Fix 1: instrument the decision.** `rearm_timer()`'s `timerPending` branch now logs
`timerPending`/`framesSinceTick`/`has_pending()`/`state`/`timerArmedInterval` whenever
`framesSinceTick` has crossed `TIMER_WATCHDOG_FRAMES` but the watchdog is declining to act (short of
`TIMER_WATCHDOG_FORCE_FRAMES`, or `has_pending()` is false). Rate-limited via
`TIMER_WATCHDOG_DIAG_EVERY_FRAMES = 40` (2x `TIMER_WATCHDOG_FRAMES`) to once at first crossing plus at
most once every 40 frames after - this runs on every inbound MIDI event including notes, so logging it
per-frame would flood the log the same way an earlier frame-count sweep already warned against.

**Fix 2: a second, ungated timer backstop.** `TIMER_WATCHDOG_FRAMES`'s existing `has_pending()` guard is
deliberate (see "Timer watchdog" above) - it is what keeps a long run of uncounted note traffic from
ever tripping the watchdog during a legitimately-outstanding one-shot. But it also means a clock that
dies while the display queue is *empty* was never recovered, silently and permanently - exactly what
the hardware capture shows once the 28 frames' worth of CC/note traffic drained whatever was left in
`pendingMessages`. `TIMER_WATCHDOG_FORCE_FRAMES = 600` forces a re-arm regardless of `has_pending()`.
Sized the same way `TIMER_WATCHDOG_FRAMES` was (comfortably above anything a real one-shot's own
`KEEPALIVE_MS`/`FLUSH_SOON_MS` cadence should ever let frames reach before firing on its own), but
without hardware data for the empty-queue case specifically - a real one-shot firing does not depend on
frame counts at all, so the only way this backstop mis-fires is if ordinary play manages to jam more
than 600 inbound events into a single outstanding interval, which no captured session has shown.

**Fix 3: the recovery trigger, reachable from the inbound path.** The re-identify action
(`recoveryAttempts`/`recoveryCooldownMs`/`recoveryGivenUp` bookkeeping, previously inline in
`controller_timer_trigger`) is now `trigger_recovery(reason)`, called from two places: the original
ms-based check (unchanged bounds - `ACTIVE_QUERY_DROP_MS` 10s, `RECOVERY_COOLDOWN_MS` 15s,
`MAX_RECOVERY_ATTEMPTS` 3), and a new `check_inbound_recovery()` called from `controller_midi_in`. The
inbound path cannot measure elapsed ms (no ticks means no clock), so it counts inbound *frames* instead
via `framesSinceQueryReply`, reset at the same three sites as `activeMsSinceQueryReply` (an ID_QUERY
reply, `enter_active_session`, and a fired recovery attempt). This is a coarse proxy, not a duration -
it under-counts a drop during quiet play and over-counts during a burst - which is why
`ACTIVE_QUERY_DROP_FRAMES = 1200` is set well above `TIMER_WATCHDOG_FORCE_FRAMES`: the cheap,
non-disruptive clock restart (fix 2) gets first chance to fix a merely-dead local timer before this
more drastic step (drop to `STATE_IDLE`, forcing a re-identify) runs. Both paths share
`trigger_recovery()`, so the cooldown and attempt cap bound them identically regardless of which one
notices the drop first.

**Explicitly not a proven fix.** All three changes are instrumentation and structural repair: they make
the failure observable and give the state machine a path to recover that previously did not exist. None
of them establishes *why* MainStage stopped delivering the one-shot in the first place. Treat the next
hardware capture's watchdog-diagnostic lines as the next real evidence, not this entry.

Pinned by Lua harness sections 62-64: the diagnostic's rate limit, the force backstop firing only at
its own (much higher) threshold while leaving the `has_pending()`-backed path unchanged, and the
inbound recovery path firing/cooldown/cap - all reached via `controller_midi_in` alone, with
`controller_timer_trigger()` never called, to prove they do not depend on a working tick.

Unrelated, same session: `POPUP_VALUE_Y_NUDGE` raised from 5 to 8 - still sat a touch high on hardware.
Containment (harness section 59) holds with 6px of slack at the bottom edge.

## Popup value repaint throttled (2026-09-14)

**Measured on hardware:** during one encoder sweep, `popupValue` flushed 399 times against
`popupKnob`'s 76. Write Text has no compositing to fall back on - it blanks its whole background box
before painting glyphs - so a redraw on essentially every tick (~28/s at `FLUSH_SOON_MS`) reads as a
visible blink. The ring flickers far less because it only has 13 fill levels, so it redraws about a
fifth as often.

**Fix:** `queue_popup_value()` throttles the value's redraw to at most once every
`POPUP_VALUE_THROTTLE_TICKS` (3) ticks - ~10/s, chosen as a trade against coarser value increments
during a fast sweep. It bypasses the throttle whenever `drawn['popupValue']` is `nil`, which is also
exactly the signal `draw_popup_knob()` sets when an icon change wipes the ring's centre - so that
invalidation still wins immediately, on the same tick, regardless of the throttle window.

**Staleness guarantee:** a throttled call sets `popupValueDirty = true` instead of drawing.
`flush_popup_value_if_due()`, called every tick from `controller_timer_trigger`, drains that flag once
`POPUP_VALUE_THROTTLE_TICKS` have elapsed since the last actual paint - so once encoder motion stops
and no further `queue_popup_value()` calls arrive, the next few ordinary keepalive ticks still paint
the settled value rather than leaving it one step behind.

Pinned by Lua harness sections 65-66: throttled cadence during continuous motion, the settled value
painted rather than left stale, the knob invalidation forcing the value through despite an unelapsed
throttle window, and `draw_popup_knob()`'s own repaint rate (memoized purely by icon) left unchanged.

### Popup rework verified on hardware (2026-09-14)

Jeroen exercised the reworked popup on the SL88 across several deploys: **"this is way better"**, layout
good, three-digit values fine, redraws clean through knob-level changes in both directions.

Settled after three rounds of tuning by eye, because neither the ring's inner hole nor `SIZE_MEDIUM`'s
real glyph height has ever been measured: the value box narrowed 45 → 38px, and the value nudged down 5
then 8px.

**Confirmed fixed on hardware:** the popup no longer paints the patch-list top line over the zoom screen
(`queue_sacrificial_redraw()` branched on `displayMode`, which is `'popup'` while a popup is up, so it
always took the list branch — pre-existing, exposed by the smaller panel).

**Not proven by this run:** the session recovery still has not fired. Two drops occurred; Jeroen restored
the app by re-selecting it on the keyboard, and the log shows no `recovery` or `watchdog` lines at all.
The mechanism is now *reachable* from the inbound path — previously it could only run from the tick
handler, which is dead in exactly the case it exists for — but reachable is not the same as proven.

### A encoder button mute (2026-09-14)

The A encoder's push button (`BID_A_ENC = 0x0B`) now toggles the SL88's audio-board mute: SHORT flips
it, LONG resets volume to `MVOL_SEED_DEFAULT` (60) and unmutes. Offline only — **nothing here has been
run against hardware yet.**

**The `VOL > 0x64` technique.** §6's write frame is `07 01 <VOL> [MUTE]`; omitting `MUTE` leaves it
untouched, which is why `msg_master_volume_write()` (the plain encoder-turn write) stays exactly as it
was — it must never carry `MUTE`, or turning the A encoder could flip mute as a side effect. To change
mute *alone*, the write needs a `VOL` byte the firmware will ignore, and the upstream answer says any
value over `0x64` (100) qualifies. `MVOL_IGNORE_VOL = 0x7F` was picked as that sentinel — the max legal
7-bit data byte. The new `msg_master_volume_mute_write(vol, muted)` builder is used for both the SHORT
toggle (`MVOL_IGNORE_VOL`, flipped `MUTE`) and the LONG reset (`MVOL_SEED_DEFAULT`, `MUTE=0` together —
a real volume and a real mute change in one message, since LONG wants both anyway).

**First LED message this project has ever sent.** `IT_LED = 0x02` (`<WLID> <state 0|1>`, on/off only)
had no builder before this — `msg_white_led()` is new. The A encoder's LED id, `WLID_A_ENC = 0x0A`, is
**probable, not certain**: it comes from `docs/full-functionality-plan.md`, a historical doc, not from
an authoritative table — the real white-LED id table lives upstream in `fatarsrl/sl-link`'s
`docs/hardware-io.md` and is not vendored in this repo. `0x0A` needs confirming against a lit ring on
the first hardware run.

**`BID 0x0B` has never been observed.** The spec claims the host never sees the A encoder's button
(reserved for USB audio), but §7 already records the opposite for A traffic in general — EID_A ticks
reach the host as ordinary messages with no special-casing needed. Expected to work the same way, but
unexercised: if the first hardware press logs nothing, the spec's "reserved" claim holds for the button
specifically and this feature stops there, which is a real possible outcome, not a bug.

**Startup state:** seeded from the READ reply already sent at `enter_active_session()`, which now also
sends the LED once unconditionally to establish it before any reply arrives (`set_master_mute`
called with the current default). If the reply's `MUTE` byte differs from that default, it corrects the
state and resends the LED; a reply with no trailing `MUTE` byte (§7 — trailing bytes are optional more
often than documented) leaves the assumed default (unmuted) alone.

**Popup:** `POPUP_H` grew by `POPUP_MUTE_HINT_H` (21px, `SIZE_SMALL`'s one *measured* height) plus
`POPUP_MUTE_HINT_GAP` (8px) to fit a "PUSH TO MUTE/UNMUTE" hint line, shown only when `popupCcNumber`
is `nil` (true only for the Master Volume popup — mapped-encoder popups always have a CC number). A
control switch mid-popup-session (no full erase) that moves away from Master Volume blanks the hint
with an empty Write Text call rather than leaving it stale, the same self-clearing idiom used elsewhere
in this file for blanked rows.

Pinned by Lua harness sections 19 (both 8- and 9-message popup counts), 27 (an addition confirming a
volume turn never touches `masterMuted`), 52 (per-tick ceiling raised 11 → 12), and new sections 68-69
(button SHORT/LONG behaviour and byte vectors, LED on/off bytes, the READ reply's optional `MUTE` byte).

## Mute and LED writes are dropped from MainStage (2026-09-14)

The mute write and the LED write from the section above were run against hardware. Both were
**ignored when sent from MainStage**, but `Scripts/probe-mute-led.swift`, sending byte-identical
messages directly over CoreMIDI with no MainStage in the loop, **worked reliably**. This is a
workaround for that asymmetry, not a diagnosis of it — nothing below explains *why* MainStage's path
drops these two messages specifically.

**Ruled out.** The message bytes themselves: re-checked against §6 and confirmed spec-correct — the
same bytes the probe sent successfully. And the `[message, query]` pairing shape `flush_pending()`
always uses: the probe's own four-phase run (paired and unpaired sends both worked) rules out pairing
as the cause.

**The remaining difference is repetition.** A volume turn writes on every tick of the gesture — dozens
per turn — so any single dropped write is invisible; the next tick's write lands a moment later and
the hardware ends up in the right state regardless. The mute write and the LED write are each sent
**exactly once** per button press. A captured failure shows `FLUSH #131 regionId=mvolMute bytes=12
queueDepthAfter=11` — the write went out, into a queue that was already 11 messages deep, and nothing
downstream shows it taking effect. A one-shot message dropped once is simply lost; the volume path
never faced that test because it never sends only once.

**The fix: repeat them, the way the volume path effectively does.** `MUTE_LED_REPEATS = 3` (survives
up to two drops); both `set_master_mute()`'s LED write and the mute WRITE itself now go out via the
new `queue_repeated()` helper, called `MUTE_LED_REPEATS` times. Coalescing was the obstacle: repeating
a `queue_message(msg, 'mvolMute')` call collapses to one queued entry the moment the second call finds
the same regionId already queued (see `queue_message`'s PER-REGION COALESCING comment) — the repeats
would never reach the wire as separate sends. `queue_repeated()` sidesteps this by queuing with no
regionId at all, the same "never coalesced" idiom protocol messages already use, so all N copies
append and drain one per flush.

**LED re-enabled.** `LED_ENABLED` was a temporary diagnostic gate added to isolate whether the LED
message was blanking the display; the probe confirmed the LED message genuinely lights the A encoder's
ring on this hardware, with no display side effect. The gate (constant and early-return) is removed.

**LONG press no longer folds MUTE into the volume write.** The combined write (`07 01 3C 00` — a real
volume together with `MUTE=0`) was also ignored from MainStage; the plain 3-byte form (`07 01 3C`,
`msg_master_volume_write()`, no MUTE byte at all) is the one proven to work. LONG now sends that plain
reset write, and separately issues the repeated unmute as an ordinary mute-only write
(`msg_master_volume_mute_write(MVOL_IGNORE_VOL, false)`), matching the SHORT-press shape.

Pinned by Lua harness section 12b (`queue_repeated` produces N separate, non-coalesced entries) and
the rewritten sections 68-69 (mute/LED assertions now expect `MUTE_LED_REPEATS` sends, and the LONG
reset write is checked for the plain 3-byte shape).
