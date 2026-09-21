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

Measured on hardware: a returned array of 78 bytes renders; one of 96 bytes renders **nothing at all**
— the whole array is discarded, not truncated. The SL Link spec itself has no such limit (Write Text is
`S(1)...S(N)` for arbitrary N; Max Width truncates visually in pixels), so this is purely a MainStage
transport constraint.

2026-09-21 measured the same thing in the shape `flush_pending` actually uses (`[display, query]`, where
the original table used two Write Texts): **78, 79 and 80 bytes all delivered**. `FLUSH_BUDGET` is
therefore **78**, raised from the 72 that had been a guess below the known-good value. It buys six
characters on every text line (`TEXT_STRING_CAP` 37 → 43), and a normal session confirmed it the same
day: the 43-character context bar rendered, patch changes and mode switches kept repainting, and the app
stayed in the APP list.

Earlier revisions of this section, and three other documents, stated the bracket as `[78, 87)`. That was
wrong: the table it derives from tested 96, not 87. The number is corrected here and in
`docs/implementing-sl-link.md` and `docs/mainstage-device-scripts.md`.

The exact ceiling is still unknown, and one attempt to pin it was abandoned — see below.

### Why the byte-ceiling probe was abandoned (2026-09-21)

A temporary probe walked the returned array upward one byte per trial, in the real flush shape, using the
Identification Query riding inside each trial as the detector: if the array arrives the SL88 replies, and
that reply is also what keeps the session clock running.

It could not be trusted, because **it destabilised the session it was measuring**. One run confirmed 78,
79 and 80 and then stalled; a later run sent the identical 78-byte array into a session that had been
healthy for 46 ticks with every query answered, and the session died on that first trial. A dropped array
and a dropped app produce exactly the same signature — silence — so the probe cannot tell them apart.

Two hardware facts fell out of the attempt regardless:

- **The Apply button (panel: CONFIRM) sends `01 0E 01` to the host AND exits the app on the SL88.** It
  cannot be used as a host-side binding; the keyboard acts on it locally at the same time.
- **Some button frames arrive addressed to `(00 1F)` instead of `(SL_HOST_ID, instanceID)`** and are
  discarded by `is_our_sl_frame` before any handler sees them — observed for Global short and long, and
  for Cancel. This is the most likely reason the Cancel button has never been confirmed on hardware.

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

**Status (2026-09-17): it sends one again, and this time it is gated.** Third attempt, and the first
that distinguishes a real quit from MainStage's startup teardown churn instead of sending
unconditionally. The two reverts below both failed for the same reason - the churn teardown released a
registration it should have kept.

Instrumenting `controller_finalize` settled it. It had never logged anything, so how often and in what
state it fired had never actually been measured; a capture then showed only **two** teardowns in a full
session, and they are trivially separable:

```
controller_finalize (state=identifying, tick=0,   pending=0)   <- startup churn
controller_finalize (state=active,      tick=537, pending=5)   <- the user quitting
```

So the gate is: send only from a registered state (LISTED/ACTIVE/STANDBY) **and** only past
`LOGOUT_ON_QUIT_MIN_TICKS`. The state test covers the observed churn case; the tick floor covers the
2026-09-10 failure below, where the churn teardown fired *after* APPROVED and a state test alone would
have let it through.

Confirmed on hardware 2026-09-17: the app reaches the APP list, activates and works normally, and on
quitting MainStage the entry disappears **immediately** rather than after the SL88's ~5s keepalive
timeout - which also removes the dead second entry that used to linger when relaunching. The log shows
the churn teardown correctly sending nothing and the real quit sending the request. No LOGOUT
CONFIRMATION is captured, because the script is already gone when it would arrive.

Prompted by the observation that Studiologic's own Numa Player deregisters instantly on close, so a
host evidently is expected to release its registration rather than let it time out.

**Cost of the gate:** a quit inside the first `LOGOUT_ON_QUIT_MIN_TICKS` ticks still falls back to the
~5s timeout. The verified run quit at tick 32 against a floor of 20, which is not a wide margin - if a
quick quit-after-launch is ever seen leaving a stale entry, the floor is the thing to lower, not the
state test.

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

> **Superseded 2026-09-20.** Both were measured: the hole is 36px wide starting 18px down, and
> `SIZE_MEDIUM`'s box is 23px. `POPUP_VALUE_GLYPH_H` no longer exists. See [Write Text box heights
> measured](#write-text-box-heights-measured-2026-09-20).

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

> **Superseded 2026-09-20.** The nudge is gone; the value box sits at the measured hole offset, which
> is where `NUDGE = 5` had put it. The conflict between that reading and this one is discussed in
> [Write Text box heights measured](#write-text-box-heights-measured-2026-09-20).

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

### A-button mute verified on hardware, and a follow-up (2026-09-14)

Verified by Jeroen on the SL88 after the repeat workaround landed: **short press mutes and unmutes; the
A encoder's ring lights when unmuted and goes dark when muted; the screen is not blanked; long press
resets the volume to 60 and unmutes; and turning the encoder while muted leaves it muted.**

Two corrections to earlier conclusions in this file:

- **The LED message never blanked the display.** It is spec-correct, `WLID 0x0A` is confirmed as the A
  encoder's ring, and the probe lit both it and the Zone 1 LED with an on-screen marker visible
  throughout. The single MainStage run that blanked had four instances with two colliding on id `4B`,
  and the SL88 discards draws from an app that is not selected — a far likelier cause than the LED. The
  earlier "the LED message blanks the display" claim rested on one run each way.
- **The firmware does not deviate on the MUTE byte.** Every mute form works from the probe, including
  `07 01 <vol> <mute>` and the `VOL > 0x64` mute-only form, and including when sent paired with an
  Identification Query in `flush_pending()`'s exact shape. The bytes and the pairing are both exonerated.

**OPEN — not all volume changes are carried out.** Jeroen reports that while turning the A encoder, some
volume steps do not take effect. This is the same family as the mute-write drops: single messages from
MainStage go missing, and the volume path has been masking it by streaming dozens of writes per gesture.
The repeat workaround (`MUTE_LED_REPEATS = 3`) applies only to mute and the LED, not to volume writes —
which are additionally throttled to one per tick, so a dropped one is simply a step that never happened.

Worth testing next: whether the dropped volume writes correlate with queue depth (the captured mute
failure had `queueDepthAfter=11`), and whether repeating or un-throttling volume writes closes the gap
without reintroducing the flicker the throttle was added to fix. **The underlying cause — why MainStage's
single messages are dropped at all, when byte-identical ones from a probe are not — remains unexplained.**

**Follow-up, same session: confirm the settled volume lands.** Beyond the dropped intermediate steps
above, the *final* value of a gesture must be guaranteed to reach the device — a dropped mid-gesture
write is corrected milliseconds later, but a dropped final write leaves the popup and the audio board
permanently disagreeing, silently. Options, in rough order of cost: repeat the last write once motion
settles (the mute/LED workaround, applied at gesture end rather than per tick); or issue a READ after the
gesture settles and re-send if the reported VOL differs from what was intended — the read reply is the
only evidence the device actually took the value. Note the read is answered reliably from a probe, and
was answered from MainStage in the 2026-09-13 runs, so this is testable.

## Settle re-send of the final Master Volume write (2026-09-16)

Implements the first option from the follow-up above: repeat the last write once motion settles,
rather than trusting the READ reply to drive a correction.

**"Settled" is defined the same way the popup already defines idle.** `check_mvol_settle()` reuses
`idleTicks` (frozen while messages are queued, advancing once per tick otherwise) exactly like
`check_popup_dismiss()` does — a gesture is settled once `MVOL_SETTLE_IDLE_TICKS` (2) idle ticks have
passed with no further `EID_A` activity. `mvolSettlePending` is set true by every `EID_A` tick and
cleared the moment the settle fires, so it fires once per gesture, not on every idle tick after — and
setting it true again is exactly what a resumed gesture does, so settling twice re-sends twice.

**Re-send count.** `MUTE_LED_REPEATS` (3), unchanged, via the same `queue_repeated()` a single dropped
message cannot survive on its own — see the mute/LED entry above for why 3.

**The READ is diagnostic only, deliberately.** A settle queues one `msg_master_volume_read()`, rate
limited to at most once per `MVOL_SETTLE_READ_MIN_TICKS` (2) `timerTicks` so back-to-back short gestures
can't spam it. The reply logs `settled volume confirmed vol=N` or `settled volume MISMATCH: sent X,
device reports Y` and stops there — it never writes `masterVolume` or re-sends again. This was a
deliberate choice, not an oversight: the READ reply has a mixed record on this hardware (one capture
pinned at a constant while writes plainly took effect; another tracked correctly — see
[the mid-gesture guard entry](#master-volume-drop-detection-read-rate-limiting-and-the-mid-gesture-guard-2026-09-10)
and the [read-reply anchor](#master-volume-read-reply-does-not-track-writes-2026-09-12)). Correcting
`masterVolume` from a read that might itself be stale risks thrashing the audio board's volume, which is
worse than an occasional silently-stale step. The log is the evidence a future correction loop would
need; building the loop itself is left for when that evidence exists.

## Startup LED discarded before login confirmation (2026-09-16)

**Hardware capture.** At session start the volume was correctly unmuted, but the A encoder's ring
never lit. The LED write did go out — `-> A ENCODER LED x3: unmuted` appears early in the log — but it
was sent from `enter_active_session()`, reached via the ID_QUERY self-heal path in `handle_sl_frame`
(the same path Lua harness section 35 covers for the Master Volume read) **before** the user had
actually selected the app on the keyboard. The SL88 discards display/LED traffic from an app that
isn't the one currently selected — the same long-standing behaviour that is why a full repaint is
required on login and on restart.

**Fix.** `handle_login()` already re-queues a Master Volume READ when `enter_active_session()` reports
it did *not* just perform the transition itself (i.e. the session was already ACTIVE from a prior
self-heal) — that guard is what stops a genuine LOGIN CONFIRMATION's resync from being swallowed. The
LED needed the identical treatment: `handle_login()` now also calls `set_master_mute(masterMuted)` in
that same branch, so the LED is (re)sent once the app can actually act on it. The
`enter_active_session()` send is left in place — harmless, and it is what covers the case where login
was already established before this script instance even started.

**No double-send.** Because the fix reuses the exact guard the READ resync already relies on, a bare
self-heal reaffirmation (no genuine login confirmation) still sends nothing, and a fresh transition
into ACTIVE still sends the LED exactly once (via `enter_active_session()`), not twice.

Pinned by Lua harness section 71: a login confirmation while already ACTIVE resends the LED
`MUTE_LED_REPEATS` times with the byte matching the current mute state (both muted and unmuted), a
bare reaffirmation sends none, and a fresh transition is not double-sent.

## Fast-turn Master Volume write budget (2026-09-16)

**Hardware measurement.** The one-write-per-tick pace (`mvolFlushReady`, see
[the write-pacing entry above](#master-volume-write-pacing-one-per-tick-2026-09-13)) cures audibly
uneven stepping on a slow turn, but a fast sweep generates deltas faster than ~28 writes/sec can
represent: one capture logged 120 A-encoder frames in against only 105 writes actually flushed - not
drops, just pacing too slow to keep up, so the audible/displayed volume visibly trails the knob.

**The pace must stay for slow turns.** Removing or loosening it outright would reintroduce the bursty
stepping it was added to fix. Jeroen's decision: let writes go out faster while turning quickly,
keeping the existing pace for slow turns.

**What counts as fast.** The SL88's own encoder ticks are speed-sensitive - observed ±1 for a slow
turn up to ±8 for a fast one - so a single frame's delta magnitude is a direct, per-frame signal of
how fast the physical knob is moving, with no extra bookkeeping needed. `MVOL_FAST_DELTA_THRESHOLD`
(3) marks a delta at or above it as fast: comfortably above a single slow detent, comfortably below
the fastest observed speed.

**The mechanism.** `handle_sl_frame`'s EID_A branch tags the queued write's message table with
`.fast` when its own delta meets the threshold - a slow delta leaves the tag unset. `flush_pending()`
still spends `mvolFlushReady`'s ordinary one-per-tick grant first; only once that is gone does it check
whether the head write is tagged `.fast` and, if so, let it through anyway, counting the emission in
`mvolFastWritesThisTick` (capped at `MVOL_FAST_WRITES_PER_TICK - 1` = 3 extra writes). Both counters
reset together each real `controller_timer_trigger` tick, so the budget is a per-tick-window allowance,
not a running total - a sustained fast sweep flushes up to `MVOL_FAST_WRITES_PER_TICK` (4) writes in
one window (a ~4x speed-up over the base pace) and then leaves a single coalesced backlog entry,
carrying the newest value, until the next tick resets the budget. A slow turn never sets the tag, so
it is completely unaffected - exactly the pre-existing one-write-per-tick behaviour.

**Trade-off against the anti-jitter fix.** 4 was picked as a bound comfortably above the base rate
without approaching "one write per frame," which was the shape that produced audible stepping in the
first place when the device saw an uneven burst-then-gap pattern. A fast turn's writes are evenly
paced relative to the frame rate that produced them (each additional write requires its own inbound
frame reaching `flush_pending`, so the emission rate cannot outrun the physical rate the encoder is
actually generating), so this does not reintroduce the original bursty pattern.

**Keepalive protection.** The fast-turn bypass changes nothing about how often
`controller_timer_trigger` itself fires - that clock is governed entirely by `settriggertimer`/
`timerPending`, untouched by this change. Every `flush_pending` call this mechanism enables still runs
through the same call sites that already pair a display/volume message with the Identification Query
(`flush_pending(true)` from `controller_midi_in`), so the extra writes never come at the query's
expense - they ride along with it, the same as an ordinary write always has.

Pinned by Lua harness section 72: a slow delta never sets the tag and still emits at most one write
per tick; a fast delta bypasses an already-spent grant; a sustained fast sweep flushes exactly
`MVOL_FAST_WRITES_PER_TICK - 1` writes before the budget caps out and leaves one coalesced backlog
entry rather than piling up; the session clock keeps re-arming throughout; and the next real tick
resets the budget and drains the backlog.

### Mute, LED and fast-turn pacing verified on hardware (2026-09-16)

Jeroen's verdict after the final round: **"good enough. not exactly smooth, but workable."**

Confirmed working on the SL88: short press mutes and unmutes; the A encoder's ring lights on login and
tracks mute state; long press resets the volume to 60 and unmutes; turning the encoder while muted leaves
it muted; the settled volume lands where the popup says it does; and a quick turn now keeps up rather
than trailing.

**Residual, accepted:** fast turns are not perfectly smooth. Volume writes are paced at one per tick for
slow turns (which cured the audibly uneven stepping) and allowed up to four per tick when the encoder
delta is 3 or more. That is a deliberate trade — loosening the pacing further risks reintroducing the
unevenness it was added to fix, and crowding the budget the Identification Query and keepalive share,
which has previously got the app dropped from the APP list.

**Single messages from MainStage are silently dropped**, while byte-identical ones from
`Scripts/probe-mute-led.swift` always arrive. Ruled out by hardware test: the message bytes
(spec-verified against upstream `docs/hardware-io.md`), and the `[message, query]` pairing shape
`flush_pending()` uses. The workaround throughout is repetition — mute, the LED, and the settled volume
are each sent three times. **Diagnosed and the workaround removed on 2026-09-17 — see
[One SL message per tick](#one-sl-message-per-tick-2026-09-17) below.**

**The settle read-back produced no data.** Seven `SETTLE: resend x3` lines in the capture and zero
`settled volume confirmed` / `MISMATCH` lines, so the diagnostic READ either never went out or was never
answered. **Resolved on 2026-09-17:** it went out every time and was dropped every time, for the same
pacing reason as the mute and LED writes — it now answers reliably. See
[One SL message per tick](#one-sl-message-per-tick-2026-09-17).

## Every LED id swept and identified (2026-09-17)

`Scripts/probe-leds.swift`, a new standalone probe, lit every White LED id `0x00`-`0x1F` and every RGB
`LID` `0x00`-`0x07` one at a time with the id named on the SL88's own screen. The resulting table is in
`docs/implementing-sl-link.md` §5. Run logged in, fw 1.1.2, zero `MIDISend` errors.

**All 12 white LEDs are contiguous from `0x00`**: ten button lamps (Zone 1-4, APP, Apply, Cancel,
Home, Global, DAW) at `0x00`-`0x09`, then the A encoder ring at `0x0A` and the B encoder ring at
`0x0B`. `0x0C` and above are dark. This **confirms `WLID_A_ENC = 0x0A`**, which had carried a
"PROBABLE, NOT CERTAIN" caveat in `config.lua` since it was first guessed from the upstream docs, and
establishes `0x0B` as B's ring.

**A B encoder ring LED exists.** This was the open question behind the sweep: `docs/full-functionality-plan.md`
had B's LED as an unverified id, so nothing could be built on it. It is real, and on/off only — it can
show B's mute state but never a volume level.

**Ids wrap: the lamp is `WLID mod 13`.** Twelve lamps plus the dark `0x0C` slot give a period of 13,
so `0x0D` is Button 1 again, `0x18` the B ring, `0x19` dark, `0x1A` Button 1. Confirmed by lighting
`0x00`, `0x0D`, `0x1A`, `0x18`, `0x19`, `0x0C` on a logged-in session. This means an out-of-range id
silently lights the wrong lamp rather than being ignored - there is no safe no-op `WLID`.

**Pacing matters more than range when a human is the instrument.** The first run stepped 32 ids at 3s
each and produced a confident but wrong reading — a ten-lamp cycle, making `0x0A` look like Button 1
and implying the encoder rings did not exist at all. The wrap it spotted was real; the period was not,
because the two ring lamps at `0x0A`/`0x0B` are easy to miss when the eye is on the button row. Re-running the same ids at 8s
each gave the correct table. Nothing in the log distinguished the two runs; both were logged in with no
send errors, because an LED has no reply and no log signal of its own. When the only oracle is a person
watching the hardware, slow the sweep down rather than widening it, and confirm any surprising negative
at a slower pace before recording it.

## One SL message per tick (2026-09-17)

The 3x repeat workaround above was hiding a bug in our own pacing. `MUTE_LED_REPEATS` is gone and the
mute write, the LED write and the settle write are single sends again.

**Root cause.** `flush_pending`'s `is_paced_and_blocked` only ever gated two itemTypes — `IT_DISPLAY`
and `IT_MASTER_VOLUME`/`MVOL_WRITE`. `IT_LED`, `IT_SYSTEM`, `IT_IDENTIFICATION` and `MVOL_READ` hit the
final `return false` and could never be blocked. That would be harmless if `flush_pending` ran once per
tick, but it runs **once per tick plus once per inbound SL frame**, from four call sites. During a
gesture that is 2-3 flushes per tick window, so an ungated message left on whichever flush came first —
typically the query-reply flush trailing ~2ms behind the tick flush.

A traced mute press put the three LED writes on the wire at **2ms, 37ms and 39ms**. Two of them land
inside the inbound round-trip window, immediately behind another SL message — the exact condition rule
5 says the SL88 silently drops. `Scripts/probe-mute-led.swift` wins because it sends one message with
nothing in front of it. The asymmetry was ours, not the hardware's.

Two facts corroborate it. The **settle READ produced zero replies** (seven `SETTLE: resend x3` lines,
no confirm/mismatch lines) — `MVOL_READ` was explicitly unpaced, and harness section 54 *asserted* that
as intended. And the **volume path never showed the bug**, because it writes dozens of times per
gesture, so a dropped write is corrected by the next tick's.

**The fix.** `slFlushReady`, a shared per-tick permit that every queued message needs on top of its
class flag, granted once per tick by `controller_timer_trigger` and consumed by whichever queued
message goes out. The `.fast` Master Volume bypass is the single exception, so fast turns keep their
feel. The trailing Identification Query is untouched — it is appended rather than dequeued, so the
session clock is unaffected.

**Rejected: giving the keepalive priority for the permit.** Tried first, to protect rule 6's ~5s
APP-list timeout now that only one message leaves per tick. It was over-cautious and delayed the
settled popup value by a tick. A non-empty queue rearms the timer at `FLUSH_SOON_MS` (35ms), so a
keepalive behind a full repaint waits milliseconds, not seconds; it takes its turn in queue order like
everything else.

**Harness.** New section 73: one queued message per tick across mixed itemTypes, and a ledger assertion
that every message removed from `pendingMessages` appears in the flush's `.midi` — sections 3 and 8
drain the queue but discard the return value, so they could not tell "emitted" from "dropped on the
floor". Section 54's `a Master Volume READ is never paced` survives as written (it is about
`mvolFlushReady` specifically); (d) in section 73 asserts the READ *is* paced by the shared permit.
Mutation-tested by a separate agent across eight mutations; no assertion passed when it should have
failed.

**Confirmed on hardware (2026-09-17).** SL88 MK2, script 2.2.0, one session of 1,275 log lines.

The settle READ — the sharpest signal, silent on every prior run — produced **five**
`settled volume confirmed` lines (vol=75, 78, 77, 60, 86), each preceded by its `MASTER VOLUME READ
reply`. The login-time READ was answered too (`07 00 3C 00` → `vol=60 mute=0`). The diagnosis is
right: the READ was always going out and always being dropped for arriving behind another message.

Everything else the fix touched held. Mute and unmute each cost **one** LED write and **one** mute
write — `FLUSH #33 ... msg=F0 00 20 1A 16 03 33 02 0A 01 F7` is the whole of the login LED paint,
where three copies used to go. A LONG press reset to 60 and unmuted, twice. The queue drained strictly
one message per tick throughout (ticks 25-34 emptied an 8-deep repaint one message at a time). The
keepalive never missed a flush and the app was not dropped from the APP list, which was the regression
the rejected keepalive-priority variant existed to guard against — it was not needed.

Jeroen's verdict: **"looks good ... reaction speed is much better"**, with one regression, below.

## Popup value wiped by its own ring redraw (2026-09-17)

Found at the hardware gate for the change above, and caused by it. In some situations the number
inside the popup's ring gauge is no longer visible.

`popupValue` draws *inside* `popupKnob`'s rect — the documented escape hatch to the non-overlap rule —
so a knob redraw repaints the whole icon and wipes the centre. The number must therefore always be
painted **after** its knob.

**Root cause: `queue_message` coalesces in place.** An entry already in `pendingMessages` keeps its
original queue position when a later draw updates it (`pendingMessages[i] = msg; return`). So:

1. A paint where only the value changed queues `popupValue` at position *k*.
2. Before *k* drains, a paint where the icon changed appends `popupKnob` at the tail — and the paired
   `queue_popup_value()` coalesces the value back into position *k*, now **ahead of its own knob**.
3. The value is emitted first, the knob repaints over it and wipes the centre, and nothing follows.

The hardware trace shows exactly that: `FLUSH #116 tick=115 regionId=popupValue`, then
`FLUSH #119 tick=118 regionId=popupKnob`, then nothing, then dismissal with the centre still blank.
Invisible before the change above, because both messages left inside one display refresh and the
order never showed; under one-message-per-tick they are three ticks apart.

**Rejected: a `popupValueOwed` debt flag.** Built first, on the theory that the paired value redraw was
being *stranded* by the repaint throttle or by `dismiss_popup`. It cannot be: `draw_popup_knob` has one
caller, `paint_popup_screen`, with `queue_popup_value()` on the next line, so the pairing is
unconditionally synchronous — and `draw_popup_knob` already cleared `drawn['popupValue']` in the same
branch, so the new flag was always in lockstep with the existing signal and changed no behaviour. The
mutation pass proved it: deleting the owed bypass from `flush_popup_value_if_due`, and deleting the
`owed` term from `queue_popup_value`'s `forced` condition, each left the suite green at 442/442. The
flag was untestable because it was unreachable as a distinct state. Worth recording as a case where the
tests were green, the mechanism was plausible, and the fix was a placebo — the independent mutation
pass is what caught it.

**Not fixed by relaxing the pacing.** Letting the pair share a flush or a tick is precisely what rule 5
forbids and what the change above removed. The value trailing its knob by one tick (~35ms at
`FLUSH_SOON_MS`) is fine; being emitted *before* it is not. The fix drops any pending `popupValue`
entry when the knob re-queues, so the value is appended behind it instead of coalescing into an older,
earlier slot.

## Follow-up: can settings be stored and read back? (registered 2026-09-17)

Idea, not yet investigated: wire the Global button to a settings screen that edits the CC mappings
live, instead of them being constants in `CC_MAP` that require an edit-and-redeploy.

The screen itself is the easy half — it is another paint function in the same family as the list and
zoom screens, and the Global button already reaches the host as a button event. The open question is
**persistence**, and there are two candidate homes for it, neither confirmed:

- **Host side.** MainStage's Lua sandbox has no `io`/`os` and no `UserDefaults` equivalent, so nothing
  currently survives a script reload except what MainStage re-derives — which is why `instanceID` is
  generated per run rather than persisted. Worth checking with the `probe-mainstage-internals` skill
  whether the host exposes any storage or preference API at all before assuming it does not; that
  skill reads the shipped application rather than guessing.
- **Keyboard side.** The SL88 stores its own configuration, and the spec's Hardware/Pedal Settings
  queries are currently out of scope for this project. If those can be read and written over SL Link,
  the mappings could live on the keyboard, which would also make them survive a machine change. Start
  from the upstream spec's `docs/` tables rather than from our code.

Without persistence the screen is still worth something (edits lasting the session), but the value is
mostly in the mappings sticking, so settle the storage question first.

**Note the versioning consequence:** changing a CC mapping is what the policy calls a **major** bump,
because the 34 CCs are MIDI-Learned by hand in MainStage and renumbering one silently breaks a working
rig. A settings screen that lets the user re-map at runtime makes that breakage a user action rather
than a release event, so it needs a deliberate answer for what happens to an existing concert's learned
assignments.

## Stale identification requests (2026-09-17)

Found on the second hardware run of the one-message-per-tick change, when Jeroen reported the app
dropping out of the APP list during slow encoder turns.

Not the keepalive, which was the predicted risk: the capture showed 338 ticks contiguous and 338
identification replies, so the session clock never faltered. The cause was the startup queue. During
identification the script queues an Identification Request, retries it, and queues more. Approval then
arrives — but at one message per tick a 15-deep startup queue still holds those requests, and they go
out *after* approval:

```
FLUSH #11 tick=10 ... queueDepthAfter=7 msg=F0 00 20 1A 16 03 11 7F 00 ... F7   <- stale Request
<- IDENTIFICATION REJECTED (reason 00) for instance 11
re-identify retry 1/2 as (03 11)
```

Each stale request draws a `REJECTED (reason 00)`, `handle_identification_rejected` treats it as a real
DeviceID collision, and re-identification restarts — tearing down a working session. The cycle repeated
several times in one run. Before the pacing change the queue drained several messages per tick, so the
stale requests cleared around approval rather than long after it.

**Two fixes, because either alone leaves a hole.** `handle_identification_approved` now purges queued
Identification Requests (`drop_queued_identification_requests` — they carry no regionId, so
`drop_queued_region` cannot reach them). And `handle_identification_rejected` ignores a rejection that
arrives once the state is already LISTED/ACTIVE/STANDBY: a Request is only ever sent while identifying,
so a rejection after approval can only be a stale echo. A rejection *during* identification still takes
the retry path unchanged.

Harness section 76 covers all three behaviours, mutation-checked: removing the purge fails the purge
assertions, and removing the state guard fails the stale-echo assertions.

**Worth noting as a pattern.** This is the second latent defect that one-message-per-tick pacing
exposed rather than caused — the first being the popup value/knob ordering. Slowing the drain turned
queue contents that used to clear within a tick into state that persists for many, and anything queued
speculatively during a transition now outlives the transition.

## Second hardware run: both fixes confirmed (2026-09-17)

Re-ran after the popup ordering fix and the stale-request purge. SL88 MK2, script 2.2.0, 419 ticks.

- **Zero post-approval rejections.** Two rejections before approval (the ordinary startup retry), then
  `APPROVED as 03 40`, then `LOGIN`, and nothing after. The stale-echo guard in
  `handle_identification_rejected` never had to fire, because the purge stopped the requests reaching
  the wire at all - the guard stays as a backstop for any path that queues one later.
- **Popup ordering holds.** Every `popupKnob` flush is followed by its `popupValue` flush, never the
  reverse; the temporary pairing diagnostic fired 25 times and resolved every time. Jeroen confirmed
  the number stays visible through slow turns, fast turns and an abrupt stop.
- Settle READ confirmed twice, no mismatches. 419 ticks contiguous, 419 keepalive replies.

**Unlooked-for improvement: logout via CANCEL reacts much quicker.** Jeroen noticed this without being
asked to look for it. It follows from the same change - logout is a request/confirm pair, and the
confirm used to queue behind whatever else was pending and, before the pacing fix, could be one of the
messages lost to arriving behind another. Worth remembering that the pacing work paid off somewhere
nobody was measuring.

## controller_midi_out reports real parameter values — with a screen control (2026-09-17)

**The old finding was wrong, and the missing variable was the screen control.** `config.lua`'s popup
comment stated that `controller_midi_out` "was confirmed on hardware to report nil
name/valueString/color for the mapped CC itself", which is why the popup was built on `encoderValue`,
a local accumulator seeded at 64. Re-probed today: it reports nil only for a control with no **screen
control** in the concert. Assign one and it reports fully.

Captured from the B encoder (CC 63) once a screen control for output 1-2 volume existed:

```
midi_out st=BF d1=63 d2=90 name=Volume valueString=+0,0 ㏈ color=1.00/0.90/0.31
midi_out st=BF d1=63 d2=85 name=Volume valueString=-1,0 ㏈ color=1.00/0.90/0.31
```

- `name` is the screen control's name, `valueString` the **real formatted value** (locale-formatted -
  comma decimal separator here), `color` a table of `r`/`g`/`b` floats 0.0-1.0.
- **`d2` is ABSOLUTE**, not the relative delta we send. It tracks the parameter's own 0-127 position,
  so the ring gauge can read it directly and `encoderValue`'s accumulator is unnecessary in this mode.
- **It fires unprompted and repeatedly.** A single static button produced 2,929 identical calls with no
  user input at all, which is why every shipped implementation caches before drawing. Cache on the
  tuple, not on the event.
- **Our own outbound SL Link SysEx passes through this callback** (`st=F0`, all metadata nil), so what
  this callback returns for an unhandled event decides whether our display traffic survives. Return
  `nil` on every unhandled path.

  The shipped scripts disagree on the default, so the corpus is not a single answer: 12 of the 14 fall
  through to `nil` (all six Arturia, TranzPort, Komplete Kontrol S61, GTR Ground, all three Axiom Pro),
  while KONTROL49 and microKONTROL fall through to `{}` - *"filter everything, that hasn't been
  processed, the controller ignores it anyway"*. But **none of them swallows SysEx**: both KORG scripts
  make passing it their very first branch, `return nil -- always forward SysEx to the device`. So the
  danger is not KORG's default as such, it is copying that default without its SysEx exemption.

### Popup layout: two modes

Chosen with Jeroen. `POPUP_H` stays 169 so the verified legacy layout is untouched; only the feedback
mode is new. Panel spans y 35-204.

| Feedback mode (screen control exists) | y | Legacy mode (no feedback) | y |
|:--|--:|:--|--:|
| `popupTitle` — parameter name, SIZE_SMALL | 45 | `popupKnob` — ring, fill from `encoderValue` | 57 |
| `popupKnob` — ring, fill from `d2` | 70 | `popupValue` — 0-127 number, INSIDE the ring | 78 |
| `popupValue` — `valueString`, SIZE_MEDIUM | 132 | `popupLabel` — `ENC n - CC nn`, SIZE_MEDIUM | 123 |
| `popupMuteHint` — only if a mute mapping exists | 165 | `popupMuteHint` — Master Volume only | 158 |

**The 2.2.1 overlap fix stays.** Legacy mode still draws `popupValue` inside `popupKnob`, so the
non-overlap escape hatch and `drop_queued_region('popupValue')` in `draw_popup_knob` remain load-bearing
for that mode. Feedback mode's regions do not overlap.

**A layout change must re-erase.** The two modes place `popupValue` at different y positions, and
memoization only redraws a region, it never clears the one it vacated. Switching the popup between a
feedback control and a non-feedback control mid-session must re-run the filled-rect erase, not rely on
the new content covering the old.

**Mute:** show the hint and bind the ring LED only when the paired push button's reported parameter
name contains "Mute". **Lit = unmuted**, matching the A ring's existing convention.

**Non-ASCII units.** `㏈` is three UTF-8 bytes, each clamped to a space by `append_text`, so it would
render as blanks. Substitute known units (`㏈` -> `dB`) and strip anything else outside 0x20-0x80 rather
than emitting runs of spaces.

**Scope reality:** only controls with a screen control report. In the test concert that was two -
`PANIC!` and `Volume`. Every other encoder falls back to legacy mode.

### Mute ring LED: four faults found on hardware (2026-09-17)

The LED half of the feedback work needed four fixes, each found by Jeroen on a separate run. Recorded
because three of them are timing/lifecycle traps rather than logic errors, and the last one repeats a
mistake this document already warned about.

1. **Driven from the popup paint.** The LED write lived in `paint_popup_feedback`, so it needed an
   encoder *turn* to fire - but the mute is pressed on the paired push button, which neither opens nor
   repaints the popup, and the popup dismisses after ~2s regardless. It is a persistent indicator, so
   it now drains from `flush_mute_leds()` once per timer tick, independent of the popup.
   `controller_midi_out` cannot queue it directly - that callback must never queue.
2. **~3s lag.** The tick is `KEEPALIVE_MS` when idle. A mute state change now calls
   `request_quick_rearm()`, pulling the next tick to `FLUSH_SOON_MS`. Safe from a callback MainStage
   floods, because that helper only acts when the timer is armed at the slow interval and only a real
   state change reaches it.
3. **No mapping left the lamp lit.** With no mute feedback the code *skipped* the ring, leaving
   whatever it happened to show. It now dark-asserts. Related: a **concert change** must drop stored
   feedback entirely (`midiOutFeedback = {}`), because MainStage never announces that a control it used
   to report is gone - it sends `'Unmapped'` only for controls that still exist. Feedback is
   deliberately KEPT across patch changes within a concert; clearing per patch would blank the popup
   until MainStage happened to re-report.
4. **Discarded before login.** The dark-assert went out at tick 6, before `LOGIN` - and the SL88
   discards anything sent before the app is selected, exactly as
   [Startup LED discarded before login confirmation](#startup-led-discarded-before-login-confirmation-2026-09-16)
   records. The memo clear had been put in `enter_active_session`, which `handle_login` calls only on
   the *not already active* path - i.e. not the normal one. `handle_login` now clears
   `encoderMuteLedSent` unconditionally, alongside the `set_master_mute` re-send that was already there
   for the A ring. **The lesson is that the existing A-ring re-send is the pattern to copy for any new
   LED, not an A-specific quirk.**

A regression the harness caught on the way: `flush_mute_leds` initially queued during
`STATE_REIDENTIFY_WAIT`, competing with the identification retry for the one-message-per-tick permit.
It is ACTIVE-only.

### controller_midi_in reviewed against the host contract (2026-09-17)

Checked against `docs/mainstage-device-scripts.md` section 3-4 and the section 11 checklist, as the
other half of the `controller_midi_out` work.

**One real defect, fixed.** `flush_pending_cc` returned `{ midi = {} }` when every queued relative
delta netted to zero. Per the contract's return table an empty table **swallows the inbound event**,
and the `#pendingCCOrder > 0` branch also pre-empted that round's SL flush - so the round lost its
display drain and its keepalive query to send nothing at all. It returns `nil` now, and
`controller_midi_in` falls through to the flush.

Three harness assertions had been encoding the defect as intended behaviour (`#out.midi == 0`); they
now assert `nil`.

**Everything else already conformed**, verified rather than assumed: the signature
`(midiEvent, portName)` matches all 20 shipped implementations; `midiEvent` is read 0-indexed; the
timer is re-armed here and never from `controller_timer_trigger` (rule 6); musical MIDI returns `nil`
and is never swallowed; `outport` uses the short port name.

## Write Text box heights measured (2026-09-20)

`SIZE_MEDIUM`'s glyph height had been an estimate since the display work started, and the open item in
`docs/mainstage-integration.md` framed it as a spec disagreement to reconcile. It is not one: the
upstream spec contradicts **itself**, at the pinned commit `4c0824d` and at `main` alike.
`sl-link/docs/display-messages.md` says in prose "the size of the text can be selected between *small*
(21px), *medium* (27px), *big* (33px)", and a few lines later, in its table: `0x00` Small (21px),
`0x01` **Medium (22px)**, `0x02` Big (33px). So 27 was never an interpolation of ours - it is one of
the two figures the spec itself publishes.

**Measured on hardware** (SL88 MK2, firmware 1.1.2) with `Scripts/probe-text-metrics.swift`:

| SIZE | spec table | spec prose | measured |
|:--|:--|:--|:--|
| `SIZE_SMALL` | 21px | 21px | **18px** |
| `SIZE_MEDIUM` | 22px | 27px | **23px** |
| `SIZE_BIG` | 33px | 33px | **27px** |

Every published figure is too large, and medium is neither of the two on offer. Treat the spec's pixel
heights as font sizes or line pitches, not as the height of Write Text's background box - the box is
what a layout actually has to fit, since it fills the whole `maxWidth` opaquely.

### How it was measured, and why the first attempt failed

Round one drew fixed 21/27/33px caliper bars beside a text box at each size and asked which bar's
bottom edge was flush with the box's. That established the direction - all three too large - but
stalled there: 1px resolution and the ring's hole were both reported "hard to see". A flush-edge
judgement is a poor instrument for a 1px difference.

Round two made the keyboard measure itself. Three copies of the same string are stacked exactly `H`
apart in alternating background colours, with an encoder driving `H`:

- `H` too large -> black seams appear between the stripes
- `H` too small -> each stripe clips the one above it, leaving the last stripe visibly thicker
- `H` exact -> one continuous block: no seam, equal stripes

Seam / no seam is a binary judgement, so it resolves to 1px. The same probe draws the real Write Text
box over the Knob bitmap, with encoders on its width and y offset, for the hole.

### The Knob bitmap's hole

The largest box that fits without touching the ring is **36px wide, starting 18px down** the 61x54
icon - `KNOB_HOLE_W` and `KNOB_HOLE_DY`. The shipped `POPUP_VALUE_W = 38` was 2px too wide and had
been painting an opaque bar through the ring's sides.

This replaced `POPUP_VALUE_GLYPH_H = 27` and `POPUP_VALUE_Y_NUDGE`, an eyeball correction that had
been guessed twice (5, then 8) because it was absorbing two unknowns at once: the glyph height *and*
where the hole sits inside the icon. `POPUP_VALUE_Y` is now `POPUP_KNOB_Y + KNOB_HOLE_DY` with no
correction term. `POPUP_HINT_Y`'s duplicated literal `27` became `TEXT_H_MEDIUM`, which moves the
Master Volume hint row 4px up.

`POPUP_MUTE_HINT_H = 21` stays as it is: it is space reserved in the panel, not a glyph height, and
shrinking it to 18 would move the whole popup for no visible gain. The harness asserts it stays
`>= TEXT_H_SMALL`.

### A conflict with the 2026-09-14 note

`POPUP_VALUE_Y_NUDGE = 5` put the value box at dy=18 - exactly where the caliper settled - and [the
note from that day](#value-moved-inside-the-ring-2026-09-14) records it as still sitting "a touch
high", which is what pushed it to 8 (dy=21). The two judgements used different instruments: 2026-09-14
was an in-situ look at the live popup with a 38px box, this one an isolated box driven against the
ring until it visibly cleared it. The measurement is the better evidence and is what ships - but the
in-situ look is what a user actually sees, so if the value reads high again on the next hardware run,
the cause is inside the glyph box (ink sitting high within it), not the geometry. Do not re-introduce
a nudge without measuring which of the two it is.

### Harness

Section 59 asserts against the measured hole rather than the icon's bounds - the 38px box fit the icon
and still hit the ring, so the old assertion could not have caught the defect. Section 83 checks that
the five zoom-screen rows do not overlap at the measured heights; rule 4's non-overlap requirement was
previously unverifiable, because no real glyph height existed to check it against. Both were
mutation-tested: widening the value box to 45, nudging it 3px above the hole, setting
`TEXT_H_MEDIUM = 40`, shrinking the hint row to 12, and moving `zname` to y=60 each fail exactly one
assertion, and the first of those fails only the hole check - not the icon-bounds checks.

### Confirmed on hardware (2026-09-20)

Run under MainStage with the measured constants in place: the value box clears the ring's sides at
`POPUP_VALUE_W = 36`, the value reads correctly centred at `KNOB_HOLE_DY = 18` with no nudge, and the
Master Volume hint row is right 4px higher. That settles the conflict above in favour of the
measurement — dy=18 is correct, and the 2026-09-14 in-situ reading that pushed it to 21 was wrong.

`LUA_DEBUG` capture: 503 timer ticks, 0 Lua errors, 0 STANDBY. Two `IDENTIFICATION REJECTED
(reason 00)` at init, recovered by the same-DeviceID retry path — see
`docs/mainstage-integration.md`.

## The config screen (2026-09-20)

A third full display mode, `'config'`, alongside `'list'`/`'zoom'`/`'popup'`: the script version and
the whole CC map, so the mapping can be read off the keyboard instead of these docs. Toggled by the
Global button, scrolled by the joystick ring.

**The button id was unknown and had to be measured.** The spec's button-id table was not vendored in
this repo (it is now - see `docs/implementing-sl-link.md` section 6), so pressing each candidate in
isolation under `Scripts/probe-display.swift` settled which ids arrive: **`0x09`**, `0x0A` and `0x0E`,
all three reaching the host. `docs/full-functionality-plan.md` had `0x09` right all along as the spec's
**Global Button**; only the SL88 MK2's panel disagrees, silk-screening it SETTINGS. The constant was
first named `BID_SETTINGS` off the panel and renamed to `BID_GLOBAL` the same day - see
[Button and LED names aligned with the spec](#button-and-led-names-aligned-with-the-spec-2026-09-20). The same run confirmed the Navigation bitmap group's
icon indices (`0x00`-`0x07` = left, right, left-right, up-down, rotate, push, apply, cancel) — the
first indices verified in any group other than Knob, and exactly the order the spec states. The round
arrow (`0x04`) is the config screen's scroll indicator.

### Layout

Agreed with Jeroen before implementing, per the standing rule for screen changes. He chose the denser
paired form over one row per CC, and required column headers.

| Band | y | Regions |
|:--|:--|:--|
| Title | 4 | `cfgTitle` (`CONFIG`), `cfgVer` (`v2.4.1`, right-aligned) |
| Header | 26 | `cfgHdrName` (`CONTROL`), `cfgHdrCC` (`SHORT  LONG`) |
| Rule | 46 | `cfgRule`, a 1px line |
| Rows | 52, +24 × 7 | `cfg0..6` (name) and `cfgv0..6` (CC pair) |
| Footer | 216 | `cfgIcon` (rotate icon), `cfgFoot` (`1-7/20`) |

**The CC pair is ONE right-aligned draw, not two columns of text.** Every CC is two digits (40-74), so
`'40  41'` right-aligned lands consistently without a fixed-width font, and it halves what a row costs:
2 draws instead of 3, so a page is 21 messages rather than 28. A turn-only control draws `'50   -'` —
the dash holds the SHORT column's digits in place instead of letting a lone number drift right.

`CONFIG_ROWS` is an explicit hand-written list of `{ SHORT key, LONG key }` pairs, 20 rows, so they can
be compared by eye against `CC_MAP`. The displayed **name is not repeated** there: it comes from
`CC_LABEL[short]`, which already reads `'Joy Up'`, `'Zone 1 Push'`, `'Joy Rotate'`. The harness asserts
the table covers every `CC_MAP` key exactly once and names nothing outside it — the guard that makes a
hand-written table safe.

### Three decisions that shape the behaviour

- **The joystick ring emits no CC while this screen shows.** It is normally CC 50 (`JOY_ROTATE`);
  leaving that live would mean every scroll tick also moves whatever MainStage learned to it — editing
  a fader while reading the mapping list. The `IT_ENCODER` branch returns before `queue_relative_cc`,
  and no popup is shown either (it would cover the screen being scrolled). Every other control keeps
  emitting normally.
- **The Global button is not MIDI-mappable.** It is absent from `BUTTON_CC`, so it emits no CC and
  generates no `controller_info()` item — the same treatment Home already had. Asserted for both.
- **Home's SHORT press does nothing in config mode.** One button owns one mode. Left alone, the toggle
  would compute `'zoom'` regardless of what config was covering and discard `configPreviousMode`. LONG
  still forces a full repaint, which works on any screen.

### The traps this touched

- **Three dispatches, all ending in a bare `else` that means "list".** `paint_screen`,
  `update_screen` and `set_display_mode` each needed an explicit `'config'` branch; without one a new
  mode silently paints the patch list. `set_display_mode`'s guard would also have *rejected* `'config'`,
  which would have broken `dismiss_popup`'s restore after a popup over the config screen.
- **`queue_sacrificial_redraw` needed a config branch too.** Its duplicate line is chosen by mode, and
  the `else` draws the list's context bar — over the config screen, that is the same bug as
  [the popup case](#sacrificial-redraw-painted-the-list-line-under-a-popup-2026-09-14).
- **A scroll repaint goes through `update_screen()`, not `paint_config_screen()` directly**, so it
  picks up the trailing sacrificial redraw; without it the last row of every scroll is silently lost.
- A content change from MainStage arriving while config shows needs no special case: the screen's
  content does not depend on patch state, so per-region memoization makes the repaint a no-op.

### Harness

38 assertions, mutation-checked: adding the Global button to `BUTTON_CC`, duplicating or dropping a
`CONFIG_ROWS` entry, letting the ring emit its CC in config mode, and letting Home toggle out of config
each fail the matching assertion. One mutation also exposed a fragile test of my own — with the ring's
scroll branch disabled, the CC path opened a popup, and the leaked `popupActive` changed what the later
Global round-trip assertion proved. That block now sets `popupActive` explicitly rather than
inheriting it.

### Hardware round 1: three changes (2026-09-20)

The config screen, its lamp, the Global toggle and the ring scroll all worked first time - the
capture shows three clean round-trips (from zoom and from list), 100 ring turns, and the
Home-ignored-in-config branch firing. Three things came back from it.

- **The Home lamp must not move when config opens.** It tracks list-vs-zoom only, and config is an
  overlay on one of those, so `flush_mode_led` now resolves `'config'` to `configPreviousMode` before
  deciding the lamp - the same indirection the popup already used for `popupPreviousMode`.
- **The title line is `SIZE_MEDIUM`.** Everything below it shifted down by the extra glyph height
  (23 vs 18) and the row pitch tightened from 24 to 22 to keep 7 rows above the footer. The
  sacrificial duplicate had to follow the size too, or it would repaint the title at the wrong height.
- **No popup over the config screen.** An encoder turn used to open the value popup on top of it,
  which hides the page being read and costs a full Clear-Screen repaint of all 21 config regions to
  restore. Both entry points (`show_popup`, `show_master_volume_popup`) now return early in config
  mode. The CC and the Master Volume write still go out - only the panel is skipped, so nothing about
  what MainStage receives changes.

### A session died with the popup up over config - cause not established

The run ended with the session dead: last timer tick #546, then three more inbound frames and nothing
at all. MainStage itself was still running (~23% CPU, no crash report), so this is the documented
"no tick means no keepalive and the SL88 drops the app" failure rather than a Lua error - there is no
error line in the capture.

What the capture does show: `timerPending` is cleared at the top of every tick and re-armed only from
`controller_midi_in`, and only **3** frames arrived after the last tick - far below
`TIMER_WATCHDOG_FRAMES` (20), so the watchdog could not fire before the keyboard dropped us and the
frames stopped. Once that happens the script has no clock and no inbound events, and cannot recover.

**What is not established** is why the outstanding one-shot never fired. It is not attributable to a
specific line, and two earlier unexplained dropouts with a healthy-looking session clock are already
on record (`docs/mainstage-integration.md`'s open items). Suppressing the popup over config removes
the situation this one appeared in - a 21-message repaint queued behind a popup drain, with
`idleTicks` frozen the whole time because it only advances on a non-draining tick - but that is
removing the trigger, not explaining the mechanism. If a dropout recurs, this is the first place to
look.


## Button and LED names aligned with the spec (2026-09-20)

`BID_SETTINGS`/`WLID_SETTINGS` were named off the SL88 MK2's front panel, which silk-screens three
buttons differently from the spec. Jeroen's rule: the spec's name wins, and it is applied everywhere.

The spec's tables (`sl-link/docs/hardware-io.md`, pinned commit `4c0824d`, now vendored in
`docs/implementing-sl-link.md` section 6) name `0x09` the **Global Button**, `0x0E` the **Apply
Button** and `0x10` the **Home Button**; the panel calls those SETTINGS, CONFIRM and ZOOM. The LED
sweep's by-eye label "CHECK" for `WLID 0x05` was the **Apply** lamp.

Renamed, no behaviour change and no wire bytes touched: `BID_ZOOM`/`WLID_ZOOM` ->
`BID_HOME`/`WLID_HOME`, `BID_SETTINGS`/`WLID_SETTINGS` -> `BID_GLOBAL`/`WLID_GLOBAL`,
`handle_zoom_button` -> `handle_home_button`, `handle_settings_button` -> `handle_global_button`, and
the two lamp memos `modeLedSent`/`configLedSent` -> `homeLedSent`/`globalLedSent` (each is named after
the lamp it drives).

**Display modes deliberately keep their own names.** `'list'`/`'zoom'`/`'config'`/`'popup'`,
`displayMode`, `paint_config_screen` and every `CONFIG_*` constant are screen concepts, not buttons, so
`handle_home_button` toggling `'zoom'` and `handle_global_button` opening `'config'` is correct rather
than inconsistent.

**A claim to retire:** an earlier note today said this repo had `0x09` "wrong" as Global. It did not -
the id was right, and only the name differed from the panel. That error came from naming the constant
off the hardware instead of the spec, which is the whole reason for the rule.

## RGB encoder rings (2026-09-20)

The four zone encoders have RGB ring lamps this script had never touched, and two pieces of data were
already sitting unused that together make them meaningful:

- `controller_midi_out` stored `color` per CC and **nothing read it**. Format, from the 2026-09-17 probe
  capture: a table of r/g/b **floats 0.0-1.0** (`color=1.00/0.90/0.31`).
- `encoder_mute_state(eid)` already worked for **all four** zone encoders - it reads the encoder's PUSH
  CC and reports whether MainStage calls that parameter a Mute and whether it is on. Only the lamp was
  missing: `ENCODER_MUTE_WLID` holds just `EID_B`, because only the B encoder has a white lamp. Zones
  1-4 had the state and no way to show it.

So `flush_encoder_rings()` needs no new feedback plumbing: colour from the turn CC's reported parameter,
mute from the push CC's, drained on the tick and memoized per ring id exactly like `flush_mute_leds`.

### Where the colour actually comes from (answered on hardware 2026-09-20)

**MainStage's knob mapping attributes have a Custom Color, and its default is yellow.** That is the
colour reported to `controller_midi_out` - which is why the first two mappings both lit amber
(`1.00/0.90/0.31`, the same value the September probe captured for a Volume control). It is *not* the
channel strip's colour, and the script does not compute it.

So distinct ring colours are a **setup step in MainStage**, not something the script can infer: set
Custom Color per knob mapping. Confirmed working by Jeroen once he did.

The companion attribute is **Replace Parameter Label**, which supplies the popup's title - the answer to
"three popups all called Volume". One trap found on hardware the same day: ticked with an empty field,
MainStage reports an **empty name**, which would have painted a blank title band. An empty name is now
normalised to nil, keeping the entry so the ring still has its colour while the popup falls back to the
physical encoder's label. That path also crashed the mute-flip branch (`name:lower()` on nil) - caught by
the new assertion before it reached hardware, which is the second time a nilable field from this callback
has needed guarding.

**Semantics, agreed with Jeroen:** the ring shows MainStage's own colour for whatever the knob is mapped
to, and a muted channel goes **fully dark**. A knob mapped to a **volume** also tracks its level in the
ring's *brightness* - the ring dims as the fader comes down and bottoms out dark (added on his request
during the hardware run).

That started out matching the reported name for 'volume', the same idiom `encoder_mute_state()` uses for
'mute'. It was widened to **every** ring the same day, because the name is whatever MainStage's Replace
Parameter Label says: a mapping relabelled from "Bari volume" to "Bari" would have silently stopped
dimming. The rings are driven by encoder TURN mappings, which are always continuous controls, so tracking
the value is right for all of them - at the cost of a Pan going dark at hard left, where its value really
is 0. He chose that over dimming, accepting the trade-off that
muted and unmapped then look identical.

**Going dark when MainStage reports nothing is not optional.** Skipping instead leaves a colour from a
previous concert lit - the same trap `flush_mute_leds` already documents for the mute rings, and the
reason both memos are cleared at login confirmation as well as in `enter_active_session`.

### The one real trap: units

MainStage's colour is floats 0.0-1.0; the wire is 7-bit per channel. The conversion is `floor(c * 127)`,
**not** the halving that an 0-255 source needs (the `rgb7` helper in the spec's own examples). Halving a
float gives 0 for every channel - a dark lamp, no error, nothing in any log. The harness pins 1.0 -> 127,
0.0 -> 0 and a midpoint, and pins the clamp: a value above 127 would have its MSB set, which is illegal
in a MIDI data byte and drops the whole message.

### Brightness tracking forced the rings to coalesce

A volume sweep reports a new value continuously, and each one is a ring change. LED messages carry no
regionId by default, so they **append** - a single fader move would queue dozens of RGB messages ahead of
display traffic and the keepalive, which is the shape rule 6 exists to protect. Each ring therefore
queues under its own regionId (`'ring0'`..`'ring3'`) so successive updates supersede in place, exactly as
the Master Volume write already does with `'mvol'`. The harness pins this: three reported values leave
**one** queued update carrying the latest brightness.

### Harness

21 assertions including a byte-exact golden vector for `msg_rgb_led`. Mutation-checked: halving instead
of scaling, dropping the clamp, dropping the muted branch, leaving a stale colour when feedback is
absent, and no longer clearing the memo at login each fail the matching assertion.

## The ring selects patches: Bank Select + Program Change (2026-09-20)

Bank Select (`CC 0`/`CC 32`) then a Program Change, injected from `controller_midi_in`'s return, selects a
patch exactly. Verified across the bank boundary on 133 patches. Wire detail and the bindings that do not
work: `docs/mainstage-integration.md#the-ring-selects-patches-with-bank-select-and-program-change`.

Why it works where Q1a failed: Q1a closed the `patchselector` **parser** (falsy-return only). MainStage's
generic program-change handling is a different path and does act on injected bytes.

Two earlier implementations were wrong and are gone: a raw patch index (MainStage rescales, so it drifts as
it climbs) and a proportionally scaled absolute CC (correct arithmetic, but 133 patches cannot be addressed
by 128 values, so ~1 click in 26 skipped). The CC they used, 75, was removed - it had never been released.

`ringPatchTarget` counts patches only (`listRows` interleaves set headers) and re-syncs from the active
patch on every `controller_select_patch`, so it never scrolls from a stale position. In config mode the ring
scrolls that screen and injects nothing.

18 assertions including the byte-exact injected sequence and the bank boundary at patch 129.
Mutation-checked: dropping the bank select, sending it after the PC, not wrapping the program into the next
bank, and letting the config-mode guard fall through.

## The ring sends only patch selection (2026-09-21)

Jeroen: "ring should not send cc but pc". Once Bank Select + Program Change worked, the ring's relative CC
(`JOY_ROTATE`, CC 50) had no job left - the patch list is the feedback for a patch change, so neither a CC
nor a popup adds anything, and keeping it on the same gesture was what made MIDI Learn keep capturing the
wrong control during the investigation.

**Removed from every table rather than muted at the emit site**: `CC_MAP`, `CC_LABEL`, `CC_TURN`,
`ENCODER_CC`, `ENCODER_NAME`, `CONFIG_ROWS` and the `controller_info()` items. A CC that exists but never
emits is worse than no CC - it still appears in MainStage's Layout mode and on the config screen, inviting
a mapping that can never fire.

**CC 50 stays unused, like 64.** Renumbering the map to close the gap would shift every CC after it and
break every mapping learned by hand - the one thing the versioning policy calls major on purpose.

The ring now has its own branch in `handle_sl_frame`'s `IT_ENCODER` case, so it no longer falls through to
the generic CC path (which would have logged `(unhandled)` on every tick once its mapping was gone). The
`show_popup` guard stays as belt and braces, with its comment corrected to say so.

**This is a breaking change** - the first in this project - so it is a major bump. The harness asserts the
absence rather than trusting it: no `CC_MAP`/`CC_LABEL`/`CC_TURN` entry, no `ENCODER_CC` wiring, and CC 50
not reassigned to anything else. Mutation-checked by re-adding the ring to `ENCODER_CC`, by pointing
another control at CC 50, and by removing the ring's branch so it falls back to the CC path.

## Browse with the ring, commit with the press (2026-09-21)

The ring moves `cursorIndex` and nothing else; the joystick press injects Bank Select + Program Change for
the browsed patch. Replaces live selection, which loaded every patch scrolled past. Confirmed on hardware,
snap-back included.

- The **cursor is the browse target** - `ringPatchTarget` and its helpers are gone. `cursorIndex` already
  re-syncs from the active patch in `controller_select_patch`, so a commit or an external change keeps it
  in step for free.
- It **steps over set headers**: a header is not selectable, so the cursor never rests on one.
- `browsePending` also arms the ~1s tick (`rearm_timer`), which is what lets `check_browse_revert()` snap
  back after `BROWSE_IDLE_TICKS` rather than a multiple of `KEEPALIVE_MS`.
- The press is **commit-only**: its CC (48/49) went the way of the ring's CC 50. All three are left unused
  rather than reassigned.
- The bottom list row is narrowed (`ROW_LAST_MAXW`) to carve a gutter for the rotate and push icons, since
  with 8 rows there is no space below them. The push icon changes **colour**, not presence, so the region
  never needs erasing.

**The context bar is SIZE_SMALL, not medium.** At medium its 35 characters overflowed the 304px box and the
SL88's Max Width truncation mangled the line to `Jose..` - the same defect `docs/implementing-sl-link.md`
records at `SIZE_BIG`, now seen at medium too. `MEDIUM_MAX_CHARS = 36` is therefore unsafe at this width
and is flagged in the source; `zset` survives only because set names are usually short.

## The joystick tilts select patches (2026-09-21)

The four tilts lost their CCs (40-47) and now select patches directly, through the same
`commit_cursor_patch()` the press uses: up/down step one patch, left/right step to the first patch of the
neighbouring set, long up/down jump to the first/last patch of the concert. Long left/right do what short
does, the project rule for `LONG_PRESSION`. With the press (48/49) and the ring (50) already converted,
CC 40-50 are now all unused gaps - renumbering would break every learned mapping after them, so the CC map
starts at 51 and holds 23 gestures.

- They step from the **cursor**, not the playing patch. That is what makes a fast double-tilt advance two
  patches - the second tilt sees the first one's cursor whether or not MainStage has answered yet - and it
  lets a tilt commit a ring browse in progress.
- A tilt that **cannot move** sends nothing. Re-sending the playing patch's own Program Change would make
  MainStage reload it, which on a live rig cuts the sound.
- Set stepping uses `set_entry_points()`, which lists only sets that actually contain patches, so a
  header-only set is never a stop and the cursor can never land on a header.
- The CC count was already stale in four places (34 stated, 31 actual) before this change; the harness now
  pins it, since the number appears in two source comments, the README and the integration doc's table.

## Tilt icons on both patch screens (2026-09-21)

The tilts were undiscoverable from the keyboard, so both patch screens now carry the navigation group's
up/down (`0x03`) and left/right (`0x02`) bitmaps. Layout agreed with Jeroen before implementing.

- **List screen:** four icons in one band at y=214, 20px wide on a 26px pitch, right edge at 312 -
  `⇕ ⇔ ↻ ⊙` in the order the gestures escalate. Paying for the two new ones cost the bottom row 50px
  (`ROW_LAST_MAXW` 248 -> 198); the seven rows above keep the full width.
- **Zoom screen:** the tilt pair only, level with the `n/N` counter. The counter's box was narrowed
  **symmetrically** about the screen centre (`ZOOM_POS_X` 58, `ZOOM_POS_W` 204) so its digits did not move -
  narrowing from x=8 would have shifted them left, since the device centres within the box.
- The ring and press icons stay **off** the zoom screen: a ring turn there switches to the list before it
  browses, so no browse can ever be pending on that screen.
- Icons are WHITE, not amber - Jeroen's call after seeing the amber version on hardware. Amber therefore
  now marks only the active patch. The push icon keeps its grey/white distinction, the one piece of state
  any icon carries.
- Region ids are per screen (`navUpDown` vs `zNavUpDown`). The same id at two positions would let one
  screen's memoized tuple stand in for the other's; the harness now asserts the two screens share no
  region id at all.

## The item order is a default rig (2026-09-21)

With the SL88 connected, MainStage **automaps** a fresh concert's screen controls from the items
`controller_info()` declares, taking them per type in declaration order: the first `Knob` to Vertical
Fader 1, the next four to Smart Knob 1-4, the first four `Button`s to Button 1-4. The stock templates
wire those buttons to Prev/Next Set and Prev/Next Patch, and map the Smart Knobs to the loaded patch's
Smart Controls - so the assignment is fixed while the parameters follow the patch.

Observed with the previous, accidental order: Button 1-4 took CC 51-54, which were Zone 1 Push, Zone 1
Push **(long)**, Zone 2 Push and Zone 2 Push (long) - so a long press of Zone 1's encoder did "Next Set".
Vertical Fader 1 took Zone 1's encoder, leaving Smart Knob 1-4 driven by zones 2, 3, 4 and B, one off
from the panel labels.

The order is now chosen deliberately, and the harness asserts it: B encoder first among the turns, then
zones 1-4; the four zone selects first among the buttons; every long press last, where the automap
cannot reach it.

The numbers moved with it, to 85-89 and 102-119. The old 51-74 map sat on MainStage's own channel-strip
controller table (`BaseplateMIDIControllers.plist`: Insert #1-16 Bypass 56-71, Send Mute 1-8 72-79) and
on the MIDI spec's switch and sound controllers. 85-90 and 102-119 are free in both. Whether the automap
walks declaration order or ascending CC number was never established - the two agree here, deliberately.
