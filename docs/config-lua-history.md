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

---

## Identification and instance-ID collisions

MainStage tears the script down and re-initialises it repeatedly (observed: init → finalize → init →
... within seconds, partly because the script is loaded once per matched USB-MIDI interface). A
MainStage-driven re-init resets `instanceID` back to `SL_INSTANCE_START` — but the SL88 still holds the
*previous* incarnation's registration under that same id, because `controller_finalize` has no return
path with which to send a Logout Request (see
[`controller_finalize` sends no Logout Request](#controller_finalize-sends-no-logout-request)).

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

An earlier version of `controller_finalize` sent a Logout Request. Because MainStage tears the script
down and re-initialises it repeatedly, every one of those spurious teardowns actively removed the app
from the SL88's APP list — guaranteeing the "showed up briefly, then disappeared" symptom on its own,
independent of the timer bugs above. Staying quiet lets the APP-list entry survive a churn; if the
script really is going away for good, the keyboard's own ~5s keepalive timeout removes it anyway.

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
