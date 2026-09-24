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
  `controller_select_patch`, `set_display_mode` and `handle_home_button`** — every `quick-rearm` log
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
  so the cause is not known. Watch for it specifically next run; it has not recurred since. A later,
  different dropout — the display "sometimes drops out while playing" at `FLUSH_SOON_MS = 25`
  (`docs/config-lua-history.md#flush_soon_ms-retuned-to-25-backed-out-2026-08-29`) — is another
  unexplained dropout with a healthy-looking session clock; whether the two share a cause is
  speculation, not established.

## `FLUSH_SOON_MS` sweep: settled at 35 (2026-08-29)

The planned sweep (50 → 35 → 25) is concluded, not paused. 35 is confirmed good on hardware —
255-307 tick runs across 22 patch changes and 10 mode switches, every zoom/list/popup region
rendering correctly with zero Lua errors — and **is the current value**. 25 was tried and backed out:
both 35 and 25 were exercised while playing, and only 25 dropped out, so 25 is below the usable floor
on this hardware; there is no plan to revisit it without a new reason. Full detail and the revert
ladder: `docs/config-lua-history.md#flush_soon_ms-retuned-to-35-2026-08-29` and
`docs/config-lua-history.md#flush_soon_ms-retuned-to-25-backed-out-2026-08-29`.

**The mechanism is still open.** The failure that set the floor was not the one the sweep plan
predicted — it watched for missing regions and stale tails, and every region rendered correctly at
25. The dropout only appeared under note traffic instead, and the captured run can't explain why: the
one STANDBY captured had a healthy session clock right up to the SL88 sending it unprompted, notes
aren't logged, and the log has no timestamps to check whether tick intervals stretched out.

## Zoom centring moved to the device (2026-08-29)

Resolved: zoom centring is no longer computed in Lua from estimated character widths. `zset` and
`zname` now draw at a real, non-zero `maxWidth` with the device's own `ALIGN_CENTER`, exactly as
`znext` and every list row already did —
`docs/config-lua-history.md#zoom-screen-centring-moved-to-the-device-2026-08-29`. `CHAR_WIDTH_BIG`,
`CHAR_WIDTH_MEDIUM` and `estimate_text_width_px()` are gone from the codebase (confirmed by grep), and
so is the erase-rect path manual centring at `maxWidth = 0` needed — a full zoom repaint dropped from
7 queued messages to 5. Confirmed centred on hardware the same day.

Truncation is untouched by this: `truncate_text()` still pre-truncates `zname`/`zset` in Lua before
every draw, because Max Width *truncation* is still confirmed broken at `SIZE_BIG` on the device — a
separate, still-open bug this change does not touch or fix.

## Next stage

There is no committed roadmap document. `full-functionality-plan.md` is marked historical, and its
Phase 2 (CC-mapped navigation/patch selection) shipped long ago — see "Every control emits a mappable
CC" above. Q1a's finding still holds: the patch-selector parser is unreachable from
`controller_midi_in`'s return value, so anything reaching MainStage goes through the CC/MIDI-Learn
route instead.

What's open, drawn from what's already tracked in this file and in `docs/config-lua-history.md`:

- ~~**Master Volume does not work, and the next step is a MIDI proxy**~~ — **RESOLVED 2026-09-10.**
  Master Volume works. The device requires a READ issued alongside the WRITE; a write on its own is
  ignored. The MIDI proxy was never needed. See "Master Volume needs a live login" below and commit
  `f2d9f3e`. Still unexplained: the login-time READ goes unanswered while gesture READs are answered.
- **Two hardware paths remain unproven** (see "Refactor verification" above): Zoom LONG press (the
  force-full-repaint path in `handle_home_button`), and the re-identification wait path
  (`STATE_REIDENTIFY_WAIT`, `handle_identification_rejected`), which needs a deliberate DeviceID
  collision to exercise.
- **Login Recall (`00 06`)** stays blocked on a stored device icon, which is out of scope (see "Open
  issues" above).
- **Most of the SL Link icon library is unused.** Only the Knob group (`GIDX 0x00`) has been drawn, in
  the encoder popup (`docs/config-lua-history.md#the-knob-bitmap-replaces-the-ring-2026-08-29`); Knob
  Center, Toggle, Navigation, Arrow, General and Daw are all confirmed available on hardware
  (`docs/implementing-sl-link.md`) but untried in `config.lua`.

None of these is committed as *the* next stage — this is the open candidate list, not a plan.

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
  incarnation's registration under `0x6D` because **no logout is sent on teardown**. (The original
  reason given here — that `controller_finalize` has no return path — was **wrong**, disproven on
  hardware 2026-09-10: a Logout Request returned from `controller_finalize` reached the device, which
  answered `00 03` LOGOUT CONFIRMATION. It is not sent because doing so logs the app out of the APP
  list on every one of MainStage's spurious teardowns. See `config-lua-history.md`.) The
  keyboard therefore answers `IDENTIFICATION REJECTED (reason 00)`, the script bumps to `0x6E`, and
  re-registers **as a different app**, which is why the user's APP-list selection is lost. A second
  script instance — possible if MainStage loads one per USB-MIDI interface — would compound this by
  also starting at `0x6D`; the one hardware run measured so far ran as a single instance instead (see
  `docs/config-lua-history.md#single-instance-confirmed-on-hardware-2026-08-28`).

  **SHIPPED 2026-09-10** (was "untested fix to try first"): on rejection, **retry the same instance ID
  after a pause of more than 5 s** rather than immediately bumping. The SL88 drops a host that goes silent for ~5 s, so the
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
back/forward — so absolute addressing is no longer required.

**Confirmed working 2026-09-20** (Jeroen): the joystick CCs are mapped in his concert and stepping
works. This supersedes the earlier note here that only "next patch" had been observed and that the
reverse and set steps were unproven.

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

### CC map (43 gestures, two encoder banks)

The four zone encoders, their pushes and the four zone select buttons exist **twice** — bank A is zones
1–4, bank B is zones 5–8 — on one set of physical controls, toggled by the **DAW button** (BID `0x0A`,
confirmed on hardware 2026-09-24) and shown by its lamp (WLID `0x09`). The B encoder, the B push and the
joystick do not bank.

| CC | Gesture | MainStage calls it |
|---:|:--|:--|
| 3, 9 | Zone 1–2 Select | **Solo**, **Mute** |
| 14 | B Encoder | — |
| 15, 20 | Zone 3–4 Select | — |
| 28–31 | Zone 1–4 Encoder | **Send 1–4** |
| 56–59 | Zone 5–8 Encoder | **Insert #1–4 Bypass** |
| 60–63 | Zone 5–8 Select | **Insert #5–8 Bypass** |
| 72–79 | Zone 1–8 Push | **Send Mute 1–8** |
| 80 | B Push | — |
| 102–118 | the 17 long presses | — |

**The numbers land on MainStage's own table deliberately**, the opposite of the earlier map that avoided
it. Those parameters belong to a **channel strip**, so they follow the loaded patch — right for the zone
controls, wrong for anything global, which is why the B encoder is *not* on CC 7 (Volume): it is the
concert's output fader and must not change meaning with the patch.

**CC 0 and CC 32 are reserved.** They are the Bank Select MSB/LSB every patch commit sends, so no
gesture may use one — which is why bank B's encoders take Insert Bypass rather than a run of Sends
broken by 32. The harness asserts it.

### The baseplate

MainStage's own CC→channel-strip table lives in `MainStage.app/Contents/Resources/`:

- `BaseplateMIDIControllers.plist` — Solo 3, Volume 7, Balance 8, Mute 9, Pan 10, Expression 11,
  Send 1–8 at 28–35, Insert #1–16 Bypass at 56–71, Send Mute 1–8 at 72–79.
- `BaseplateMIDIControllersMIDI.plist` — the MIDI-strip variant, only Insert Bypass 56–71.

`MainStageCore` consumes them through `MABaseplateParameterMapping` and
`WsMIDIBaseplateControlsForPort(port, channel, isMIDI)`, so the set is resolved **per port and per
channel**. Whether it engages for the LINK port is not yet established — see
`docs/config-lua-history.md` for the hardware result.

### Automap

With the SL88 connected, MainStage **assigns a fresh concert's screen controls by itself** from the items
`controller_info()` declares. It takes them per type, in declaration order:

| Screen control | Gets | Which is |
|:--|:--|:--|
| Vertical Fader 1 | the first `Knob` | B Encoder |
| Smart Knob 1–4 | the next four `Knob`s | Zone 1–4 Encoder |
| Smart Knob 5–8 | the next four after those | Zone 5–8 Encoder (bank B) |
| Button 1–4 | the first four `Button`s | Zone 1–4 Select |

The stock templates wire Button 1–4 to Prev Set, Next Set, Prev Patch, Next Patch, and map Smart Knob
1–4 to whatever the loaded patch's Smart Controls are — so the assignments are fixed while the parameters
follow the patch.

**The declaration order is therefore a default rig, not a formality.** It is ordered deliberately: the B
encoder first among the turns so it lands on the output fader, then zones 1–4 for Smart Knob 1–4, the
four zone selects first among the buttons, and every long press last so the automap can never consume
one. Observed before that ordering (2026-09-21): a *long* press of Zone 1's encoder did "Next Set",
because CC 52 happened to be next in line.

### The ring browses, the press selects with Bank Select and Program Change

The ring moves the list cursor locally; the joystick press injects the selection for the browsed patch.
Confirmed on hardware: the injection itself 2026-09-20 (174 ring steps, 173 patch changes, 13 in bank 1 -
exact, no scaling, no skipped patches, no 128 ceiling), and browse/commit with its snap-back 2026-09-21.

Browsing rather than selecting live is what stops MainStage loading every patch scrolled past. An
uncommitted browse reverts to the playing patch after `BROWSE_IDLE_TICKS`.

The four **tilts** select in one gesture instead, via the same `commit_cursor_patch()`: up/down step a
patch, left/right step to the first patch of the neighbouring set, and long up/down jump to the first/last
patch of the concert (long left/right do what short does). They step from the CURSOR, not the playing
patch, so a fast double-tilt advances two patches even before MainStage answers the first, and a tilt can
continue a ring browse. A tilt that cannot move sends nothing rather than re-triggering the playing patch.

Per ring step on `CC_CHANNEL` (16): `CC 0` (Bank MSB), `CC 32` (Bank LSB), then the Program Change. Bank is
`floor((p-1) / 128)`, 0-based on the wire (MainStage displays bank 1 upward); program is `(p-1) % 128`.

**MainStage counts program changes from 1, MIDI counts from 0** — so patch 1 is wire value 0, and every
`-1` in the arithmetic above is that conversion. MainStage's *Program Change Range* setting (0–127 vs
1–128) only changes the numbers it displays, not the bytes, so the conversion holds either way.
Bank must precede the PC. This reaches MainStage's **generic** program-change handling; the `patchselector`
parser stays unreachable from an injected return (Q1a) and uses no PC anyway.

Setup: the patches need program change numbers (Patch List → reset program change numbers). *Program
Changes Device* and *Program Changes Channel* in Concert Settings are plausible gates but were never
isolated - see README.

The ring emits nothing else. Its old relative CC 50 was removed in v3.0.0 and left unused rather than
reassigned; renumbering would break every mapping after it.

### Routes that do not work

Tried on hardware 2026-09-20:

| Attempt | Outcome |
|:---|:---|
| Ring → patch list widget | cannot bind |
| Ring → Next Patch action | both directions step forward |
| Ring → Jump to Patch action | fires once, then ignores value changes |
| Ring → *current patch number*, `Relative2C` | not decoded; `0x01` and `0x7F` land at the same end |
| Ring → *current patch number*, absolute CC | works, but MainStage rescales 0-127 onto the patch range, so ~1 click in 26 skips |

**Trap:** an assignment's value range can collapse to 0/127, squashing every value to an extreme. That made
four bindings look dead, two of which work. Check the range before concluding anything.

### Two MainStage mapping attributes drive what the SL88 shows

Everything the screen and the rings know about a mapping comes from `controller_midi_out`'s
`name`/`valueString`/`color`, and two attributes on the **knob mapping** in MainStage decide what
arrives. Both are setup steps the script cannot infer. Confirmed on hardware 2026-09-20:

| Attribute | Effect on the SL88 |
|:---|:---|
| **Custom Color** (default **yellow**) | colours that encoder's RGB ring. Every ring reads amber until this is set per knob |
| **Replace Parameter Label** | becomes the popup's title. Without it MainStage sends the raw parameter name, so three mapped volumes all read "Volume"; name them and the popups become distinct |

**Watch the checkbox-with-empty-field case:** "Replace Parameter Label" ticked but left blank makes
MainStage report an **empty** name. The script treats that as no name — the popup falls back to the
physical encoder's own label and CC, and the ring keeps its colour — rather than painting a blank title.

A ring is dark when the channel is muted or nothing is mapped; a knob mapped to a volume also dims with
its level.

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

### Encoders send relative deltas (changed 2026-09-05)

The six `CC_TURN` encoders (`ENC1-4_TURN`, `ENCB_TURN`, `JOY_ROTATE`) emit each tick's signed delta
rather than the tracked absolute position, using MainStage's `Relative2C` (two's complement, 7-bit)
`midiType`: `+1` on the wire as `0x01`, `-1` as `0x7F`, clamped to `-63..63` then `% 128`-encoded.
`encoderValue` is still tracked internally 0–127 — the encoder value popup's ring gauge reads it —
only what's *emitted* changed.

**Confirmed on hardware (2026-09-05)**: the `Relative2C` byte encoding above was verified by
remapping the B encoder to a relative control in MainStage 4.3.1 against a real SL88 MK2 - smooth
bidirectional movement, confirming the two's-complement encoding rather than merely inferring it
from the name.

**Fixed 2026-09-05**: `queue_cc`'s per-control coalescing (see "Momentary buttons" above) replaces
rather than sums a pending value — harmless for the old absolute encoding, but a relative delta needs
two ticks for the same control before a flush to SUM rather than lose the first tick's motion.
`queue_relative_cc`/`flush_pending_cc` now accumulate the delta in signed `pendingDelta` and only
clamp/encode it at emit time; `queue_cc`/`pendingCC` are unchanged and still used for every absolute
control. See `Tests/lua/harness.lua`'s "Relative CC coalescing" checks.

`JOY_ROTATE` (CC 50) goes through the same `handle_sl_frame` encoder branch and now joins `CC_TURN`:
`controller_info()` declares it `objectType='Knob'`, `midiType='Relative2C'`, matching the other five
turn gestures instead of the stale `Button`/`Momentary` it kept when this file's encoding first
changed.

### Stick layout corrected (confirmed by Jeroen, 2026-09-05)

**Confirmed:** the SL88 has two physical sticks. Stick 1 is an XY stick whose X axis is pitch bend by
default. Stick 2 is the modulation stick. The previous `controller_info()` item names had modulation
and "Stick 2" transposed — guessed from captured CC numbers without knowing which physical stick
produced them. Renamed, wire bytes unchanged: `0xE0` (pitch bend) is now `Stick 1 X`, `0xB0,0x01`
(CC 1) is now `Stick 2 Mod`, `0xB0,0x10` (CC 16) is now `Stick 1 Y`.

**Confirmed on hardware (2026-09-05):** that CC 16 specifically carries Stick 1's Y axis, verified
in MainStage's MIDI Message Monitor by moving Stick 1 vertically and observing CC 16 move.

### Status: Confirmed on hardware (2026-08-22)

Deployed and tested against the SL88 with a real concert loaded. MainStage's MIDI Learn does accept a CC arriving by injection — Selector 1 (CC 67) was learned and responded on the first attempt, confirming the one assumption the whole design rested on. The `[sllink] CC batch: N CC(s), B bytes` log line confirms each injection round on the script side.

Not yet mapped, by choice — left for a later phase: Apply and DAW (the panel labels Apply CONFIRM).
Cancel drives logout. Home and Global have their own on-keyboard function instead — the list/zoom
toggle and the config screen — and neither is MIDI-mappable, which the harness asserts by checking both
stay out of `BUTTON_CC`. Spec names throughout; the panel silk-screens Home as ZOOM and Global as
SETTINGS (see `docs/implementing-sl-link.md` section 6).

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
- **Home button** (panel: ZOOM) — 4 SHORT presses, toggling list<->zoom in both directions (2 each way).
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

- **Home LONG press** (the force-full-repaint path in `handle_home_button`).

**The re-identification wait path is no longer unproven (2026-09-20).** It fired unprompted on an
ordinary relaunch: one instance was rejected twice with reason `00`, retried on the *same* DeviceID
both times per `MAX_SAME_ID_RETRIES`, and was approved on the third request — so
`STATE_REIDENTIFY_WAIT` and the retry budget work on hardware. The instance **bump** past those
retries is still unproven, since it never had to run.

## `action_<app>` spike: verified inert (2026-09-05)

Tested whether `controller_info()` items' undocumented `action_<app>`/`action` fields could invoke a
MainStage command (`NextPatch`/`PreviousPatch`/etc.) directly, bypassing MIDI entirely. If it had
worked, it would have removed the one-time MIDI-Learn per concert that "Every control emits a
mappable CC" (above) currently requires, and given a relative patch/set-navigation primitive for
free.

**Result: inert on every reachable path** — six configurations tried (script-injected CCs on two
channels, and two genuine hardware CCs with `controller_midi_in` returning `nil`), none fired the
bound command. Byte-level detail, the full evidence table and the Logic-Pro caveat live in
[`mainstage-device-scripts.md`](mainstage-device-scripts.md#2-controller_info--the-items-table) §2 —
not repeated here.

What this means for this project: `action_<app>` is not a route to patch navigation. The CC map plus
one-time MIDI-Learn per concert ("Every control emits a mappable CC", above) remains the only working
mechanism. The parked `feature/joystick-browse` branch's relative-commit idea is unaffected — it
already builds on the CC/assignment-layer route from "Round 5" above and never depended on
`action_<app>`.

This spike is also a concrete instance of this project's standing rule to prove a signal is
observable before trusting a negative result (see the three-findings list at the top of this file for
the pattern). Its first round produced a false negative: the gesture performed emitted a different CC
than the item under test was bound to, and nothing in the log showed the mismatch, so the "no command
fired" result was uninterpretable. Adding a log line that prints the CC numbers in each batch
(`[sllink] CC batch: 1 CC(s) [74=127], 3 bytes`) closed that gap and made the second round's negative
trustworthy.

## Logout, Master Volume and login findings (2026-09-05)

Hardware: MainStage 4.3.1, SL88 MK2 firmware 1.1.2.

**1. Cancel button logs out — but only by withholding the keepalive.** BID `0x0F` is Cancel,
confirmed (frames `01 0F 01` short, `01 0F 02` long). A host-initiated System Logout Request (`00 02`)
is sent correctly — byte-identical to the archived Swift implementation's `systemLogoutRequest` — and
the SL88 **never replies with a Logout Confirmation** and does not leave the app. What actually works
is going silent: the upstream spec says the keepalive must be sent more often than once per 5 seconds
or the SL88 drops the app from the APP list. `STATE_LOGGED_OUT` withholds the Device Notification for
`LOGOUT_SILENT_TICKS` ticks while still emitting the Identification Query (which keeps the one-shot
session clock alive, per rule 6). Measured: **short press ~9s to drop, long press (force, no request
sent) slightly less.** Both then re-identify and the app returns to the APP list.

Note the timing trap found and fixed before this worked: `rearm_timer()` picks the tick interval
dynamically (`FLUSH_SOON_MS` 35ms while draining, `POPUP_TICK_MS` 1000ms during a popup), so a tick
*count* is not a duration. `STATE_LOGGED_OUT` now pins `KEEPALIVE_MS`, `request_quick_rearm()` refuses
to shorten while logged out, and logout dismisses the popup and drops queued display first. Without
all three, three ticks could be ~105ms and the keyboard never drops the app.

**2. Master Volume (ItemType `0x07`) does not work on this hardware — unresolved.** Encoder A drives
it in the script and the popup updates correctly, but the keyboard's own volume never changes. The
outbound bytes are exactly right; logged verbatim:
`[sllink] -> MASTER VOLUME WRITE: F0 00 20 1A 16 03 6D 07 01 64 00 F7`
(`07` item type, `01` = write, `64` = 100%, `00` = unmuted). 129 such writes in one session, no
effect. Reads (`07 00`) get no reply either. Cross-checked against the upstream spec
(`fatarsrl/sl-link` `docs/hardware-io.md` at `4c0824d`), which confirms this exact layout — R/W=1
writes, VOL 0-100 as a percentage, MUTE optional — and documents **no preconditions** about login or
app state. The archived Swift app never implemented Master Volume, so there is no reference to
compare against. This is unexplained; remaining hypotheses are that the SL88 MK2 does not implement
`0x07` despite the spec, or that it applies only when the USB audio board is actually in use. Neither
is asserted as fact.

**3. `handle_login()` frequently never runs — anything hung off it is unreliable.** A 20-tick session
showed `state=active` throughout with zero login lines. The SL88 remembers the host across runs and
then sends neither Identification Approved nor Login Confirmation; the session reaches ACTIVE via the
Identification-Query reply path instead. `state = STATE_ACTIVE` is assigned in three places and only
`handle_login()` queued the Master Volume read, so the read never went out. General hazard:
session-entry work belongs on every transition into ACTIVE, not on the login message.

**4. Encoder A does reach the host** — 162 EID `0x05` frames in one session, confirming
`docs/implementing-sl-link.md` §7's existing note against the spec's "reserved" claim. Earlier
captures showing zero were simply sessions where A was not turned; the note needed no correction.

**5. Incidental:** `MIDI_CtrChange` is the number `176` (`0xB0`), so Arturia's `MIDI_CtrChange` and
our `0xB0 + CC_CHANNEL` with channel 0 are the identical value.

**Still open:** encoder pickup of mapped parameter values via `controller_midi_out(midiEvent, name,
valueString, color)` is designed but not implemented — it is the route to Q3/Q6 in
`docs/full-functionality-plan.md` and to a popup showing the real parameter name and value.

## Master Volume: upstream issue filed, Numa Player capture (2026-09-06)

**Filed upstream: <https://github.com/fatarsrl/sl-link/issues/2>** — the authoritative answer is
expected there.

**Key evidence — Numa Player capture**, `/tmp/numa-sniff-keep.log` (in `/tmp`, will not survive a
reboot). Sniffing CoreMIDI sources while Studiologic's own Numa Player drove the volume: each
encoder-A tick is followed ~3ms later by `F0 00 20 1A 16 7E 60 07 00 <VOL> <MUTE> F7`, VOL stepping
with the knob — 81 ticks, 81 volume reports. Under identical conditions with our script active: 133
encoder-A ticks, **zero** `0x07` frames. This was read as a spec disagreement — the device's own traffic
uses `R/W = 00` *with* a VOL payload, where `docs/hardware-io.md` describes `R/W = 0` as a read with
VOL omitted. **That conclusion was wrong; see "Master Volume: answered upstream" below.** The frame is
the hardware's read *reply*, and only half the exchange was visible to a source-only sniffer.

**Ruled out today, each on hardware:** audio board missing (`SL AUDIO` exists as a Core Audio
device); audio board not in use (routing MainStage's output through it changed nothing); host
identity (`SL_HOST_ID = 0x7E`, matching Numa Player, produced neither volume reports nor logout
confirmations — reverted); message shape (`07 01 <vol> <mute>`, `07 01 <vol>`, `07 00 <vol> <mute>`
all ignored, 100+ sends each).

**Still unexamined, and the only route left:** Numa Player's *outbound* bytes.
`Scripts/sniff-all-sl-ports.swift` watches CoreMIDI **sources** only and structurally cannot see a
host→device send. Seeing them needs a MIDI proxy (a virtual destination Numa Player is pointed at,
logged and forwarded to the real `LINK`) or Snoize MIDI Monitor's spy driver.

**A real bug found and fixed along the way:** `handle_login()` frequently never runs — the SL88
remembers the host across runs and sends neither Approved nor Login Confirmation, so the session
reaches ACTIVE via the Identification-Query reply path instead. `enter_active_session()` now does the
session-entry work on every transition into ACTIVE. Before this fix the Master Volume read had never
once been sent.

**Current code state:** `msg_master_volume_write` now emits `07 00 <vol> 00` (mirroring the device's
observed format), not the spec's `07 01`. **Neither form works.** Left as-is pending the issue —
noted here so the current form is not mistaken for known-good. *(Superseded — see the next section.)*

## Master Volume: answered upstream (2026-09-08)

Andrea (FSL, hardware side) answered <https://github.com/fatarsrl/sl-link/issues/2>. The protocol
consequences are folded into `docs/implementing-sl-link.md` §6 and §7; what belongs here is what it
says about *our* investigation, including the parts of it that were wrong.

**The capture was read backwards.** `07 00 <VOL> <MUTE>` arriving from the keyboard is a **read
reply**, not a write — the hardware must answer a read request with the payload present. Numa Player's
sequence is read request → this reply → `07 01 <VOL>` write; our sniffer watches CoreMIDI *sources*
only, so it recorded the middle message of three and we mistook it for the whole exchange. There was
never a spec disagreement here. The general lesson is the one already on file as
`verify-observability-before-negatives`: a half-visible channel produces confident, wrong readings, and
"the device's own traffic uses this format" is only trustworthy when both directions are visible.

**`R/W = 0x00` is why the current code does nothing.** The firmware discards every byte past the R/W
byte when it is `0x00`, so `07 00 <vol> 00` is a read request with junk attached, not a write. Mirroring
the device was the wrong instinct: the two directions are not symmetric.

**The keyboard does not own the volume — the host does.** Turning A produces an encoder message and
nothing else; the audio board's volume only moves because a host writes it. That retires the standing
puzzle in `docs/implementing-sl-link.md` §7 about A arriving "with no accompanying volume traffic":
there was never supposed to be any.

**The remaining suspect for `07 01` also being ignored is login state.** The precondition Andrea states
is identified + keeping alive + **logged in**, where logged in specifically means a System Login
Confirmation was received. Finding 3 in the 2026-09-05 section above records that `handle_login()`
frequently never runs — the SL88 remembers the host across runs and sends neither Approved nor Login
Confirmation, and the session reaches ACTIVE through the Identification-Query reply path instead.
`enter_active_session()` makes our *own* state machine reach ACTIVE either way, but it cannot make the
keyboard consider us logged in. So the `07 01` attempts recorded on 2026-09-06 may have been sent in a
state where the firmware was entitled to ignore them.

**The read is the observability probe.** The hardware *must* answer `07 00` with a payload. So a run
that sends the read and gets no `0x07` back is positive evidence that the session is not logged in —
which is a far better signal than "the volume did not change". Check for the read reply first; only
if it arrives is a silent write a real write bug.

**DeviceID nomenclature is retired, and `examples/` is stale on it.** Bytes 5 and 6 together are the
DeviceID, regenerated per session; `HostID`/`InstanceID` is old documentation. Andrea confirmed the
reference JUCE plugins still use the old static mechanics and are therefore not a reference for
identification — one for `revalidate-findings-against-reference-implementations`. The hardware cannot
distinguish a random DeviceID from a fixed one (it is only anti-collision), so `SL_HOST_ID = 0x03` plus
an in-script instance byte stays valid and needs no change.

**Still owed upstream:** Andrea asked whether the documentation reads as misleading on DeviceID and on
host/device-vs-hardware nomenclature, and offered to look at a full SysEx capture.

## Master Volume: the login-state hypothesis is retired (2026-09-10) — WRONG, SEE CORRECTION BELOW

> **This section's conclusion was later disproved on the same day.** Login *is* required for Master
> Volume; see "Master Volume needs a live login — earlier retirement was wrong (2026-09-10)" at the end
> of this file. The run recorded below did hold a Login Confirmation and still failed, which remains
> unexplained and is now attributed to MainStage's two script instances holding different DeviceIDs.
> The rest of this section's observations stand; only its verdict does not.

Andrea's answer left one suspect standing — that the `07 01` writes had been sent while the keyboard
did not consider us logged in. Tested directly today. **It was not the cause.**

**A real bug was in the way first.** `enter_active_session()` early-returned when already ACTIVE, and
on hardware the session reaches ACTIVE via the Identification-Query self-heal path *before* the user
selects the app. So the volume READ only ever went out in the un-logged-in state, and a later genuine
Login Confirmation could not re-send it. Fixed: `queue_master_volume_read()` is factored out, and
`handle_login()` — which runs only on a real login frame — forces a read when the self-heal path had
already promoted the session. Harness test 35 asserts both halves (a genuine login queues exactly one
read; a self-heal reaffirmation queues none) and was mutation-tested in both directions.

**The run, with the fix in place.** All of Andrea's stated preconditions held simultaneously and were
each visible in the log: identified (`03 6D`), keepalive running (one Identification Query per tick,
replies arriving), and genuinely logged in — `F0 00 20 1A 16 03 6D 00 01 F7`, a System Login
Confirmation, at which point `handle_login()` ran and queued the read:

```
<- SYSEX on port=LINK: F0 00 20 1A 16 03 6D 00 01 F7
<- LOGIN - session active
-> MASTER VOLUME READ: F0 00 20 1A 16 03 6D 07 00 F7
```

The queue drained to 0, and across 20+ subsequent inbound frames **no `0x07` frame arrived**. In an
earlier phase of the same run, ~15 well-formed `07 01 <vol>` writes went out in the logged-in state
(`07 01 1B` down to `07 01 0D`) and Jeroen confirmed the output level did not move.

**The observation path is sound this time** — the standing worry from
`verify-observability-before-negatives`. Inbound SL Link frames are demonstrably visible: the login
confirmation and every Identification-Query reply were logged through the same path a `07` reply would
take. The one residual gap is outbound: `FLUSH` lines record byte counts, not bytes, and the 10-byte
read is indistinguishable from the 10-byte keepalive, so "the read was sent" rests on queue-depth
accounting rather than on seeing those bytes leave.

**Ruled out today, on hardware:** login state (above); audio board missing or idle — `SL AUDIO`
(STUDIOLOGIC) is present in Core Audio *and* is MainStage's configured output with speakers confirmed
working, so a working write would have been audible.

**What the Numa capture means now.** Re-read against Andrea's answer, the 2026-09-06 capture says more
than it first appeared: 81 encoder-A ticks each produced a `07 00 <VOL> <MUTE>` reply ~3ms later. If
that frame is a read *reply*, then Numa Player issues a **read on every tick** and writes afterwards —
read-modify-write per tick, not a host that owns the value and pushes it. Jeroen independently proposed
exactly this. It cannot be built here yet: it depends on the read being answered, which is the thing
that does not happen.

**The only route left is unchanged, and now it is the whole task:** capture Numa Player's *outbound*
bytes. `sniff-all-sl-ports.swift` watches CoreMIDI sources and structurally cannot see a host→device
send, so this needs a MIDI proxy — a virtual destination Numa Player is pointed at, which logs and
forwards to the real `LINK` — or Snoize MIDI Monitor's spy driver. Every hypothesis reachable from our
own side has now been tested and eliminated; what distinguishes Numa Player's session from ours is
visible only in what it sends.

**Owed upstream:** today's result is new information for
<https://github.com/fatarsrl/sl-link/issues/2> — a read issued with a confirmed Login Confirmation in
hand still goes unanswered. Andrea offered to look at a full SysEx capture; the proxy above would
produce one.

## Master Volume works on hardware — from a standalone probe (2026-09-10)

`Scripts/probe-mastervolume.swift` drives its own SL Link session with no MainStage involved, and
**Master Volume works completely**: reads answered 6/6, and `07 01 <vol>` writes at 20, 60, 90 and 45
each confirmed by a read-back returning exactly that value. The `07 00 <vol>` shape correctly did
*not* write (value unchanged) — it is only ever a reply, as Andrea said. A Login Confirmation was
received during the run.

**So the message form `config.lua` already sends is correct**, and the device honours it. Everything
previously concluded about Master Volume being rejected was measurement error.

**The probe's first run lied, and the lesson is the familiar one.** CoreMIDI delivered every SL Link
frame **split across two packets** (`F0 00 20 1A 16 03` then `2B 07 00 3C 00 F7`). The probe decoded
whole packets only, so both halves failed the header check, every frame logged as "not an SL Link
frame", the `0x07` capture never matched, and the Login Confirmation detector never fired — producing
a verdict table reading 0/11 replies and "logged in: no" when the device had in fact answered every
read with the right value and the user had selected the app. The raw RX lines contained the answer the
whole time. Fixed by buffering from `0xF0` to `0xF7` across packets before decoding. This is
`verify-observability-before-negatives` a third time: the negative was in the decoder, not on the wire.

**What is now unexplained is narrower and sharper:** the probe and `config.lua` send the same Master
Volume bytes over an identically-shaped session, and only the probe is answered. Differences checked
and eliminated: message shape (identical), login state (both logged in), keepalive type (`config.lua`
sends the same `00 00` System Device Notification, line 2114, not only the Identification Query).

**Leading hypothesis: the read never actually leaves MainStage.** The device answers a read in ~2ms,
6/6, so a sent read that drew no reply is hard to credit. `config.lua`'s evidence that it was sent is
only queue-depth accounting — `FLUSH` lines log byte *counts*, and the 10-byte read is
indistinguishable from the 10-byte keepalive. **Next experiment:** log the actual bytes of protocol
messages at flush time, run MainStage, and see whether `07 00` appears on the wire at all.




## Master Volume needs a live login — earlier retirement was wrong (2026-09-10)

Established with `Scripts/probe-mastervolume.swift` and, critically, a control run. Supersedes the
verdict of "the login-state hypothesis is retired" above.

**The result.** With the probe selected on the SL88's APP list, so a real System Login Confirmation
arrives: reads answered 6/6, writes confirmed by read-back 4/4, negative control PASS. Run again with
no selection and after a Logout Request has cleared the previous one: 0/6 and 0/4. The maintainer's
stated precondition was correct.

**How the wrong conclusion was reached, and it is worth remembering.** A probe run that reported
"logged in: no" got 6/6 anyway, which looked like proof that login was irrelevant. It was not: that run
reused DeviceID `6D` seconds after a run that *had* been logged in, so the keyboard still held `6D` as
its selected app. The probe's own login detector, which only watches for a `00 01` frame during that
run, could not see an inherited selection. **The state was carried between runs, and nothing reset it.**
Four hypotheses were killed by controls today — bundled Identification Query, DeviceID contention, app
name, and a supposed cooldown — and this one was very nearly *accepted* for want of one.

Practical rule for anyone testing Master Volume: a run is only meaningful if the probe was explicitly
selected on the keyboard during that run, or was deliberately not selected AND the previous run's
selection was cleared. Rapid successive runs on the same DeviceID inherit state.

**What remains unexplained.** MainStage's own session received a genuine `<- LOGIN - session active`
and its Master Volume reads still went unanswered. So login is necessary but does not by itself account
for the MainStage failure. Prime suspect: MainStage loads the script once per matched USB-MIDI
interface, and with the identification fix in place those instances now take *different* DeviceIDs —
`03 6D` and `03 6E` were both live and visible to the probe in the same run. Both register under the
name "MainStage", but only one can be the entry the user actually selects, so A-encoder writes issued by
the unselected instance would be ignored exactly as observed, while the selected instance's healthy
login appears in the same shared stdout and makes the session look fine.

**Next check:** whether the SL88's APP list shows two "MainStage" entries, and whether selecting the
other one makes the A encoder work.
