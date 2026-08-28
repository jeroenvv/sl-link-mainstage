-- SL MainStage - MainStage MIDI Device Script for the Studiologic SL88 MK2
--
-- Speaks SL Link directly from Lua, with no helper application: identifies to the keyboard, holds
-- the session alive, and draws the current MainStage patch on the SL88's screen.
--
-- Background is in docs/, not here:
--   docs/mainstage-device-scripts.md  writing MainStage Lua device scripts
--   docs/implementing-sl-link.md      the SL Link protocol, and where hardware
--                                     disagrees with the published spec
--   docs/mainstage-integration.md     status, and the historical record
--   docs/config-lua-history.md        the reasoning behind THIS file's display
--                                     pacing / session clock / flush constraints
-- SL-Link-Mainstage/SLLink/ is the Swift implementation every byte here is checked against.
--
-- MainStage's Lua sandbox has NO `io` and NO `os` - no file access, no clock, no environment. Never
-- add a call to either; it errors immediately (`attempt to index global 'io'`/`'os'`), and there is
-- no way to catch it usefully at load time. (Tests/lua/harness.lua, which drives this file with
-- plain `lua`, is the one place `os` is legitimate - it is not part of the MainStage sandbox this
-- file itself runs in.)
--
-- =========================================================================
-- SIX RULES YOU MUST NOT BREAK. Each was found the hard way; each fails
-- SILENTLY, which is why they are repeated here rather than left in docs.
--
--  1. outport is the SHORT kMIDIPropertyName ('LINK'), never the display
--     name ('SL LINK'). Wrong name = every message discarded, no error.
--     MainStage reports the right one as controller_midi_in's portName.
--  2. One message per flush, <= FLUSH_BUDGET bytes. Over MainStage's ceiling
--     (~78-87) the ENTIRE returned array is dropped, not just the overflow.
--  3. Never send Clear Screen INSIDE AN ORDINARY REPAINT. It used to race
--     with the draws that follow it and lose a line - a different one each
--     run - but that was the display-pacing bug displayFlushReady fixed (see
--     its declaration), not a property of Clear Screen itself. Write Text
--     overwrites the pixels it covers, so redrawing is self-cleaning, which
--     is still why ordinary repaints never need one. The one deliberate
--     exception is set_display_mode's mode switch (see that function's
--     comment) - queued alone, never bundled with a Write Text, paired with
--     its own settle guard. See docs/config-lua-history.md#the-clear-screen-ban-and-its-lift.
--  4. Never truncate strings. Max Width truncates visually in pixels and
--     appends '...' itself.
--  5. Display messages must be paced to at most ONE per timer tick. The
--     Identification Query's reply is itself an inbound SL frame, so an
--     ungated flush_pending() re-enters controller_midi_in and drains the
--     whole queue at the ~2ms round-trip rate instead of the timer's rate -
--     FLUSH_SOON_MS looks like it paces this but does not. The SL88 silently
--     drops a display message that arrives while it is still painting the
--     previous one. See displayFlushReady.
--  6. Never call settriggertimer unconditionally from a handler that runs on
--     EVERY inbound MIDI event. controller_midi_in calls rearm_timer() for
--     every note on/off, not just SL frames, and settriggertimer is a
--     ONE-SHOT: each call cancels and restarts whatever is already pending.
--     While the user plays, notes arrive far faster than the timer period,
--     so an ungated rearm_timer() pushes the deadline back forever and
--     controller_timer_trigger NEVER FIRES - no tick means no keepalive,
--     and the SL88 drops a host that goes quiet for ~5s, deselecting it and
--     discarding its draws. This is why the display dropped out WHILE
--     PLAYING and recovered once playing stopped. Fails completely
--     silently - nothing errors, nothing logs, the app just vanishes from
--     the APP list - which is why it is called out here rather than left to
--     be rediscovered. Fix: gate every settriggertimer call behind a
--     `timerPending` flag so only the first call arms it; the one-shot
--     firing (controller_timer_trigger) is what clears the flag again. See
--     rearm_timer() and timerPending's declaration.
-- =========================================================================

-- MARK: - Protocol constants (mirror SLLinkProtocol.swift exactly)

SL_PORT = 'LINK' -- see the banner above; NOT 'SL LINK'

SL_HEADER = { 0xF0, 0x00, 0x20, 0x1A, 0x16 }
SL_END = 0xF7

SL_HOST_ID = 0x03 -- SLLinkHeader.defaultHostID
SL_INSTANCE_START = 0x6D -- first instance byte tried; bumped on rejection

-- Item types
IT_SYSTEM = 0x00
IT_BUTTON = 0x01 -- handled for BID_ZOOM (see handle_zoom_button) and every BID in BUTTON_CC; other BIDs are logged only
IT_ENCODER = 0x03 -- handled for every EID in ENCODER_CC; other EIDs (just A) are logged only
IT_DISPLAY = 0x04
IT_IDENTIFICATION = 0x7F

-- Button IDs, matching SLButtonID in SLLinkProtocol.swift (verified against that file, not
-- re-derived here - see docs/implementing-sl-link.md).
BID_ZOOM = 0x10 -- confirmed on hardware; toggles set_display_mode('list'/'zoom')
BID_JOY_UP = 0x11
BID_JOY_LEFT = 0x12
BID_JOY_DOWN = 0x13
BID_JOY_RIGHT = 0x14
BID_JOY_MAIN = 0x15
BID_ZONE1_SEL = 0x04 -- SLButtonID.zone1SelectButton .. zone4SelectButton
BID_ZONE2_SEL = 0x05
BID_ZONE3_SEL = 0x06
BID_ZONE4_SEL = 0x07
BID_ZONE1_ENC = 0x00 -- SLButtonID.zone1EncoderButton .. zone4EncoderButton (the zone
BID_ZONE2_ENC = 0x01 -- encoders' PUSH buttons - a different namespace from the EID_ZONE*
BID_ZONE3_ENC = 0x02 -- rotation IDs below, which share the same 0x00-0x03 numbering
BID_ZONE4_ENC = 0x03 -- under a different itemType (IT_BUTTON vs IT_ENCODER)
BID_B_ENC = 0x0C -- SLButtonID.bEncoderButton

-- Button press-event byte, e[9] of an IT_BUTTON frame
PRESS_SHORT = 0x01
PRESS_LONG = 0x02

-- Encoder IDs, matching SLEncoderID in SLLinkProtocol.swift.
EID_ZONE1 = 0x00
EID_ZONE2 = 0x01
EID_ZONE3 = 0x02
EID_ZONE4 = 0x03
EID_JOYSTICK = 0x04
EID_A = 0x05 -- reference only: A is intentionally excluded from the CC map (see docs' 'Two
	-- decisions' / CC map design), not forgotten - its ticks fall through to the unhandled-ENCODER log
	-- line.
EID_B = 0x06

-- MARK: - Phase 2 CC dispatch (every SL88 control emits a mappable CC)
--
-- One dedicated MIDI channel carries every gesture below (34 total, CC 40-74 skipping 64) so
-- MainStage can MIDI-Learn each one directly - no in-script patch-selection logic, which is dead:
-- MainStage's patchselector parser only runs when controller_midi_in returns falsy, so injected
-- MIDI (the old Q1a spike's approach) can never reach it. See docs/mainstage-integration.md for the
-- full table and the one-time mapping procedure.
CC_CHANNEL = 0x0F -- channel 16; nothing else is expected to be routed here

CC_MAP = {
	JOY_UP_SHORT = 40,    JOY_UP_LONG = 41,
	JOY_DOWN_SHORT = 42,  JOY_DOWN_LONG = 43,
	JOY_LEFT_SHORT = 44,  JOY_LEFT_LONG = 45,
	JOY_RIGHT_SHORT = 46, JOY_RIGHT_LONG = 47,
	JOY_PRESS_SHORT = 48, JOY_PRESS_LONG = 49,
	JOY_ROTATE = 50,

	ENC1_PRESS_SHORT = 51, ENC1_PRESS_LONG = 52,
	ENC2_PRESS_SHORT = 53, ENC2_PRESS_LONG = 54,
	ENC3_PRESS_SHORT = 55, ENC3_PRESS_LONG = 56,
	ENC4_PRESS_SHORT = 57, ENC4_PRESS_LONG = 58,

	ENC1_TURN = 59, ENC2_TURN = 60, ENC3_TURN = 61, ENC4_TURN = 62,

	ENCB_TURN = 63,
	-- 64 deliberately skipped (sustain CC; harmless on a channel nothing listens to, but not worth the
	-- ambiguity if it's ever routed anywhere).
	ENCB_PRESS_SHORT = 65, ENCB_PRESS_LONG = 66,

	SEL1_SHORT = 67, SEL1_LONG = 68,
	SEL2_SHORT = 69, SEL2_LONG = 70,
	SEL3_SHORT = 71, SEL3_LONG = 72,
	SEL4_SHORT = 73, SEL4_LONG = 74,
}

-- BID -> { short, long } CC_MAP keys, for every button wired to a CC.
BUTTON_CC = {
	[BID_JOY_UP]    = { short = 'JOY_UP_SHORT',    long = 'JOY_UP_LONG' },
	[BID_JOY_DOWN]  = { short = 'JOY_DOWN_SHORT',  long = 'JOY_DOWN_LONG' },
	[BID_JOY_LEFT]  = { short = 'JOY_LEFT_SHORT',  long = 'JOY_LEFT_LONG' },
	[BID_JOY_RIGHT] = { short = 'JOY_RIGHT_SHORT', long = 'JOY_RIGHT_LONG' },
	[BID_JOY_MAIN]  = { short = 'JOY_PRESS_SHORT', long = 'JOY_PRESS_LONG' },
	[BID_ZONE1_SEL] = { short = 'SEL1_SHORT', long = 'SEL1_LONG' },
	[BID_ZONE2_SEL] = { short = 'SEL2_SHORT', long = 'SEL2_LONG' },
	[BID_ZONE3_SEL] = { short = 'SEL3_SHORT', long = 'SEL3_LONG' },
	[BID_ZONE4_SEL] = { short = 'SEL4_SHORT', long = 'SEL4_LONG' },
	[BID_ZONE1_ENC] = { short = 'ENC1_PRESS_SHORT', long = 'ENC1_PRESS_LONG' },
	[BID_ZONE2_ENC] = { short = 'ENC2_PRESS_SHORT', long = 'ENC2_PRESS_LONG' },
	[BID_ZONE3_ENC] = { short = 'ENC3_PRESS_SHORT', long = 'ENC3_PRESS_LONG' },
	[BID_ZONE4_ENC] = { short = 'ENC4_PRESS_SHORT', long = 'ENC4_PRESS_LONG' },
	[BID_B_ENC]     = { short = 'ENCB_PRESS_SHORT', long = 'ENCB_PRESS_LONG' },
}

-- EID -> CC_MAP key, for every encoder wired to a CC. A is deliberately absent (see EID_A's comment
-- above).
ENCODER_CC = {
	[EID_ZONE1] = 'ENC1_TURN',
	[EID_ZONE2] = 'ENC2_TURN',
	[EID_ZONE3] = 'ENC3_TURN',
	[EID_ZONE4] = 'ENC4_TURN',
	[EID_JOYSTICK] = 'JOY_ROTATE',
	[EID_B] = 'ENCB_TURN',
}

-- Batch cap for one controller_midi_in return: 16 CCs (48 bytes, 3 bytes each) - well under
-- MainStage's measured ~78-byte injection ceiling, where an oversized array is discarded WHOLE
-- rather than truncated (rule 2 in the banner above). A fast encoder sweep or many simultaneous
-- button events would otherwise risk that ceiling; anything past the cap is left queued for the
-- next round rather than truncated into the array or dropped - see flush_pending_cc().
CC_BATCH_CAP = 16

-- Identification functions
ID_REQUEST = 0x00
ID_APPROVED = 0x01
ID_REJECTED = 0x02
ID_QUERY = 0x03

-- System functions
SYS_DEVICE_NOTIFICATION = 0x00 -- keepalive
SYS_LOGIN_CONFIRMATION = 0x01
SYS_LOGOUT_REQUEST = 0x02
SYS_LOGOUT_CONFIRMATION = 0x03
SYS_STANDBY = 0x04
SYS_RESTART = 0x05
SYS_LOGIN_RECALL = 0x06

-- Display functions
DISP_WRITE_TEXT = 0x00
DISP_CLEAR_SCREEN = 0x01
DISP_DRAW_RECT = 0x02

-- Text align / size
ALIGN_LEFT, ALIGN_CENTER, ALIGN_RIGHT = 0x00, 0x01, 0x02
-- SIZE_MEDIUM (0x01) is UNDOCUMENTED - the spec, sl-link/docs/display-messages.md (upstream spec),
-- only gives pixel heights for small (21px) and big (33px). Assumed ~27px by interpolation, but
-- that is unverified: the zoom screen geometry below that positions text around SIZE_MEDIUM rests
-- on this estimate, not a measurement. Recalibrate the y coordinates around 'zset' in
-- paint_zoom_screen() on hardware if the real glyph height differs.
SIZE_SMALL, SIZE_MEDIUM, SIZE_BIG = 0x00, 0x01, 0x02

-- The keyboard drops a host that goes quiet for ~5s; the app uses 3s.
KEEPALIVE_MS = 3000

-- MainStage tears the script down and re-initialises it mid-session, which resets instanceID to
-- SL_INSTANCE_START - but the SL88 still holds the PREVIOUS incarnation's registration under that
-- id, since controller_finalize never sends a Logout Request (see that function). Bumping the
-- instance byte immediately on rejection would 'solve' it by registering as a DIFFERENT app,
-- silently losing the user's APP-list selection - do not do that here. Wait comfortably longer than
-- the keyboard's ~5s host timeout so the stale registration expires, then retry the SAME id. NEVER
-- shorten this below that margin - rearm_timer()/request_quick_rearm() both special-case
-- STATE_REIDENTIFY_WAIT so nothing overwrites it early. See
-- docs/config-lua-history.md#reidentify_wait_ms-derivation.
REIDENTIFY_WAIT_MS = 6000

-- Retries of the SAME instanceID before falling back to bumping the instance byte. Bounded so a
-- GENUINE collision (the other script instance, loaded for the other USB-MIDI interface, alive and
-- rejecting us every time) doesn't wait forever.
MAX_SAME_ID_RETRIES = 2

APP_NAME = 'MainStage'

-- MARK: - Session state

STATE_IDLE = 'idle'
STATE_IDENTIFYING = 'identifying'
STATE_LISTED = 'listed' -- approved, waiting for the user to pick us on the SL88
STATE_ACTIVE = 'active'
STATE_STANDBY = 'standby'
STATE_REIDENTIFY_WAIT = 'reidentify_wait' -- rejected; waiting out REIDENTIFY_WAIT_MS before retrying the same id

state = STATE_IDLE
instanceID = SL_INSTANCE_START
pendingMessages = {}

-- Phase 2 CC dispatch state - see the CC_MAP block above and queue_cc()/ flush_pending_cc() below.
pendingCC = {} -- control name (a CC_MAP key) -> pending value, coalesced
pendingCCOrder = {} -- insertion order of pendingCC's keys, for a deterministic batch
pendingReleases = {} -- controls whose 127 press already went out; queue their 0 release the NEXT
	-- round (see queue_momentary_cc())
encoderValue = { -- absolute 0-127 tracked value per encoder wired to a CC
	[EID_ZONE1] = 64, [EID_ZONE2] = 64, [EID_ZONE3] = 64, [EID_ZONE4] = 64,
	[EID_JOYSTICK] = 64, [EID_B] = 64,
}

-- Gates EVERY settriggertimer call (rule 6 in the banner above): true whenever a one-shot is
-- currently outstanding. rearm_timer() only calls settriggertimer when this is false, and sets it
-- true when it does; controller_timer_trigger() clears it at its own start (the one-shot has just
-- fired). Without this, controller_midi_in's per-note rearm_timer() call keeps cancelling and
-- restarting the pending timer while the user plays, so controller_timer_trigger never fires and
-- the SL88 drops the host after ~5s of silence. See
-- docs/config-lua-history.md#rule-6-notes-starve-the-clock.
--
-- Every OTHER direct settriggertimer call site must keep this flag honest: controller_initialize
-- (true - first arm), controller_timer_trigger's own top-of-function call (does NOT set this true -
-- confirmed on hardware to be a no-op from inside itself, see the SESSION CLOCK note above
-- controller_midi_in), and handle_identification_rejected's REIDENTIFY_WAIT_MS arm (true -
-- genuinely arms a timer).
timerPending = false

-- Which interval the CURRENTLY OUTSTANDING one-shot (if timerPending is true) was armed at -
-- KEEPALIVE_MS, FLUSH_SOON_MS, POPUP_TICK_MS, or REIDENTIFY_WAIT_MS. Set at every settriggertimer
-- call site alongside timerPending. Read by request_quick_rearm() (below) to decide whether an
-- outstanding LONG interval should be shortened to FLUSH_SOON_MS. See
-- docs/config-lua-history.md#quick-rearm-2026-08-21.
timerArmedInterval = KEEPALIVE_MS

-- Retries left for the CURRENT instanceID - see handle_identification_rejected. Reset to
-- MAX_SAME_ID_RETRIES whenever a FRESH instanceID is adopted (controller_initialize, and the bump
-- fallback itself) or an identification succeeds; decremented on every same-id retry.
reidentifyRetriesLeft = MAX_SAME_ID_RETRIES

-- The one-display-message-per-tick pacing gate (rule 5 in the banner above). Set TRUE once per
-- timer tick, by controller_timer_trigger. flush_pending() may dequeue and emit a display message
-- (itemType IT_DISPLAY - this includes queue_sacrificial_redraw's trailing duplicate, which has no
-- regionId but is still IT_DISPLAY) only while this is true, and clears it the instant it does.
-- Protocol messages (identification, keepalive, logout - regionId nil, itemType
-- IT_SYSTEM/IT_IDENTIFICATION) and the trailing Identification Query are NEVER gated by this flag:
-- they go out on every flush regardless, because the query's reply is the only thing that re-arms
-- the one-shot timer (see the SESSION CLOCK note above controller_timer_trigger) - gating it too
-- would stall the session clock the moment any display work was queued.
--
-- Starts true so a display message queued before the very first timer tick can still go out on the
-- next available flush rather than waiting up to KEEPALIVE_MS. Without this gate, the SL88 silently
-- drops a display message that arrives while it is still painting the previous one - see
-- docs/config-lua-history.md#defect-a-the-ungated-flush-drained-at-round-trip-speed-not-timer-speed
-- for the hardware finding this fixes.
displayFlushReady = true

-- A full-screen Clear Screen plausibly takes the panel longer to paint than an ordinary text line.
-- Set to MODE_SWITCH_SETTLE_TICKS by flush_pending() the moment it emits a Clear Screen;
-- decremented by controller_timer_trigger, which withholds that tick's displayFlushReady grant
-- while this is nonzero - so the draws that follow a clear get roughly MODE_SWITCH_SETTLE_TICKS+1
-- tick periods of quiet instead of one. Protocol messages and the trailing Identification Query are
-- never gated by displayFlushReady at all, so the session clock keeps running through the settle
-- regardless.
--
-- Named as its own constant, not folded into FLUSH_SOON_MS, so the two can be retuned
-- independently. Raised from 1 to 3 after a hardware report of stale text after mode switches - see
-- docs/config-lua-history.md#the-clear-screen-ban-and-its-lift and
-- #fix-5-audit-the-first-switch-anomaly for what this did and didn't explain.
MODE_SWITCH_SETTLE_TICKS = 3
displaySettleTicks = 0

-- Counts every display message queue_message() handles (append OR coalesced replace-in-place).
-- update_screen()/paint_screen() used to detect "did this paint queue anything real" by comparing
-- #pendingMessages before/after - that broke once coalescing can replace an existing entry without
-- changing the queue's length, so they diff this counter instead.
queuedDisplayOps = 0

-- What MainStage has loaded (from controller_select_patch), and the model for both display modes
-- below. currentConcert already existed before this feature and is reused rather than adding a
-- parallel concertName. 'zoom' stays the default (unchanged on load/restart); the Zoom button
-- (BID_ZOOM, see handle_zoom_button) toggles to 'list' and back. See
-- docs/config-lua-history.md#defect-a-the-ungated-flush-drained-at-round-trip-speed-not-timer-speed
-- for why 'list' used to be avoided (a display-pacing bug, since fixed - not anything about the
-- list screen itself).
displayMode = 'zoom' -- or 'list'

activeSetIndex = 0
activePatchIndex = 0
currentConcert = ''
setName = ''
patchName = ''

-- cursorIndex is an index into listRows (0-based, matching the pattern used throughout this file:
-- listRows[cursorIndex + 1] is the Lua-array entry). Phase 2 moves it independently of the active
-- patch (joystick navigation); Phase 1 has no wired input for that, so controller_select_patch
-- simply keeps it tracking whatever MainStage just loaded - see find_active_row_index().
cursorIndex = 0
scrollOffset = 0

-- The flat, interleaved patchlist, normalised: { label, isPatch, setIndex, patchIndex }, in the
-- SAME order MainStage's own patchlist array uses - this order IS the continuous list (sets and
-- patches interleaved exactly as MainStage displays them), so it is built with ipairs(), not
-- pairs(), in controller_select_patch: order is not just cosmetic here the way it was for the old
-- per-set filter.
listRows = {}

-- What the screen was last painted with, and when. Used to keep the display self-healing: see the
-- ID_QUERY handling in handle_sl_frame.
lastPaintedPatch = nil
lastPaintTick = -1

-- Repaint at least this often even when nothing changed, because the SL88 redraws its own screen
-- when the user picks an app from the APP list and there is no reliable signal for that (LOGIN
-- CONFIRMATION only arrives on a *fresh* login; if the keyboard still remembers us it never sends
-- one).
--
-- MUST be counted in IDLE ticks, not raw timer ticks - the tick rate is not constant, it drops to
-- FLUSH_SOON_MS while a repaint drains. Counting raw ticks makes 'N ticks' elapse fast mid-drain,
-- which repaints, which queues more work, which produces more fast ticks: a runaway repaint loop.
-- See Tests/lua/harness.lua's 'queue convergence' and 'repaint rate' checks, which fail if this
-- regresses.
REPAINT_EVERY_IDLE_TICKS = 10
idleTicks = 0

-- MARK: - Outbound plumbing
--
-- A script can only send by returning MIDI from a callback. MainStage imposes a BYTE-LENGTH CEILING
-- on what it will emit (rule 2 in the banner): measured on hardware, 78 bytes render and 87 bytes
-- render NOTHING AT ALL - the whole array is discarded, not truncated. Keep queued messages
-- DISCRETE rather than pre-concatenated, and emit only as many whole messages per flush as fit
-- inside FLUSH_BUDGET; whatever is left over goes out on a following tick. FLUSH_BUDGET sits below
-- the 78 known to work, since the exact ceiling is only bracketed to [78, 87) and there is nothing
-- to gain from running close. See docs/config-lua-history.md#the-mainstage-byte-ceiling.
FLUSH_BUDGET = 72

-- Write Text's fixed wire overhead before the string itself: header+ids (7) + itemType+func (2) +
-- x/y/maxWidth (6) + align+size (2) + fg rgb (3) + bg rgb (3) + 0x00 terminator (1) + F7 (1) = 25.
WRITE_TEXT_OVERHEAD = 25

-- While output is still queued, ask for the next tick quickly rather than waiting a whole keepalive
-- period, so a repaint converges in a fraction of a second instead of one message every
-- KEEPALIVE_MS. This is the actual pace a repaint drains at, one display message per interval - it
-- only became true once flush_pending() started gating display messages behind displayFlushReady
-- (set once per timer tick); before that this constant was inert (see
-- docs/config-lua-history.md#defect-a-the-ungated-flush-drained-at-round-trip-speed-not-timer-speed).
--
-- A sweep toward a lower value (50 -> 35 -> 25) is planned but not run past 50 - see
-- docs/config-lua-history.md#flush_soon_ms-retuning-and-the-sweep-plan for the procedure and the
-- known-good fallback (100) before changing this.
FLUSH_SOON_MS = 50

-- `regionId`, when given, is stashed as a NAMED field on the message table (Lua's `#`/ipairs only
-- see the integer-keyed byte sequence, so this rides along for free without disturbing
-- flush_pending's byte-for-byte indexing or drop_queued_display's `m[8]` itemType check). It is how
-- drop_queued_display() finds its way back to the `drawn[id]` memo entry a discarded message came
-- from - see that function's comment - and, below, how a newer paint for the same region COALESCES
-- with an older one still sitting in the queue instead of piling up behind it.
--
-- PER-REGION COALESCING: if the queue already holds a display message for this SAME regionId,
-- REPLACE it in place rather than appending a duplicate - see
-- docs/config-lua-history.md#per-region-coalescing-under-rapid-navigation for the hardware finding
-- this fixes. Position is preserved deliberately - the SL88 has no layers and paints strictly in
-- message order, so an update to one region must not reorder it relative to regions queued around
-- it, or draw order (e.g. a row's backing rect before its text) could invert.
--
-- Protocol messages (identification, keepalive, logout - regionId nil) are NEVER coalesced: they
-- append as always. Collapsing two Identification Queries, for instance, would drop one side of a
-- request/reply pair the session clock depends on (see the SESSION CLOCK note near
-- controller_timer_trigger).
function queue_message(msg, regionId)
	if regionId then
		msg.regionId = regionId
		queuedDisplayOps = queuedDisplayOps + 1
		for i = 1, #pendingMessages do
			if pendingMessages[i].regionId == regionId then
				pendingMessages[i] = msg
				return
			end
		end
	end
	table.insert(pendingMessages, msg)
end

function has_pending()
	return #pendingMessages > 0
end

-- Counts every display message flush_pending() actually emits (not merely queues). Screen content
-- proves what was PAINTED; it cannot distinguish a message that was sent and dropped by the
-- keyboard from one that was never sent at all - see the alternating-row-loss finding at the
-- displayMode declaration above. This is the observation path that tells the two apart.
flushCounter = 0

-- Emits whole messages up to the budget. `includeQuery` appends an Identification Query and
-- reserves room for it inside the budget: its reply is the only thing that re-arms the one-shot
-- timer (see the SESSION CLOCK note above controller_midi_in), so a flush carrying no query can
-- stall the session clock.
function flush_pending(includeQuery)
	local out = {}
	local query = includeQuery and msg_identification_query() or nil
	local reserve = query and #query or 0
	-- A queued message may tag itself with an .outport field to send on a port other than SL_PORT
	-- (nothing currently does - the Phase 2 CC batch goes out through flush_pending_cc, not this path,
	-- and is outport-less by design). General escape hatch: an ordinary queued message leaves .outport
	-- nil and keeps going to SL_PORT. A MIDIPacketList return can only carry one outport per call, so
	-- this is set from the single message dequeued below only.
	local outPort = SL_PORT

	-- Exactly ONE queued message per flush, always paired with the query - the only shape ([display,
	-- query]) ever confirmed reliable on hardware. See
	-- docs/config-lua-history.md#the-display-query-flush-shape.
	--
	-- A display message (itemType IT_DISPLAY) may only be dequeued here while displayFlushReady is
	-- true, and doing so clears it (rule 5 in the banner). A non-display, protocol message at the
	-- front of the queue (identification, keepalive, logout) is never gated - it dequeues every flush
	-- regardless.
	--
	-- If the head message can't go out this flush (it is IT_DISPLAY and displayFlushReady is false),
	-- scan forward for the FIRST protocol message (itemType ~= IT_DISPLAY) and let it jump the queue
	-- instead, removed from its own position with everything else left untouched - otherwise a
	-- keepalive queued behind a display backlog would starve for the whole repaint. See
	-- docs/config-lua-history.md#defect-b-a-keepalive-stuck-behind-a-display-backlog. Display messages
	-- never reorder relative to each other - only a protocol message can jump ahead of ones still
	-- waiting on displayFlushReady. Still at most one queued message per flush, still paired with the
	-- query below.
	if #pendingMessages > 0 then
		local head = pendingMessages[1]
		local headIsDisplay = (head[8] == IT_DISPLAY)
		local index, m = nil, nil
		if not headIsDisplay or displayFlushReady then
			index, m = 1, head
		else
			for i = 2, #pendingMessages do
				if pendingMessages[i][8] ~= IT_DISPLAY then
					index, m = i, pendingMessages[i]
					break
				end
			end
		end

		if m ~= nil and #m + reserve <= FLUSH_BUDGET then
			local isDisplay = (m[8] == IT_DISPLAY)
			table.remove(pendingMessages, index)
			for i = 1, #m do out[#out + 1] = m[i] end
			if m.outport then outPort = m.outport end
			if isDisplay then
				displayFlushReady = false
				-- CLEAR SCREEN SETTLE GUARD: see displaySettleTicks' declaration. A Clear Screen going out
				-- earns the next draw MODE_SWITCH_SETTLE_TICKS extra ticks of quiet on top of the ordinary
				-- one-per-tick pacing.
				if m[9] == DISP_CLEAR_SCREEN then displaySettleTicks = MODE_SWITCH_SETTLE_TICKS end
			end
			flushCounter = flushCounter + 1
			-- `tick=` ties this FLUSH to controller_timer_trigger's tick print, so a captured log reads as
			-- 'tick N emitted region R, depth D' - flushes can also happen off-tick (inbound-frame flushes
			-- in controller_midi_in, controller_select_patch); a FLUSH whose tick= repeats the previous
			-- FLUSH's is exactly one of those.
			print('[sllink] FLUSH #' .. flushCounter ..
				' tick=' .. timerTicks ..
				' regionId=' .. tostring(m.regionId or 'none') ..
				' bytes=' .. #m ..
				' queueDepthAfter=' .. #pendingMessages)
		end
	end

	if query then
		for i = 1, #query do out[#out + 1] = query[i] end
	end

	if #out == 0 then return nil end
	return { midi = out, outport = outPort }
end


-- MARK: - Phase 2 CC dispatch (queue/emit; see the CC_MAP block near the top)

-- Coalesces into the pending-CC table, keyed by CONTROL (a CC_MAP key), not by CC number. A second
-- call for the same control before it flushes REPLACES the pending value rather than queuing a
-- duplicate - this is what lets a fast encoder sweep collapse to one CC per control instead of one
-- per tick (see controller_midi_in's return path). Encoders send this absolute 0-127 tracked value,
-- not relative increments; switching to relative would mean changing the accumulate-and-clamp path
-- that produces `value` and this replace-in-place coalescing, not just a constant.
function queue_cc(control, value)
	if value < 0 then value = 0 elseif value > 127 then value = 127 end
	if pendingCC[control] == nil then
		pendingCCOrder[#pendingCCOrder + 1] = control
	end
	pendingCC[control] = value
end

-- Buttons read as momentary in MainStage (127 then 0), but queue_cc's own per-control coalescing
-- means two queue_cc calls back to back for the same control would just leave the release (0)
-- pending - the press would never reach a batch at all. So the release is NOT queued immediately
-- behind the press: this only queues 127 now and remembers the control in pendingReleases;
-- controller_midi_in queues each pending release's 0 at the START of the NEXT round (the next
-- inbound SL frame - in practice usually within one Identification Query/reply round-trip, since
-- that heartbeat keeps inbound SL frames arriving even with no further user input), before handling
-- that frame's own event. Simpler than threading a delay through the batching path, and 'shortly
-- after' is all momentary behaviour needs.
function queue_momentary_cc(control)
	queue_cc(control, 127)
	pendingReleases[#pendingReleases + 1] = control
end

function build_cc_message(control, value)
	return { 0xB0 + CC_CHANNEL, CC_MAP[control], value }
end

-- Batches every pending CC into ONE { midi = {...} } table (outport-less, like the old spike
-- injection this replaces) and clears what it emits. Capped at CC_BATCH_CAP controls (CC_BATCH_CAP
-- * 3 bytes) - see that constant's comment for why. A control past the cap is left in
-- pendingCC/pendingCCOrder for the next round rather than being dropped or truncated into an
-- oversized array.
function flush_pending_cc()
	local out = {}
	local emitted = 0
	local remaining = {}
	for i = 1, #pendingCCOrder do
		local control = pendingCCOrder[i]
		if emitted < CC_BATCH_CAP then
			local msg = build_cc_message(control, pendingCC[control])
			for j = 1, #msg do out[#out + 1] = msg[j] end
			pendingCC[control] = nil
			emitted = emitted + 1
		else
			remaining[#remaining + 1] = control
		end
	end
	pendingCCOrder = remaining
	print('[sllink] CC batch: ' .. emitted .. ' CC(s), ' .. #out .. ' bytes' ..
		(#remaining > 0 and (', ' .. #remaining .. ' deferred to next round') or ''))
	return { midi = out }
end


-- MARK: - Message builders

function sl_header()
	local m = {}
	for i = 1, #SL_HEADER do m[i] = SL_HEADER[i] end
	m[#m + 1] = SL_HOST_ID
	m[#m + 1] = instanceID
	return m
end

-- ASCII-clamps to the SLMK2 font range and 0x00-terminates, matching SLLinkEncoder.asciiTerminated.
function append_text(msg, text, maxLength)
	if text ~= nil then
		local limit = math.min(#text, maxLength or 32)
		for i = 1, limit do
			local b = string.byte(text, i)
			if b < 0x20 or b > 0x80 then b = 0x20 end
			table.insert(msg, b)
		end
	end
	table.insert(msg, 0x00)
end

-- Splits a value >127 into (msb, lsb) - mirrors SLLinkEncoder.msbLsb.
function append_msb_lsb(msg, value)
	if value == nil or value < 0 then value = 0 end
	table.insert(msg, math.floor(value / 128) % 128)
	table.insert(msg, value % 128)
end

-- 8-bit RGB -> the 7-bit-per-channel form every SL Link colour field uses (SLLinkEncoder.rgb7 drops
-- the least significant bit).
function append_rgb(msg, r, g, b)
	table.insert(msg, math.floor(r / 2))
	table.insert(msg, math.floor(g / 2))
	table.insert(msg, math.floor(b / 2))
end

function msg_identification_request()
	local m = sl_header()
	table.insert(m, IT_IDENTIFICATION)
	table.insert(m, ID_REQUEST)
	append_text(m, APP_NAME, 32)
	table.insert(m, SL_END)
	return m
end

-- Sent purely to elicit a reply and thereby keep the session clock running - see
-- controller_timer_trigger.
function msg_identification_query()
	local m = sl_header()
	table.insert(m, IT_IDENTIFICATION)
	table.insert(m, ID_QUERY)
	table.insert(m, SL_END)
	return m
end

-- flush_pending only ever dequeues ONE message per flush, and only if it fits alongside the
-- Identification Query it always reserves room for (see flush_pending's comment) - a message that
-- never fits is never sent AND never dropped, which jams the queue and stalls the session clock
-- forever. append_text used to allow up to 96 characters with no relation to that budget, so a
-- ~48-char patch name was enough to hang the script.
--
-- This cap is NOT the rule-4 'never truncate' violation: Max Width still does the *visual*
-- truncation in pixels, with its own '...' for anything that doesn't fit on screen, regardless of
-- how many characters were sent. This is a transport limit only, computed from the query builder
-- itself (not hand-counted) so it stays correct if either message's shape ever changes.
TEXT_STRING_CAP = FLUSH_BUDGET - #msg_identification_query() - WRITE_TEXT_OVERHEAD

function msg_system(func)
	local m = sl_header()
	table.insert(m, IT_SYSTEM)
	table.insert(m, func)
	table.insert(m, SL_END)
	return m
end

function msg_clear_screen(r, g, b)
	local m = sl_header()
	table.insert(m, IT_DISPLAY)
	table.insert(m, DISP_CLEAR_SCREEN)
	append_rgb(m, r, g, b)
	table.insert(m, SL_END)
	return m
end

function msg_write_text(text, x, y, maxWidth, align, size, fr, fg, fb, br, bg, bb)
	local m = sl_header()
	table.insert(m, IT_DISPLAY)
	table.insert(m, DISP_WRITE_TEXT)
	append_msb_lsb(m, x)
	append_msb_lsb(m, y)
	append_msb_lsb(m, maxWidth)
	table.insert(m, align)
	table.insert(m, size)
	append_rgb(m, fr, fg, fb)
	append_rgb(m, br, bg, bb)
	if text ~= nil and #text > TEXT_STRING_CAP then
		print('[sllink] msg_write_text: clamping "' .. text .. '" (' .. #text ..
			' chars) to ' .. TEXT_STRING_CAP .. ' chars - transport limit (see' ..
			' TEXT_STRING_CAP), not a visual-truncation change; Max Width still' ..
			' does its own "..." truncation on screen.')
	end
	append_text(m, text, TEXT_STRING_CAP)
	table.insert(m, SL_END)
	return m
end

function msg_draw_rect(x, y, w, h, r, g, b)
	local m = sl_header()
	table.insert(m, IT_DISPLAY)
	table.insert(m, DISP_DRAW_RECT)
	append_msb_lsb(m, x)
	append_msb_lsb(m, y)
	append_msb_lsb(m, w)
	append_msb_lsb(m, h)
	append_rgb(m, r, g, b)
	table.insert(m, SL_END)
	return m
end

-- MARK: - Per-region memoization
--
-- Ported from SL-Link-Mainstage/SLLink/SLLinkDisplay.swift: draw_text/draw_rect remember the full
-- parameter tuple they last sent for a given caller-supplied id, and queue nothing when a call
-- repeats it unchanged. Mandatory, not an optimisation - at one message per ~100ms flush, a full
-- list repaint costs about a second; without this every self-heal repaint would cost the same
-- again.
--
-- NON-OVERLAP RULE (same as SLLinkDisplay's doc comment): every region id must own screen pixels
-- that no other id draws. A change to one id's memo does not invalidate any other id, so a caller
-- that layers draws - e.g. a filled rect under text - will corrupt the screen the moment only the
-- bottom layer changes and the top layer is skipped as unchanged; the device has no concept of
-- layers, it paints strictly in message order. A caller that cannot avoid overlap must clear the
-- shared ids' drawn[] entries together so they resend as one unit - see draw_text_with_erase()
-- below for the one place this project needs that (the zoom screen's zset/zname/znext, which must
-- draw at maxWidth=0 and so cannot self-clear).

drawn = {}

function invalidate_all()
	drawn = {}
end

function tuple_equal(a, b, n)
	if a == nil then return false end
	for i = 1, n do
		if a[i] ~= b[i] then return false end
	end
	return true
end

function draw_text(id, text, x, y, maxWidth, align, size, fr, fg, fb, br, bg, bb)
	local t = { text, x, y, maxWidth, align, size, fr, fg, fb, br, bg, bb }
	if tuple_equal(drawn[id], t, #t) then return end
	drawn[id] = t
	queue_message(msg_write_text(text, x, y, maxWidth, align, size, fr, fg, fb, br, bg, bb), id)
end

function draw_rect(id, x, y, w, h, r, g, b)
	local t = { x, y, w, h, r, g, b }
	if tuple_equal(drawn[id], t, #t) then return end
	drawn[id] = t
	queue_message(msg_draw_rect(x, y, w, h, r, g, b), id)
end

-- MARK: - Screen
--
-- Each element is queued as its own message and delivered across consecutive flushes, because
-- MainStage will not emit more than ~78 bytes at once (see FLUSH_BUDGET). Concatenating a whole
-- repaint is exactly what produced a completely black screen in earlier attempts.
--
-- No manual string truncation: the SL Link spec sets no text-length limit, and Max Width already
-- truncates visually in pixels, appending '...' when needed. Let the keyboard do it.

SCREEN_WIDTH = 320
SCREEN_HEIGHT = 240
TEXT_X = 8
TEXT_MAXW = SCREEN_WIDTH - (2 * TEXT_X)

ROW_COUNT = 8
ROW_Y0 = 30
ROW_PITCH = 26
ROW_X = 8
ROW_MAXW = 304

-- Max Width truncation is UNRELIABLE at SIZE_BIG - confirmed on hardware: a long patch name at
-- maxWidth=304 rendered as a single letter followed by '...'. So the zoom screen's patch name
-- truncates itself in Lua (truncate_text(), paint_zoom_screen()) rather than trusting the device.
-- See docs/config-lua-history.md#max-width-truncation-broken-at-size_big. Confirmed working at
-- SIZE_SMALL (see
-- docs/config-lua-history.md#settled-facts-max-width-and-the-write-text-background-box), which is
-- why every list row below uses a real, non-zero maxWidth instead. Do not switch zname/zset back to
-- trusting Max Width without re-confirming on hardware first.
--
-- HARDWARE-CALIBRATED BY EYE, not measured from real glyph widths. Retune by eye against a name a
-- couple of characters either side of this constant if the geometry below changes (screen width, X
-- margins, font).
BIG_MAX_CHARS = 27

-- Same idea, for SIZE_MEDIUM text (only zset uses this - znext draws SIZE_SMALL with a trusted Max
-- Width instead, needing no character-count truncation). Also eye-calibrated; retune the same way
-- as BIG_MAX_CHARS.
MEDIUM_MAX_CHARS = 36

-- truncate_text() cuts zname/zset to exactly these character counts before they are drawn (see
-- draw_text_with_erase() below for how the vacated band is cleared). znext no longer calls
-- truncate_text() - see MEDIUM_MAX_CHARS's comment above. TEXT_STRING_CAP is msg_write_text's own
-- hard transport clamp (a DIFFERENT limit - see that constant's comment); assert the relationship
-- rather than assume it, since if either MAX_CHARS constant is ever retuned past TEXT_STRING_CAP,
-- msg_write_text would silently re-truncate the already-truncated string, losing truncate_text()'s
-- own '...' and cutting mid-word.
assert(BIG_MAX_CHARS <= TEXT_STRING_CAP,
	'BIG_MAX_CHARS must fit within TEXT_STRING_CAP or zname draws would be re-truncated on the wire')
assert(MEDIUM_MAX_CHARS <= TEXT_STRING_CAP,
	'MEDIUM_MAX_CHARS must fit within TEXT_STRING_CAP or zset draws would be re-truncated on the wire')

-- MANUAL CENTERING for maxWidth=0 lines. At Width=0 the SL88's own alignment area collapses to a
-- single point, so ALIGN_CENTER/ALIGN_RIGHT have nothing to justify within and draw pinned left
-- regardless of the align byte - confirmed against the pinned upstream spec's own wording.
-- draw_text_with_erase() must keep maxWidth=0 (that's the whole reason it needs an explicit erase
-- rect - see its own comment) and Max Width truncation is confirmed broken at SIZE_BIG
-- (BIG_MAX_CHARS's comment), so switching to a real maxWidth to get alignment 'for free' would risk
-- reintroducing that bug. Centring is computed in Lua instead: estimate the string's rendered pixel
-- width and pick an X that lands it mid-screen, then draw ALIGN_LEFT at that X. See
-- docs/config-lua-history.md#manual-centering-at-maxwidth-0.
--
-- EYE-CALIBRATED, like BIG_MAX_CHARS/MEDIUM_MAX_CHARS - no real glyph-metrics table exists for this
-- font. Retune both alongside those two constants if geometry or font ever changes, the same way:
-- by eye, against a name a few characters either side of dead centre. See
-- docs/config-lua-history.md#char_width-calibration for how these two numbers were derived/retuned.
CHAR_WIDTH_BIG = 11    -- floor(304 / 27)
CHAR_WIDTH_MEDIUM = 8  -- retuned 2026-08-27 from derived 7 (11*22/33≈7.33) - hardware showed 7 rendering right-of-center

-- Estimated total rendered pixel width of `text` at `size`, for the manual centering above only -
-- NOT used for truncation (truncate_text() already owns that, by character count).
function estimate_text_width_px(text, size)
	local perChar = (size == SIZE_BIG) and CHAR_WIDTH_BIG or CHAR_WIDTH_MEDIUM
	return (text and #text or 0) * perChar
end

-- SCROLL-OFF MARGIN (vim's `scrolloff`): a scroll TRIGGERS once the cursor comes within
-- SCROLL_MARGIN rows of an edge, so at least this many rows of context stay visible beyond it -
-- Jeroen's requirement that at least one patch AFTER the current one is always on screen. 2, not 1:
-- set headers occupy rows in a continuous list, so a margin of 1 could leave the single visible row
-- below the current patch a set header. See
-- docs/config-lua-history.md#scroll_margin-and-the-worked-example. Asserted rather than assumed:
-- SCROLL_MARGIN must stay under half the window or this rule and the final clamp in clamp_scroll()
-- fight each other.
SCROLL_MARGIN = 2
assert(SCROLL_MARGIN < ROW_COUNT / 2,
	'SCROLL_MARGIN must be less than ROW_COUNT / 2 or the margin and the final clamp fight each other')

-- PAGE_OVERLAP is DERIVED, not picked: the cursor's landing position after a page jump is not a
-- free choice once SCROLL_MARGIN and ROW_COUNT are fixed. Landing at the edge just jumped to (the
-- smallest possible overlap) puts the cursor back inside the OPPOSITE margin's trigger zone,
-- causing every subsequent single-row step to re-trigger a jump the other way - oscillation, worse
-- than the bug page-jumping exists to fix. The only landing spot safe from BOTH margins at once is
-- SCROLL_MARGIN rows in from the edge just crossed, which forces PAGE_OVERLAP = 2 * SCROLL_MARGIN.
-- Do not shrink this without re-running the oscillation check (see Tests/lua/harness.lua's
-- clamp_scroll test) - a smaller value than this WILL oscillate. See
-- docs/config-lua-history.md#page_overlap-derivation-and-the-oscillation-trace.
PAGE_OVERLAP = 2 * SCROLL_MARGIN
assert(PAGE_OVERLAP < ROW_COUNT,
	'PAGE_OVERLAP must be less than ROW_COUNT or a jump does not move the window at all')

-- Keeps scrollOffset such that cursorIndex is always inside the visible window, with SCROLL_MARGIN
-- rows of context beyond it wherever the list itself allows.
--
-- Once triggered, the window jumps by (ROW_COUNT - PAGE_OVERLAP) rows in the direction of travel,
-- landing the cursor SCROLL_MARGIN rows in from the edge it just crossed - the landing spot with
-- maximum runway in the direction of travel while staying clear of BOTH margins at once (see
-- PAGE_OVERLAP's comment for why any other landing spot oscillates). Do NOT replace this with a
-- one-row minimum-shift policy - that was tried and abandoned; see
-- docs/config-lua-history.md#the-one-row-shift-abandoned.
--
-- The cursor's landing row is computed directly from cursorIndex, not as an offset from the OLD
-- scrollOffset, so this is correct for a jump of any size (a single patch step, or the much bigger
-- cursorIndex jump a set change or full repaint can produce) without a separate case for either.
-- Still edge-triggered, NOT re-centring on every move - an in-window move costs nothing here
-- (scrollOffset untouched, the cheap 2-message case).
--
-- The final clamp is what makes the list's own ends behave: near the top or bottom the landing
-- guarantee can't always be honoured, so the offset pins at its limit and the cursor moves further
-- into the window instead. This is also what keeps the LAST page a full ROW_COUNT-row window rather
-- than a short one: scrollOffset can never exceed #listRows - ROW_COUNT.
--
-- Standalone rather than inlined into controller_select_patch so Phase 2's joystick-driven cursor
-- movement can call it too instead of re-deriving the same clamp arithmetic.
function clamp_scroll()
	local m = SCROLL_MARGIN
	if cursorIndex - m < scrollOffset then
		-- Triggered scrolling BACKWARD: land SCROLL_MARGIN rows in from the window's LAST row - symmetric
		-- with the forward branch below, and the one landing spot that is safe from both margins (see
		-- PAGE_OVERLAP's comment).
		scrollOffset = cursorIndex - (ROW_COUNT - 1 - m)
	elseif cursorIndex + m >= scrollOffset + ROW_COUNT then
		-- Triggered scrolling FORWARD: land SCROLL_MARGIN rows in from the window's FIRST row.
		scrollOffset = cursorIndex - m
	end
	local maxOffset = math.max(0, #listRows - ROW_COUNT)
	if scrollOffset > maxOffset then scrollOffset = maxOffset end
	if scrollOffset < 0 then scrollOffset = 0 end
end

-- Three row states - deliberately fewer than the old four, because the cursor is no longer a colour
-- state at all (see draw_list_row()'s '> ' marker below): only what KIND of row it is, and whether
-- it is the active patch, affects colour now. { fr, fg, fb, br, bg, bb } per state - see
-- docs/full-functionality-plan.md's colour table. All channel values even (the wire format is 7-bit
-- per channel and halves these, dropping the low bit - odd values silently round), except the
-- conventional 255 used for 'fully saturated' throughout this file, which rounds to the same 127 as
-- 254 so costs nothing.
ROW_HEADER = 0
ROW_PATCH  = 1
ROW_ACTIVE = 2

ROW_COLORS = {
	[ROW_HEADER] = { 110, 170, 230,   0,   0,   0 }, -- blue on black: structure, not a patch
	[ROW_PATCH]  = { 150, 150, 150,   0,   0,   0 }, -- grey on black: recessive, the bulk of the list
	[ROW_ACTIVE] = {   0,   0,   0, 255, 170,  40 }, -- black on amber: unmistakable at distance
}

-- MARK: - Encoder value popup
--
-- Shows a transient panel - 'CC <n>' small and dim above, the 0-127 value big and centred, ringed
-- by a 20-segment LED dial - whenever ANY mapped encoder moves, so the value and its wire CC number
-- are visible without a MainStage round-trip. controller_midi_out was confirmed on hardware to
-- report nil name/valueString/color for the mapped CC itself, so this never attempts to show a
-- MainStage parameter name, only the CC number and value, both already known locally via
-- CC_MAP/ENCODER_CC/encoderValue.
--
-- A genuine full-screen display mode (displayMode == 'popup', alongside 'list'/'zoom'), not a
-- floating overlay - see set_display_mode's 'popup' branch and paint_popup_screen below. Owning the
-- whole screen means dismiss_popup() can reuse set_display_mode's proven double-Clear-Screen/
-- invalidate sequence instead of an ad-hoc redraw, and there is nothing underneath to protect from
-- overlap. This was not always true - see docs/config-lua-history.md#the-encoder-value-popup-v1-v5
-- for the v1-v4 visual iteration and the placement trade-off v5's full-screen mode removed.
--
-- How often controller_timer_trigger fires while the popup is up and idle, so
-- POPUP_DISMISS_IDLE_TICKS ticks at roughly this cadence instead of KEEPALIVE_MS's ~3s - see
-- rearm_timer's popupActive branch.
POPUP_TICK_MS = 1000

POPUP_W = 280
POPUP_H = 200
POPUP_X = math.floor((SCREEN_WIDTH - POPUP_W) / 2)
POPUP_Y = math.floor((SCREEN_HEIGHT - POPUP_H) / 2)
POPUP_PAD = 10 -- inset for the label, so it doesn't touch the panel's top edge

POPUP_CONTENT_X = POPUP_X + POPUP_PAD
POPUP_CONTENT_W = POPUP_W - 2 * POPUP_PAD
POPUP_LABEL_Y = POPUP_Y + 12 -- small dim label, above the ring entirely (see geometry check below)

POPUP_CENTER_X = POPUP_X + POPUP_W / 2
-- Ring/value centre deliberately NOT the card's raw vertical midpoint (POPUP_Y + POPUP_H/2 = 120):
-- shifted down so the label has headroom above the ring without shrinking the ring to match a
-- symmetric top/bottom margin it doesn't need (the label only ever occupies the top of the card).
POPUP_CENTER_Y = POPUP_Y + 120

-- Ring geometry. Radius/segment size/count/sweep were chosen so that every one of the 20 segment
-- positions clears (a) the value text's bounding box, (b) the panel border's inner edge, and (c)
-- the label's bottom edge - CHECKED PROGRAMMATICALLY for this exact combination (all 20 positions
-- checked against both boxes for rectangle overlap). RE-RUN THAT CHECK if POPUP_W/POPUP_H/
-- POPUP_RING_RADIUS/POPUP_SEG_SIZE/POPUP_SEG_COUNT ever change - do not eyeball a replacement. See
-- docs/config-lua-history.md#popup-ring-geometry-derivation for the numbers and clearances this was
-- verified against.
--
-- The ring does not close a full 360deg - POPUP_SWEEP_DEG (300) leaves a 60deg gap centred at the
-- bottom (90deg, 6 o'clock), gauge-style. Segments are spaced evenly across the sweep via
-- POPUP_SWEEP_DEG / (POPUP_SEG_COUNT - 1) so the first and last land exactly on the sweep's two
-- endpoints, keeping the gap exactly 60deg wide and centred.
POPUP_RING_RADIUS = 68
POPUP_SEG_SIZE = 5
POPUP_SEG_COUNT = 20
POPUP_SWEEP_DEG = 300 -- full sweep in degrees; the remaining (360 - POPUP_SWEEP_DEG) is the gap
POPUP_GAP_START_DEG = 270 - POPUP_SWEEP_DEG / 2 -- angle of segment 1 (see loop below)

-- Value text: SIZE_BIG, centred in the ring's open middle. Width chosen to clear every segment box
-- per the geometry note above - re-check alongside the ring if this changes.
POPUP_VALUE_W = 100
POPUP_VALUE_X = POPUP_CENTER_X - POPUP_VALUE_W / 2
POPUP_VALUE_Y = POPUP_CENTER_Y - 20

-- Lit ring segments are true orange, deliberately NOT ROW_ACTIVE's amber/gold - the ring reads as
-- its own 'dial' idiom rather than reusing the list's 'this is the active row' colour.
POPUP_BG_COLOR = { 0, 0, 0 }
POPUP_SEG_LIT = { 255, 140, 0 } -- true orange, not amber/gold
POPUP_SEG_UNLIT = { 180, 180, 180 } -- light grey track, clearly visible against the black panel - matches the SL88's own native overlay screens
POPUP_VALUE_FG = { 255, 255, 255 }
POPUP_LABEL_FG = { ROW_COLORS[ROW_PATCH][1], ROW_COLORS[ROW_PATCH][2], ROW_COLORS[ROW_PATCH][3] }
POPUP_BORDER_COLOR = { 200, 210, 220 } -- thin light neutral border, matching the native overlay's frame - NOT orange, keep orange exclusive to the ring's active fill

-- Segment ids and their (x,y) top-left draw_rect positions, computed ONCE here at load time (not
-- per-draw) via math.cos/math.sin. Segment 1 sits at POPUP_GAP_START_DEG (120deg, just past the
-- gap's bottom-left edge) and segments proceed clockwise across POPUP_SWEEP_DEG, evenly spaced
-- every POPUP_SWEEP_DEG/(POPUP_SEG_COUNT-1) ~= 15.8 degrees, ending at segment 20 on the gap's
-- bottom-right edge (60deg) - a 60deg gap at the bottom (90deg, 6 o'clock), not a full circle.
-- Positions are top-left corners (draw_rect's convention - see msg_draw_rect), i.e.
-- centre-on-circle minus half the segment size.
POPUP_SEG_IDS = {}
POPUP_SEG_POS = {}
for i = 1, POPUP_SEG_COUNT do
	POPUP_SEG_IDS[i] = 'popupSeg' .. i
	local angleRad = math.rad(POPUP_GAP_START_DEG + (i - 1) * (POPUP_SWEEP_DEG / (POPUP_SEG_COUNT - 1)))
	local segX = POPUP_CENTER_X + POPUP_RING_RADIUS * math.cos(angleRad) - POPUP_SEG_SIZE / 2
	local segY = POPUP_CENTER_Y + POPUP_RING_RADIUS * math.sin(angleRad) - POPUP_SEG_SIZE / 2
	POPUP_SEG_POS[i] = { math.floor(segX), math.floor(segY) }
end

popupActive = false
-- Cached label/value for the CURRENTLY showing popup, updated by show_popup() and read by
-- paint_popup_screen() - so a repaint triggered from elsewhere (paint_screen() dispatching to
-- paint_popup_screen() because displayMode=='popup', or set_display_mode('popup') itself) can
-- redraw the popup's content without needing the encoder id threaded through every call site.
popupCcNumber = nil
popupValue = 0
-- displayMode to restore when the popup dismisses - set by show_popup() to whatever displayMode was
-- BEFORE it switched to 'popup' (only on the transition into showing, never overwritten while
-- already active - see show_popup's popupActive guard), consumed once by dismiss_popup().
popupPreviousMode = nil
popupLastActivityIdleTick = 0

-- Border: same 'four non-overlapping edge-strip rects' idiom as the Swift companion app's
-- zone-selection outline (SLLinkDemoScreen.drawZoneBorder) - top/bottom span the panel's full
-- width, left/right span only the strip between them, so no two edges cover the same pixel. The
-- fill (popupBg, below) is inset by the border's thickness so it never overlaps the border either -
-- each id owns pixels no other id touches, per SLLinkDisplay's per-id-memoization rule (see this
-- file's CLAUDE.md). Thickness picked thin enough to stay clear of the ring/value geometry above,
-- which already has >=26px of margin between the ring's outer edge and the panel edge.
POPUP_BORDER_THICKNESS = 4

function draw_popup_border()
	local t = POPUP_BORDER_THICKNESS
	local c = POPUP_BORDER_COLOR
	draw_rect('popupBorderTop', POPUP_X, POPUP_Y, POPUP_W, t, c[1], c[2], c[3])
	draw_rect('popupBorderBottom', POPUP_X, POPUP_Y + POPUP_H - t, POPUP_W, t, c[1], c[2], c[3])
	draw_rect('popupBorderLeft', POPUP_X, POPUP_Y + t, t, POPUP_H - 2 * t, c[1], c[2], c[3])
	draw_rect('popupBorderRight', POPUP_X + POPUP_W - t, POPUP_Y + t, t, POPUP_H - 2 * t, c[1], c[2], c[3])
end

function draw_popup_bg()
	local t = POPUP_BORDER_THICKNESS
	draw_rect('popupBg', POPUP_X + t, POPUP_Y + t, POPUP_W - 2 * t, POPUP_H - 2 * t,
		POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3])
end

function draw_popup_label(ccNumber)
	draw_text('popupLabel', 'CC ' .. ccNumber, POPUP_CONTENT_X, POPUP_LABEL_Y, POPUP_CONTENT_W,
		ALIGN_CENTER, SIZE_SMALL, POPUP_LABEL_FG[1], POPUP_LABEL_FG[2], POPUP_LABEL_FG[3],
		POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3])
end

function draw_popup_value(value)
	draw_text('popupValue', tostring(value), POPUP_VALUE_X, POPUP_VALUE_Y, POPUP_VALUE_W,
		ALIGN_CENTER, SIZE_BIG, POPUP_VALUE_FG[1], POPUP_VALUE_FG[2], POPUP_VALUE_FG[3],
		POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3])
end

-- Lit-segment count for a 0-127 value: linear scaling by value/127 (NOT value/128), so that value=0
-- lights 0 segments and value=127 - the actual maximum - lights all 20 exactly, rather than topping
-- out at 19 the way a /128 divisor would (127/128*20 = 19.84, floors to 19).
function popup_lit_count(value)
	return math.floor(value * POPUP_SEG_COUNT / 127)
end

function draw_popup_ring(value)
	local litCount = popup_lit_count(value)
	for i = 1, POPUP_SEG_COUNT do
		local pos = POPUP_SEG_POS[i]
		local color = (i <= litCount) and POPUP_SEG_LIT or POPUP_SEG_UNLIT
		draw_rect(POPUP_SEG_IDS[i], pos[1], pos[2], POPUP_SEG_SIZE, POPUP_SEG_SIZE, color[1], color[2], color[3])
	end
end

-- The popup's own content-painting function, in the same family as paint_zoom_screen()/
-- paint_list_screen() - dispatched to from set_display_mode('popup') (the mode-switch path, once
-- per popup 'session') and from paint_screen() (an ordinary content-driven repaint that lands while
-- displayMode=='popup', e.g. a patch-name change arriving mid-popup - see paint_screen's 3-way
-- branch). Reads popupCcNumber/popupValue rather than taking parameters, since both call sites
-- dispatch generically by mode with no encoder id in hand. Safe to call repeatedly - every draw_*
-- call underneath is per-id memoized (drawn[]), so a call that changes nothing queues nothing (see
-- show_popup's repeat-call path, which relies on exactly this).
function paint_popup_screen()
	draw_popup_bg()
	draw_popup_border()
	draw_popup_label(popupCcNumber)
	draw_popup_value(popupValue)
	draw_popup_ring(popupValue)
end

-- Call from handle_sl_frame's IT_ENCODER branch, right after encoderValue[eid] is updated, for
-- every eid present in ENCODER_CC (looped there, not hardcoded - see that call site).
--
-- FIRST call of a popup 'session' (popupActive false -> true) runs the full
-- set_display_mode('popup') machinery ONCE, whose own paint dispatch does the drawing. REPEAT calls
-- (continued scrubbing) must NOT re-run set_display_mode() - that would re-send the double Clear
-- Screen and a full invalidate on every tick. Instead call paint_popup_screen() directly: its
-- draw_* calls are per-id memoized, so unchanged content (background/border/label while
-- popupCcNumber matches) queues nothing and only a genuinely new value re-queues - a DIFFERENT
-- control taking over redraws the label for free, since its CC number differs.
function show_popup(eid)
	local control = ENCODER_CC[eid]
	if control == nil then return end

	popupCcNumber = CC_MAP[control]
	popupValue = encoderValue[eid]
	popupLastActivityIdleTick = idleTicks

	if not popupActive then
		popupPreviousMode = displayMode
		popupActive = true
		set_display_mode('popup') -- full mode-switch machinery once; its own dispatch paints the popup
	else
		paint_popup_screen()
		request_quick_rearm()
	end
end

-- ~1s-idle dismissal, quantised to the session clock's existing idle-tick counter (idleTicks,
-- incremented once per timer-tick while nothing is draining). While popupActive is true,
-- rearm_timer() arms the tick at POPUP_TICK_MS (~1s) instead of the normal KEEPALIVE_MS (~3s), so
-- POPUP_DISMISS_IDLE_TICKS=1 means 'wait one ~1s tick'. This reuses the single existing timer
-- rather than adding a second settriggertimer, which risks the same starved-clock class of bug rule
-- 6 in the banner fixes.
POPUP_DISMISS_IDLE_TICKS = 1

-- Popup is a full-screen mode, so dismissal is just switching BACK to whatever mode was active
-- before it took over - reusing set_display_mode's own proven double-Clear-Screen/
-- drop_queued_display/invalidate_all/sacrificial-redraw sequence. popupActive is cleared BEFORE
-- that call so show_popup's 'is this a fresh popup' check is already correct if a new popup is
-- triggered again immediately after dismissal.
function dismiss_popup()
	popupActive = false
	set_display_mode(popupPreviousMode)
end

-- Called once per timer tick (controller_timer_trigger), after idleTicks is updated for this tick.
function check_popup_dismiss()
	if popupActive and (idleTicks - popupLastActivityIdleTick) >= POPUP_DISMISS_IDLE_TICKS then
		dismiss_popup()
	end
end

-- Draws list row `i` (0-based, within the visible window) for `row` - one of the flat, normalised
-- listRows entries, or nil past the end of the list.
-- `isCursor` controls only the '> '/'  ' marker column, never the colour:
-- active state and cursor state are deliberately on separate channels (see
-- docs/full-functionality-plan.md), so there is no combined case to special-case here - a row that
-- is both simply gets ROW_ACTIVE's colours with a '> ' prefix, which reads correctly with nothing
-- extra written for it.
--
-- Every row - including a past-the-end blank one - draws at the SAME x and maxWidth (ROW_X,
-- ROW_MAXW), confirmed on hardware to make Write Text's background fill the whole box (see
-- docs/config-lua-history.md#settled-facts-max-width-and-the-write-text-background-box), so every
-- row is self-clearing: no erase rect, ever, on this screen. Indentation is two literal leading
-- spaces in the string, placed AFTER the marker column, never a change to x - that is what keeps
-- every row's background box identical (so highlight bars line up) and the '>' pinned to one
-- character position regardless of row kind.
function draw_list_row(i, row, isCursor)
	local y = ROW_Y0 + ROW_PITCH * i
	local id = 'row' .. i

	if row == nil then
		local c = ROW_COLORS[ROW_PATCH]
		draw_text(id, '', ROW_X, y, ROW_MAXW, ALIGN_LEFT, SIZE_SMALL, c[1], c[2], c[3], c[4], c[5], c[6])
		return
	end

	local isActive = row.isPatch and row.setIndex == activeSetIndex and row.patchIndex == activePatchIndex
	local state = ROW_PATCH
	if isActive then state = ROW_ACTIVE
	elseif not row.isPatch then state = ROW_HEADER
	end
	local c = ROW_COLORS[state]
	local marker = isCursor and '> ' or '  '
	local indent = row.isPatch and '  ' or ''
	draw_text(id, marker .. indent .. row.label, ROW_X, y, ROW_MAXW, ALIGN_LEFT, SIZE_SMALL,
		c[1], c[2], c[3], c[4], c[5], c[6])
end

-- Finds the flat, 0-based listRows index of the currently ACTIVE patch (the one MainStage has
-- loaded - activeSetIndex/activePatchIndex), or 0 if none matches (e.g. before the first real patch
-- selection). Used both to keep cursorIndex tracking the active patch in Phase 1
-- (controller_select_patch) and to find where the NEXT patch search should start
-- (next_line_text()).
function find_active_row_index()
	for i = 1, #listRows do
		local row = listRows[i]
		if row.isPatch and row.setIndex == activeSetIndex and row.patchIndex == activePatchIndex then
			return i - 1
		end
	end
	return 0
end

-- The ACTIVE patch's 1-based ordinal position among patches in its OWN set (activeSetIndex), and
-- that set's total patch count - 'patch 3 of 7 in this song', for the zoom screen's zpos line (see
-- paint_zoom_screen()). Counts only listRows entries with isPatch true AND setIndex ==
-- activeSetIndex, in listRows order, which is the same order MainStage's own patchlist uses within
-- a set - so this is a real 'position in the setlist', not a derived index. Returns 0, 0 if
-- activeSetIndex has no patches (listRows empty, or a state before the first real patch selection),
-- matching the graceful '0/0' this replaced.
function zoom_position_in_set()
	local pos, total = 0, 0
	for i = 1, #listRows do
		local row = listRows[i]
		if row.isPatch and row.setIndex == activeSetIndex then
			total = total + 1
			if row.patchIndex == activePatchIndex then pos = total end
		end
	end
	return pos, total
end

-- Finds the label of the nearest set header at or before cursorIndex, for the context bar. Phase
-- 1's cursor always sits on a patch row (it tracks the active patch - see controller_select_patch),
-- so this always finds a real header unless the list itself is empty.
function cursor_set_label()
	for i = cursorIndex + 1, 1, -1 do
		local row = listRows[i]
		if row and not row.isPatch then return row.label end
	end
	return ''
end

-- 'concert - set': the context bar's content. A plain ASCII hyphen, NOT a middle dot - the SLMK2
-- font only covers 0x20-0x80 (see append_text), so a middle dot would render as two spaces. See
-- docs/config-lua-history.md#typography-substitutions-non-ascii-glyphs.
function ctx_text()
	return currentConcert .. ' - ' .. cursor_set_label()
end

-- The context bar: y=2, dim grey, replacing the old per-set header. In a continuous list you
-- routinely scroll past a set header and lose track of which set you are in - this shows it in one
-- line, and redraws only when its CONTENT changes, for free, via the same per-region memoization
-- every other draw uses here (which is exactly "only when the cursor crosses into a different set",
-- since that is the only thing that can change cursor_set_label()'s result while browsing within a
-- set).
function draw_ctx()
	draw_text('ctx', ctx_text(), ROW_X, 2, ROW_MAXW, ALIGN_LEFT, SIZE_SMALL, 120, 120, 120, 0, 0, 0)
end

-- Draws the list screen's current model, memoized per region - repeat calls with nothing changed
-- queue nothing. No trailing sacrificial here - both update_screen and paint_screen add it
-- themselves, after calling this, via queue_sacrificial_redraw() (see that function for why it now
-- covers both paths). Every list-mode draw call passes ALIGN_LEFT (draw_ctx() and draw_list_row(),
-- including the blank past-end-of-list row) - the single-line ctx bar replaced an older two-line
-- header with a right-aligned n/N counter, which no longer exists in this codebase. If a
-- right-aligned counter is ever reported as visible on hardware, suspect stale content from an
-- unreliable mode-switch erase (see
-- docs/config-lua-history.md#fix-5-audit-the-first-switch-anomaly) before assuming one needs to be
-- added here.
function paint_list_screen()
	draw_ctx()
	for i = 0, ROW_COUNT - 1 do
		local row = listRows[scrollOffset + i + 1]
		local isCursor = (scrollOffset + i == cursorIndex)
		draw_list_row(i, row, isCursor)
	end
end

-- Truncates `text` to at most `maxChars` characters, cutting to maxChars - 3 and appending '...'
-- (plain ASCII full stops - the SLMK2 font only covers 0x20-0x80, see append_text) when it doesn't
-- fit. Used instead of the SL88's own Max Width truncation, which is confirmed broken at SIZE_BIG
-- (see BIG_MAX_CHARS's comment above) - both the patch name and the set name are truncated here in
-- the script and drawn with maxWidth=0.
function truncate_text(text, maxChars)
	text = text or ''
	if #text <= maxChars then
		return text
	end
	return text:sub(1, maxChars - 3) .. '...'
end

-- Write Text's opaque background fills the MAX WIDTH BOX, not the glyph run - so at maxWidth=0
-- ('print it all') that box is only as wide as the glyphs actually drawn, and a shorter string
-- can't overwrite what a longer one painted before it. DO NOT 'fix' this by padding the string with
-- spaces to a constant character count - that was tried and fails for two independent reasons
-- (proportional font; padding is symmetric in characters, not pixels, so it also breaks
-- ALIGN_CENTER). See docs/config-lua-history.md#rejected-approaches. The real fix is an explicit
-- erase rect, below.

-- Draws `text` preceded by an explicit black erase rect spanning its full band, sized independently
-- of the string's glyph width - the real fix for the stale-tail/off-centre bug in the comment
-- above. Memoized as ONE region under `id`, using an id..':rect'/id..':text' coalescing-key split
-- (base_region_id() already knows how to unwind it for drop_queued_display), so an unchanged name
-- queues NOTHING and a changed name always queues both halves together, in order. bg is always
-- black to match the erase rect's fill.
--
-- The rect and text are two SEPARATE queue_message() calls and therefore two separate flushes under
-- flush_pending's one-display-message-per-tick pacing (see FLUSH_SOON_MS/displayFlushReady) - do
-- NOT bundle them into one flush. Two display messages back-to-back in one flush is exactly the
-- pattern that dropped alternating rows on hardware (rule 5 in the SIX RULES banner), and they
-- would not fit anyway: a 21-byte rect plus a max-length Write Text plus the Identification Query
-- flush_pending always reserves room for exceeds FLUSH_BUDGET on its own. Accepted cost: one extra
-- message and a brief visible blank band per name change - the price of maxWidth=0, itself required
-- because Max Width truncation is broken at SIZE_BIG. `x`/`align` as given are used verbatim for
-- ALIGN_LEFT/ALIGN_RIGHT callers. For ALIGN_CENTER, `x` is IGNORED and recomputed here instead -
-- see CHAR_WIDTH_BIG's comment above for why: maxWidth=0 gives the device's own ALIGN_CENTER no
-- area to centre within, so the centred X is estimated in Lua and drawn ALIGN_LEFT, the one
-- deterministic choice at maxWidth=0. The memo tuple below intentionally excludes x/align - both
-- are pure functions of `text`/`size` here (either the caller's fixed values, or the deterministic
-- estimate), so text+colour alone is still sufficient to detect 'nothing changed'.
function draw_text_with_erase(id, text, x, y, align, size, fr, fg, fb, eraseX, eraseY, eraseW, eraseH)
	local t = { text, fr, fg, fb }
	if tuple_equal(drawn[id], t, #t) then return end
	drawn[id] = t
	queue_message(msg_draw_rect(eraseX, eraseY, eraseW, eraseH, 0, 0, 0), id .. ':rect')
	local drawX, drawAlign = x, align
	if align == ALIGN_CENTER then
		local estWidth = estimate_text_width_px(text, size)
		drawX = math.floor((SCREEN_WIDTH - estWidth) / 2)
		if drawX < eraseX then drawX = eraseX end
		drawAlign = ALIGN_LEFT
	end
	queue_message(msg_write_text(text, drawX, y, 0, drawAlign, size, fr, fg, fb, 0, 0, 0), id .. ':text')
end

-- 'NEXT' line for the zoom screen: the next listRows entry after the ACTIVE patch with isPatch
-- true, skipping set headers - i.e. what you are about to change to. The prompt word itself carries
-- whether that patch starts a new song (rather than trying to also fit the set's name on the line),
-- since a song boundary matters more mid-performance than the destination set's name. Returns the
-- no-next form at the end of the concert.
function next_line_text()
	local activeIndex = find_active_row_index()
	for i = activeIndex + 2, #listRows do
		local row = listRows[i]
		if row.isPatch then
			local word = (row.setIndex ~= activeSetIndex) and 'NEXT SONG' or 'NEXT'
			return word .. '  ' .. row.label
		end
	end
	-- End of the concert: no next patch. NOT an em dash - the SLMK2 font range is 0x20-0x80 (see
	-- append_text) - a plain ASCII substitute instead. See
	-- docs/config-lua-history.md#typography-substitutions-non-ascii-glyphs.
	return 'NEXT  --'
end

-- Draws the zoom screen's current model, memoized per region. Shows the ACTIVE patch, not the
-- cursor - 'what am I playing right now' - plus, on znext, what you are about to change to. Single
-- truncated line, not two wrapped lines - wrapping was tried and left stale text on the second line
-- (see docs/config-lua-history.md#max-width-truncation-broken-at-size_big).
--
-- zname and zset both truncate themselves via truncate_text() and draw through
-- draw_text_with_erase() (maxWidth=0) - Max Width truncation is CONFIRMED broken at SIZE_BIG and
-- untested at SIZE_MEDIUM (zset's size), so neither trusts it. znext always draws SIZE_SMALL,
-- self-clearing, at a real maxWidth, unconditionally. Layout (docs/full-functionality-plan.md):
-- zcnc y=12, zset y=44, zname y=100, znext y=170, zpos y=210 - bands 12-33 / 44-71 / 100-133 /
-- 170-191 / 210-231, all non-overlapping. Retune together with ROW_Y0-style constants if the layout
-- ever moves again.
function paint_zoom_screen()
	draw_text('zcnc', currentConcert, 8, 12, 304, ALIGN_CENTER, SIZE_SMALL, 120, 120, 120, 0, 0, 0)

	-- zset uses maxWidth=0 plus an explicit erase rect: Max Width truncation is confirmed broken at
	-- SIZE_BIG and untested at SIZE_MEDIUM (zset's size). If hardware ever confirms it works at
	-- SIZE_MEDIUM, draw_text() at a real maxWidth would halve this to 1 message and drop the flicker.
	draw_text_with_erase('zset', truncate_text(setName, MEDIUM_MAX_CHARS),
		8, 44, ALIGN_CENTER, SIZE_MEDIUM, 110, 170, 230,
		0, 44, SCREEN_WIDTH, 27)

	draw_text_with_erase('zname', truncate_text(patchName, BIG_MAX_CHARS),
		8, 100, ALIGN_CENTER, SIZE_BIG, 255, 255, 255,
		0, 100, SCREEN_WIDTH, 33)

	-- SIZE_SMALL + trusted Max Width, unconditionally - no truncate_text(), no erase rect, unlike
	-- zname/zset above: SIZE_SMALL is the one regime list rows already trust Max Width in, so it needs
	-- no hardware check first. One queued message instead of two.
	draw_text('znext', next_line_text(), 8, 170, SCREEN_WIDTH - 16, ALIGN_CENTER, SIZE_SMALL,
		80, 200, 120, 0, 0, 0)

	-- n/N: the ACTIVE patch's ordinal position among patches in its OWN set - 'patch 3 of 7 in this
	-- song', matching what the zoom screen actually shows (the active set/patch, not the cursor - a
	-- flat position across ALL listRows, 'row 41 of 98', does not answer the question this counter
	-- exists to answer). See zoom_position_in_set().
	local n, total = zoom_position_in_set()
	draw_text('zpos', n .. '/' .. total, 8, 210, 304, ALIGN_CENTER, SIZE_SMALL, 120, 120, 120, 0, 0, 0)
end

-- Ordinary content-driven redraw: draws the current model, memoized per region, and queues NOTHING
-- beyond whatever actually changed (2 messages for a patch change within a set, 9 for a set change,
-- 0 if nothing differs - see docs/mainstage-integration.md's redraw cost figures) PLUS the trailing
-- sacrificial redraw below when anything real was queued - see queue_sacrificial_redraw()'s comment
-- for why this MUST run here too, not only from paint_screen's full repaint.
--
-- Does NOT call drop_queued_display() at the top - per-region coalescing in queue_message()
-- supersedes a stale queued region in place, so nothing needs to be thrown away first. Do not
-- reintroduce a "drop everything, then re-queue" step here; it starves rows under rapid patch
-- changes (see queue_message's coalescing comment).
function update_screen()
	-- 3-way dispatch, matching paint_screen's - a content change (patch/set change from MainStage) can
	-- land while displayMode=='popup' and must redraw the popup's own content, not incorrectly paint
	-- list/zoom underneath a mode that's still supposed to be showing.
	local before = queuedDisplayOps
	if displayMode == 'popup' then
		paint_popup_screen()
	elseif displayMode == 'zoom' then
		paint_zoom_screen()
	else
		paint_list_screen()
	end
	if queuedDisplayOps > before then
		queue_sacrificial_redraw()
	end
	lastPaintedPatch = patchName
	lastPaintTick = idleTicks
	print('[sllink] update queued (' .. #pendingMessages .. ' msgs) mode=' .. displayMode ..
		' "' .. patchName .. '"')
end

-- Undoes queue_message's id..':rect' / id..':text' split (see draw_row) so drop_queued_display can
-- find its way back to the single drawn[] memo entry both halves share, regardless of which of the
-- two coalescing keys a given queued message actually carries. Plain ids (no backing rect in play)
-- pass through unchanged.
function base_region_id(id)
	return id:match('^(.*):rect$') or id:match('^(.*):text$') or id
end

-- Drops display messages still sitting in the queue. Used only where the queue's content is
-- genuinely garbage, not merely stale-but-wanted - see set_display_mode, its one remaining caller:
-- switching modes vacates the whole screen, so anything still queued for the outgoing mode cannot
-- be coalesced into anything the new mode will ever draw. Protocol messages (identification,
-- logout, ...) are preserved.
--
-- MUST undo the memo for exactly the id(s) it discards (drawn[base_region_id(...)] = nil), so the
-- next paint re-queues them. draw_text/draw_rect record drawn[id] the moment they QUEUE a message,
-- not when it is actually sent - without this undo, a message discarded here before it ever goes
-- out leaves drawn[id] permanently claiming the region was painted, and the memo and the physical
-- screen diverge for good. Do not reintroduce 'update the memo at queue time' without also undoing
-- it here on drop. See
-- docs/config-lua-history.md#drop_queued_display-and-the-memo-vs-screen-divergence-bug.
function drop_queued_display()
	local keep = {}
	for i = 1, #pendingMessages do
		local m = pendingMessages[i]
		if m[8] ~= IT_DISPLAY then
			keep[#keep + 1] = m
		elseif m.regionId then
			drawn[base_region_id(m.regionId)] = nil
		end
	end
	pendingMessages = keep
end

-- TRAILING SACRIFICIAL REDRAW, shared by paint_screen, update_screen AND set_display_mode - all
-- three MUST call this after queuing real content.
--
-- Empirically the FINAL flush of a repaint never takes effect: whichever display message ends up
-- last is silently lost, regardless of content, size, or what it's bundled with - swapping the draw
-- order just moves the loss to whatever is now last. See
-- docs/config-lua-history.md#the-trailing-sacrificial-redraw. So end any real screen update with a
-- harmless duplicate: re-drawing the concert line is idempotent, so it costs one extra message and
-- is safe to lose, while everything that matters now has something following it. Every caller gates
-- this on having actually queued something real - an all-memoized no-op call has no 'last real
-- message' that needs a harmless successor.
--
-- MUST build and queue the message DIRECTLY, bypassing draw_text(), and with NO regionId. A nil
-- regionId always appends (see queue_message) - routing this through draw_text('ctx', ...) would
-- instead hand it the SAME regionId as the real ctx/zcnc draw earlier in this same paint's queue
-- and coalesce into that entry, collapsing the one thing this mechanism must guarantee (a
-- disposable duplicate strictly AFTER everything real).
function queue_sacrificial_redraw()
	if displayMode == 'zoom' then
		queue_message(msg_write_text(currentConcert, 8, 12, 304, ALIGN_CENTER, SIZE_SMALL,
			120, 120, 120, 0, 0, 0))
	else
		queue_message(msg_write_text(ctx_text(), ROW_X, 2, ROW_MAXW, ALIGN_LEFT, SIZE_SMALL,
			120, 120, 120, 0, 0, 0))
	end
end

-- FULL repaint: draws everything for the current mode, relying on the caller having invalidated
-- first (handle_login, handle_restart, and the self-heal branch in handle_sl_frame all call
-- invalidate_all() before this) so every region actually resends rather than being skipped as
-- unchanged. Ordinary content-driven updates (a patch/set change from MainStage) go through
-- update_screen() instead, which also ends with queue_sacrificial_redraw() - see that function's
-- comment for why both paths need it. Does NOT call drop_queued_display() at the top - see
-- update_screen's comment on why that's unnecessary once invalidate_all() has run.
--
-- The SL88 keeps no display state across Standby, so this is also what a Restart triggers.
function paint_screen()
	-- NO Clear Screen here (rule 3 in the banner) - Write Text "completely overwrites any existing
	-- content on the screen pixels within the area where the text is printed"
	-- (sl-link/docs/display-messages.md), so redrawing the same regions is self-cleaning. See
	-- docs/config-lua-history.md#the-clear-screen-ban-and-its-lift for what this ban was protecting
	-- against.

	-- 3-way dispatch: if an ordinary content-driven repaint lands while a popup happens to be showing
	-- (e.g. a patch change arriving mid-popup), this must redraw the POPUP's own content again, not
	-- incorrectly repaint list/zoom underneath a mode that's still supposed to be showing.
	local before = queuedDisplayOps
	if displayMode == 'popup' then
		paint_popup_screen()
	elseif displayMode == 'zoom' then
		paint_zoom_screen()
	else
		paint_list_screen()
	end

	-- Trailing sacrificial redraw - see queue_sacrificial_redraw()'s comment.
	if queuedDisplayOps > before then
		queue_sacrificial_redraw()
	end

	lastPaintedPatch = patchName
	lastPaintTick = idleTicks
	print('[sllink] paint queued (' .. #pendingMessages .. ' msgs) mode=' .. displayMode ..
		' "' .. patchName .. '"')
end

-- Mode switching. Wired to the Zoom button (BID_ZOOM, confirmed on hardware - see
-- handle_zoom_button).
--
-- The ONE place in the file that sends Clear Screen (rule 3 in the banner bans it everywhere else).
-- MUST stay queued as its own discrete message with no regionId - never coalesced, never bundled
-- into an array with a Write Text - and paired with the SETTLE guard (displaySettleTicks). See
-- docs/config-lua-history.md#the-clear-screen-ban-and-its-lift for why, and the documented fallback
-- (a full-screen black msg_draw_rect) if remnants or dropped lines return on hardware.
--
-- An unexplained 'first switch differs from later ones' anomaly was chased here and not root-caused
-- - see docs/config-lua-history.md#fix-5-audit-the-first-switch-anomaly before assuming this
-- function branches correctly on 'is this the first switch' (it doesn't - nothing here does).
function set_display_mode(mode)
	if mode ~= 'list' and mode ~= 'zoom' and mode ~= 'popup' then return end
	displayMode = mode
	drop_queued_display()
	invalidate_all()
	-- MUST queue the Clear Screen TWICE, as two SEPARATE messages with no regionId (queue_message
	-- never coalesces without one), each earning its own flush. Do not collapse this back to one
	-- queue_message() call. flush_pending always appends the Identification Query to whatever it
	-- emits, so a single Clear Screen goes out bundled with the query in one MIDI array - confirmed on
	-- hardware to be an unreliable shape (only [display, query] alone, or [display] first, ever
	-- reliably painted; see docs/config-lua-history.md#the-double-clear-screen). It is idempotent, and
	-- a dropped copy costs nothing but one extra flush. flush_pending's settle-guard
	-- (displaySettleTicks) resets on EVERY Clear Screen it emits, so the settle window still lands
	-- after the LAST one.
	queue_message(msg_clear_screen(0, 0, 0))
	queue_message(msg_clear_screen(0, 0, 0))
	local before = queuedDisplayOps
	if mode == 'popup' then
		paint_popup_screen()
	elseif mode == 'zoom' then
		paint_zoom_screen() -- redundant with the full-screen erase above, but each name draw erases its own band anyway
	else
		paint_list_screen()
	end
	-- MUST end with the same trailing sacrificial redraw paint_screen/ update_screen use - see
	-- queue_sacrificial_redraw()'s comment; without it the LAST message of a mode switch (zpos in
	-- zoom, or the last visible row in list) is exposed to the same "final flush is silently dropped"
	-- finding. Same gate: only queue it if real content was queued.
	if queuedDisplayOps > before then
		queue_sacrificial_redraw()
	end
	lastPaintedPatch = patchName
	lastPaintTick = idleTicks
	-- Always has real content queued here (Clear Screen plus a guaranteed-non-empty repaint, since
	-- invalidate_all() above forces every region to resend) - see request_quick_rearm's comment.
	request_quick_rearm()
	print('[sllink] display mode -> ' .. mode)
end


-- MARK: - Session

function start_identification()
	state = STATE_IDENTIFYING
	queue_message(msg_identification_request())
	print('[sllink] -> Identification Request as (' ..
		string.format('%02X %02X', SL_HOST_ID, instanceID) .. ') on outport=' .. SL_PORT)
end

function handle_identification_approved()
	state = STATE_LISTED
	-- Cleanly cancels any pending reidentify-wait: this instanceID is now confirmed good, so a LATER
	-- rejection (a fresh re-init down the line) should get the full retry budget again, not whatever
	-- was left over.
	reidentifyRetriesLeft = MAX_SAME_ID_RETRIES
	print('[sllink] <- IDENTIFICATION APPROVED as ' ..
		string.format('%02X %02X', SL_HOST_ID, instanceID) ..
		' - now in the SL88 APP list; select it there to activate')
end

-- Reason 0x00 = DeviceID taken/reserved - usually OUR OWN previous incarnation's still-live
-- registration after a MainStage-driven re-init (see REIDENTIFY_WAIT_MS's comment for why bumping
-- the id immediately would be wrong here). Wait out REIDENTIFY_WAIT_MS and retry the SAME id first;
-- only fall back to bumping the instance byte after MAX_SAME_ID_RETRIES failed retries. See
-- docs/config-lua-history.md#identification-and-instance-id-collisions.
function handle_identification_rejected(reason)
	print('[sllink] <- IDENTIFICATION REJECTED (reason ' ..
		string.format('%02X', reason or 0) .. ') for instance ' ..
		string.format('%02X', instanceID))

	if reidentifyRetriesLeft > 0 then
		reidentifyRetriesLeft = reidentifyRetriesLeft - 1
		state = STATE_REIDENTIFY_WAIT
		-- Not rearm_timer() - this must WIN over the FLUSH_SOON_MS/KEEPALIVE_MS that inbound traffic
		-- would otherwise re-arm it to (see rearm_timer's STATE_REIDENTIFY_WAIT guard, which is what
		-- stops that overwrite from happening on every subsequent inbound frame during the wait).
		settriggertimer(REIDENTIFY_WAIT_MS)
		-- This call genuinely arms a fresh one-shot (unlike controller_timer_trigger's own
		-- top-of-function call - see timerPending's declaration), so timerPending must reflect that:
		-- keeps rearm_timer's gating honest once the wait ends and normal inbound traffic resumes calling
		-- it.
		timerPending = true
		-- Not KEEPALIVE_MS: request_quick_rearm() must never shorten THIS wait (see its own
		-- STATE_REIDENTIFY_WAIT guard, which is belt-and-suspenders for the same reason - this value
		-- alone already keeps its `timerArmedInterval == KEEPALIVE_MS` check from matching).
		timerArmedInterval = REIDENTIFY_WAIT_MS
		print('[sllink] re-identify retry ' ..
			(MAX_SAME_ID_RETRIES - reidentifyRetriesLeft) .. '/' .. MAX_SAME_ID_RETRIES ..
			' as (' .. string.format('%02X %02X', SL_HOST_ID, instanceID) .. ')')
		return
	end

	instanceID = instanceID + 1
	if instanceID > 0x7E then instanceID = 0x10 end
	reidentifyRetriesLeft = MAX_SAME_ID_RETRIES
	print('[sllink] bumping instance to ' ..
		string.format('%02X %02X', SL_HOST_ID, instanceID) .. ' after ' ..
		MAX_SAME_ID_RETRIES .. ' failed retries')
	start_identification()
end

function handle_login()
	state = STATE_ACTIVE
	print('[sllink] <- LOGIN - session active')
	-- Fresh/re-confirmed session: make sure everything is resent rather than trusting our memo, which
	-- may record draws sent before the keyboard had actually identified/confirmed us.
	invalidate_all()
	paint_screen()
end

function handle_standby()
	state = STATE_STANDBY
	print('[sllink] <- STANDBY')
end

function handle_restart()
	state = STATE_ACTIVE
	print('[sllink] <- RESTART - repainting (SL88 retains no screen state)')
	invalidate_all() -- SLLinkDisplay.swift: the SLMK2 forgets everything across Standby; without this
		-- every id's memo would wrongly think its last content is still on screen and skip resending it.
	paint_screen()
end

function handle_logout_request()
	print('[sllink] <- LOGOUT REQUEST - confirming')
	queue_message(msg_system(SYS_LOGOUT_CONFIRMATION))
	state = STATE_IDLE
end

function send_keepalive()
	queue_message(msg_system(SYS_DEVICE_NOTIFICATION))
end

-- True if a Device Notification is already queued and not yet flushed. See
-- controller_timer_trigger's unconditional-keepalive comment for why this guard exists: protocol
-- messages are never coalesced by queue_message, so calling send_keepalive() on every tick without
-- this check would pile up a duplicate behind an already-queued-but-undrained keepalive.
function has_keepalive_queued()
	for i = 1, #pendingMessages do
		local m = pendingMessages[i]
		if m[8] == IT_SYSTEM and m[9] == SYS_DEVICE_NOTIFICATION then
			return true
		end
	end
	return false
end

-- MARK: - Inbound decoding
--
-- controller_midi_in receives the SL88's traffic, SysEx included (the VAX77 reference matches F0 in
-- its own controller_midi_in the same way).

function is_our_sl_frame(e)
	return e[0] == 0xF0
		and e[1] == 0x00 and e[2] == 0x20 and e[3] == 0x1A and e[4] == 0x16
		and e[5] == SL_HOST_ID and e[6] == instanceID
end

function handle_sl_frame(e)
	local itemType = e[7]
	local func = e[8]

	if itemType == IT_IDENTIFICATION then
		if func == ID_APPROVED then
			handle_identification_approved()
		elseif func == ID_REJECTED then
			handle_identification_rejected(e[9])
		elseif func == ID_QUERY then
			-- The reply to our own keepalive query. Receiving it is what re-arms the timer, but its result
			-- byte is also the most reliable session signal we get - far more dependable than waiting for a
			-- LOGIN CONFIRMATION, which the keyboard only sends on a *fresh* login and skips entirely if it
			-- still remembers us.
			if e[9] == 0x00 then
				print('[sllink] <- query: not identified; re-identifying')
				state = STATE_IDLE
				start_identification()
			else
				-- Identified. Treat this as 'the session is up' regardless of whether we ever saw
				-- APPROVED/LOGIN, and make sure the screen actually reflects the current patch.
				if state == STATE_IDENTIFYING or state == STATE_LISTED then
					state = STATE_ACTIVE
				end
				if patchName ~= '' and not has_pending() then
					local stale = (lastPaintedPatch ~= patchName)
					local due = (idleTicks - lastPaintTick) >= REPAINT_EVERY_IDLE_TICKS
					if due then
						-- Memoization means an unchanged repaint would emit ZERO messages and heal nothing, defeating
						-- the entire point of this periodic repaint (the SL88 wipes its own screen on APP-list
						-- selection with no reliable signal for it) - force every region to resend.
						invalidate_all()
					end
					if stale or due then paint_screen() end
				end
			end
		end
	elseif itemType == IT_SYSTEM then
		if func == SYS_LOGIN_CONFIRMATION or func == SYS_LOGIN_RECALL then
			handle_login()
		elseif func == SYS_STANDBY then
			handle_standby()
		elseif func == SYS_RESTART then
			handle_restart()
		elseif func == SYS_LOGOUT_REQUEST then
			handle_logout_request()
		end
	elseif itemType == IT_BUTTON then
		local bid = func
		local pressKind = e[9]
		local ccButton = BUTTON_CC[bid]
		if bid == BID_ZOOM then
			handle_zoom_button(pressKind)
		elseif ccButton ~= nil and (pressKind == PRESS_SHORT or pressKind == PRESS_LONG) then
			local control = (pressKind == PRESS_SHORT) and ccButton.short or ccButton.long
			queue_momentary_cc(control)
		else
			local kind = (pressKind == PRESS_SHORT and 'SHORT') or (pressKind == PRESS_LONG and 'LONG')
				or tostring(pressKind)
			print('[sllink] <- BUTTON bid=' .. string.format('0x%02X', bid)
				.. ' event=' .. kind .. ' (unhandled) frame=' .. dump_event(e))
		end
	elseif itemType == IT_ENCODER then
		local eid = func
		local delta = e[9] - 0x40
		local control = ENCODER_CC[eid]
		if control ~= nil then
			local newValue = encoderValue[eid] + delta
			if newValue < 0 then newValue = 0 elseif newValue > 127 then newValue = 127 end
			encoderValue[eid] = newValue
			queue_cc(control, newValue)
			show_popup(eid)
		else
			print('[sllink] <- ENCODER eid=' .. string.format('0x%02X', eid)
				.. ' tick=' .. string.format('0x%02X', e[9])
				.. ' delta=' .. tostring(delta) .. ' (unhandled) frame=' .. dump_event(e))
		end
	else
		print('[sllink] <- unhandled itemType=' .. string.format('0x%02X', itemType)
			.. ' frame=' .. dump_event(e))
	end
end

-- SHORT toggles the display mode; LONG forces a full repaint of whichever mode is currently
-- showing. LONG must never be silently dropped - the project rule (see CLAUDE.md's demo-screen
-- interaction model: LONG_PRESSION is confirmed delivered on real hardware, and every button case
-- must give it a distinct effect or run the same action as SHORT) - so it gets its own, always-safe
-- effect: a manual on-demand version of the periodic self-heal repaint above (paint_screen() after
-- invalidate_all()), useful if the SL88's screen has drifted from what the script thinks it last
-- painted.
--
-- Popup interaction: the plain SHORT toggle ('list' <-> 'zoom') assumes displayMode is one of
-- exactly those two - false while a popup is showing, where it would compute newMode='zoom'
-- regardless of what was showing before the popup, ignoring popupPreviousMode and leaving
-- popupActive stale-true. So a Zoom-button SHORT while a popup is up must instead dismiss the popup
-- - dismiss_popup() already restores popupPreviousMode via set_display_mode. LONG needs no special
-- case: invalidate_all()+paint_screen() already redraws whatever displayMode currently is, popup
-- included, via paint_screen's 3-way dispatch.
function handle_zoom_button(pressKind)
	if pressKind == PRESS_LONG then
		print('[sllink] <- BUTTON zoom LONG - forcing full repaint of mode=' .. displayMode)
		invalidate_all()
		paint_screen()
		-- invalidate_all() above guarantees this repaint queues real content - see request_quick_rearm's
		-- comment.
		request_quick_rearm()
	elseif displayMode == 'popup' then
		print('[sllink] <- BUTTON zoom SHORT - dismissing popup (mode=popup)')
		dismiss_popup()
	else
		local newMode = (displayMode == 'zoom') and 'list' or 'zoom'
		print('[sllink] <- BUTTON zoom SHORT - toggling display mode -> ' .. newMode)
		set_display_mode(newMode)
	end
end

-- MARK: - MainStage callbacks

function controller_initialize(applicationName, deviceNewlyDetected)
	settriggertimer(KEEPALIVE_MS)
	-- This is the very first arm for a fresh script instance - nothing was outstanding before it, and
	-- this call genuinely arms a timer (unlike controller_timer_trigger's own top-of-function call),
	-- so timerPending must say so or the first rearm_timer() from inbound traffic would wrongly re-arm
	-- on top of it.
	timerPending = true
	timerArmedInterval = KEEPALIVE_MS
	state = STATE_IDLE
	instanceID = SL_INSTANCE_START
	reidentifyRetriesLeft = MAX_SAME_ID_RETRIES
	pendingMessages = {}
	pendingCC = {}
	pendingCCOrder = {}
	pendingReleases = {}
	encoderValue = {
		[EID_ZONE1] = 64, [EID_ZONE2] = 64, [EID_ZONE3] = 64, [EID_ZONE4] = 64,
		[EID_JOYSTICK] = 64, [EID_B] = 64,
	}
	displayMode = 'zoom' -- see the displayMode declaration above for why
	patchName, setName, currentConcert = '', '', ''
	activeSetIndex, activePatchIndex = 0, 0
	cursorIndex, scrollOffset = 0, 0
	listRows = {}
	invalidate_all()

	if applicationName ~= nil and applicationName ~= '' then
		APP_NAME = applicationName
	end

	print('[sllink] controller_initialize (app="' .. tostring(applicationName) .. '")')
	start_identification()
	return flush_pending()
end

-- MUST NOT send a Logout Request. MainStage tears this script down and re-initialises it repeatedly
-- (init -> finalize -> init -> ... within seconds - partly because the script is loaded once per
-- matched USB-MIDI interface). A Logout Request here actively removes the app from the SL88's APP
-- list on every one of those spurious teardowns. Staying quiet lets the entry survive a churn; if
-- the script really is going away for good, the keyboard's own ~5s keepalive timeout removes it
-- anyway. See docs/config-lua-history.md#controller_finalize-sends-no-logout-request.
function controller_finalize()
	print('[sllink] controller_finalize (no logout sent - see note)')
	pendingMessages = {}
	state = STATE_IDLE
	return nil
end

-- Periodic. Re-arms itself so it keeps firing for as long as the device stays selected. This is the
-- only clock the session has, so the keepalive cadence depends on it.
timerTicks = 0

function controller_timer_trigger()
	-- The one-shot has just fired, so nothing is outstanding any more - clear this BEFORE the
	-- settriggertimer call below, which (per the SESSION CLOCK note further down, established on
	-- hardware) does NOT actually re-arm anything when called from inside this function. Leaving
	-- timerPending false here is what is factually correct AND what lets the real re-arm -
	-- rearm_timer(), from the next inbound frame, almost always the reply to the Identification Query
	-- this function's own return flushes - go ahead instead of being gated out by a flag claiming a
	-- timer is already pending when none actually is.
	timerPending = false
	settriggertimer(KEEPALIVE_MS)
	timerTicks = timerTicks + 1

	-- Grant this tick's one-display-message permit (see displayFlushReady's declaration). Withhold it
	-- while a Clear Screen is still settling (displaySettleTicks), so the draw that follows one gets
	-- roughly two tick periods of quiet instead of one. Protocol messages and the trailing
	-- Identification Query are never gated by displayFlushReady, so the session clock keeps running
	-- through the settle regardless.
	if displaySettleTicks > 0 then
		displaySettleTicks = displaySettleTicks - 1
	else
		displayFlushReady = true
	end
	-- Only ticks that arrive at the full keepalive cadence count towards the periodic refresh; fast
	-- drain ticks must not.
	local draining = has_pending()
	if not draining then idleTicks = idleTicks + 1 end
	check_popup_dismiss()
	-- `tick=`/`pending=`/`draining=` here let a captured hardware log be read as 'N drain ticks
	-- elapsed while M messages went out' - pair against the `tick=` field flush_pending's own FLUSH
	-- print carries.
	print('[sllink] timer tick #' .. timerTicks .. ' (idle ' .. idleTicks .. ') state=' .. state ..
		' pending=' .. #pendingMessages .. ' draining=' .. tostring(draining))

	-- Announce unconditionally once an Identification Request has been sent, regardless of what we've
	-- observed back: if the keyboard still remembers us from a previous run it sends neither APPROVED
	-- nor LOGIN, so gating this on having seen APPROVED first stalls the state machine in IDENTIFYING
	-- with no keepalive going out - the entry ages out of the APP list after ~5s. The query reply is
	-- the reliable session signal (see handle_sl_frame's ID_QUERY branch), not APPROVED/LOGIN.
	if state == STATE_IDLE then
		start_identification()
	elseif state == STATE_REIDENTIFY_WAIT then
		-- This tick firing at all means REIDENTIFY_WAIT_MS actually elapsed (rearm_timer() refuses to
		-- shorten it while waiting - see there), so this is the retry, not an ordinary keepalive tick.
		-- Falling through to the send_keepalive() branch below would be wrong here: it would announce the
		-- still-rejected instanceID instead of retrying it.
		start_identification()
	else
		-- MUST send the keepalive UNCONDITIONALLY on every keepalive-cadence tick, even while display
		-- work is still queued - do not gate this on `not has_pending()`. A display message paces at one
		-- per tick (displayFlushReady), so a multi-message repaint can leave has_pending() true for
		-- several ticks in a row; gating the keepalive on an empty queue starves it for the whole
		-- repaint, an independent route to the same ~5s APP-list timeout rule 6 fixes. See
		-- docs/config-lua-history.md#the-unconditional-keepalive for the measurement that ruled out the
		-- alternative (bundling the keepalive into the same array as a Write Text, which the SL88
		-- discards).
		--
		-- Safe unconditionally because send_keepalive() queues a PROTOCOL message (itemType IT_SYSTEM,
		-- regionId nil), and flush_pending never gates non-display messages behind displayFlushReady -
		-- they jump ahead of any display backlog if necessary (flush_pending's scan-forward fix).
		-- has_keepalive_queued() guards against PILE-UP: protocol messages are deliberately never
		-- coalesced, so without this guard a keepalive queued-but-not-yet-flushed would get another one
		-- appended behind it on every subsequent tick, growing without bound.
		if not has_keepalive_queued() then
			send_keepalive()
		end
	end

	-- Also send an Identification Query. Its only purpose is to make the keyboard send something back:
	-- `settriggertimer` is a ONE-SHOT that cannot be re-armed from inside this callback (established
	-- on hardware, see the SESSION CLOCK note above controller_midi_in), so the only thing that keeps
	-- the clock running is inbound MIDI arriving at controller_midi_in. The query's reply is that
	-- inbound event, which re-arms the timer and schedules the next tick - a self-sustaining
	-- request/response heartbeat that does not depend on anyone playing. flush_pending appends the
	-- query itself and reserves budget for it.
	return flush_pending(true)
end

function dump_event(e)
	local parts = {}
	local i = 0
	while i < 48 do
		local b = e[i]
		if b == nil then break end
		parts[#parts + 1] = string.format('%02X', b)
		i = i + 1
	end
	return table.concat(parts, ' ')
end

-- SESSION CLOCK: `settriggertimer` is a ONE-SHOT that does NOT re-arm when called from inside
-- controller_timer_trigger - confirmed on hardware, that callback fires exactly once per script
-- instance no matter what. It DOES re-arm when called from here (controller_midi_in). Do not assume
-- controller_timer_trigger can free-run; it cannot.
--
-- So the heartbeat is: timer tick -> send keepalive + Identification Query -> keyboard replies ->
-- that reply lands here -> re-arm -> next tick. Without the query there is nothing to reply, the
-- chain stops after one tick, and the SL88 drops the host from its APP list after ~5s. See
-- docs/config-lua-history.md#settriggertimer-is-a-one-shot-and-does-not-self-renew-from-inside-the-tick-handler.
--
-- Re-arms the one-shot timer. Called at the END of controller_midi_in, after any queued output has
-- been drained, so the interval reflects what is still outstanding rather than what was outstanding
-- on entry.
--
-- MUST only actually call settriggertimer when timerPending is false (rule 6 in the banner):
-- controller_midi_in calls this on EVERY inbound MIDI event, including every note on/off, and
-- settriggertimer cancels-and-restarts whatever is pending on each call - an ungated call here
-- starves the clock while the user plays. See
-- docs/config-lua-history.md#rule-6-notes-starve-the-clock. A note arriving while a timer is
-- already pending leaves it alone and passes straight through untouched; the first inbound frame
-- after a tick fires (almost always the Identification Query's reply) is what chooses the next
-- interval.
function rearm_timer()
	if state == STATE_REIDENTIFY_WAIT then
		-- CRITICAL: rearm_timer() runs on EVERY inbound frame. The rejection handler sets the one-shot
		-- timer to REIDENTIFY_WAIT_MS to wait out the SL88's ~5s host timeout (see
		-- handle_identification_rejected) - if this function touched the timer here too, that wait would
		-- be overwritten with FLUSH_SOON_MS/KEEPALIVE_MS by the very next inbound frame, typically within
		-- milliseconds, and the wait would never actually happen. Leave the pending timer alone until the
		-- wait state ends.
		return
	end
	if timerPending then
		-- A one-shot is already outstanding; it will fire on its own. This is the notes-starve-the-clock
		-- fix - see this function's comment above.
		return
	end
	if has_pending() then
		settriggertimer(FLUSH_SOON_MS) -- still draining a repaint; come back soon
		timerArmedInterval = FLUSH_SOON_MS
	elseif popupActive then
		-- While the popup is showing and nothing is draining, arm the ~1s popup tick instead of the ~3s
		-- keepalive tick, so POPUP_DISMISS_IDLE_TICKS (an idleTicks count, not a literal duration)
		-- actually dismisses after ~1s. Only reached once has_pending() is false, so this never delays
		-- the popup's own draw burst - only the idle wait afterward, before dismissal.
		settriggertimer(POPUP_TICK_MS)
		timerArmedInterval = POPUP_TICK_MS
	else
		settriggertimer(KEEPALIVE_MS)
		timerArmedInterval = KEEPALIVE_MS
	end
	timerPending = true
end

-- If a one-shot is currently outstanding AND it was armed at either LONG interval (KEEPALIVE_MS or
-- POPUP_TICK_MS - matching both matters, see docs/config-lua-history.md#quick-rearm-2026-08-21 for
-- the responsiveness regression that motivated adding POPUP_TICK_MS here), shorten it to
-- FLUSH_SOON_MS instead of leaving newly-queued display work to wait out whatever is left. Call
-- ONCE per queueing burst - from controller_select_patch's update, set_display_mode, and the button
-- handlers - never from queue_message() itself, which would fire it many times over a single
-- repaint.
--
-- Shares rearm_timer's STATE_REIDENTIFY_WAIT guard: that wait must never be shortened (see
-- handle_identification_rejected).
function request_quick_rearm()
	if state == STATE_REIDENTIFY_WAIT then return end
	if timerPending and (timerArmedInterval == KEEPALIVE_MS or timerArmedInterval == POPUP_TICK_MS) then
		settriggertimer(FLUSH_SOON_MS)
		timerArmedInterval = FLUSH_SOON_MS
		print('[sllink] quick-rearm -> FLUSH_SOON_MS')
	end
end

function controller_midi_in(midiEvent, portName)
	if midiEvent[0] == 0xF0 then
		print('[sllink] <- SYSEX on port=' .. tostring(portName) .. ': ' .. dump_event(midiEvent))
	end

	if is_our_sl_frame(midiEvent) then
		-- Release any momentary CC presses queued LAST round before handling THIS frame, so a button
		-- press on this frame queues its own release for the round after, not this one - see
		-- queue_momentary_cc's comment for why the release can't just follow the press directly.
		if #pendingReleases > 0 then
			for i = 1, #pendingReleases do
				queue_cc(pendingReleases[i], 0)
			end
			pendingReleases = {}
		end

		handle_sl_frame(midiEvent)

		-- Phase 2 (every SL88 control emits its own CC): a batch queued by the release-drain above and/or
		-- this frame's own button/encoder event takes priority this round, mirroring the old Q1a spike's
		-- proven injection shape - return it ALONE, never call flush_pending, never dequeue
		-- pendingMessages and discard the result. Anything already queued for the SL88 (display/protocol
		-- traffic) is untouched and drains on a later flush; rearm_timer() below still runs
		-- unconditionally, so skipping the Identification Query this round does not stall the session
		-- clock (this inbound frame is itself the 'reply' the clock needs - see the SESSION CLOCK note
		-- above rearm_timer).
		if #pendingCCOrder > 0 then
			local out = flush_pending_cc()
			rearm_timer()
			return out
		end

		-- Protocol traffic, not music: swallow it, and use the opportunity to flush whatever the handler
		-- queued. Do NOT include the Identification Query while state == STATE_REIDENTIFY_WAIT:
		-- flush_pending(true) appends it unconditionally, and the SL88 would truthfully answer 'not
		-- identified' for an id it just rejected - which the ID_QUERY branch in handle_sl_frame treats as
		-- licence to re-identify right away, defeating the wait handle_identification_rejected just
		-- started.
		local out = flush_pending(state ~= STATE_REIDENTIFY_WAIT)
		rearm_timer()
		if out ~= nil then return out end
		return { midi = {} }
	end

	rearm_timer()

	if midiEvent[0] == 0xC0 then
		return { midi = {} } -- swallow Program Change (patchselector handles it)
	end

	-- Musical traffic must pass through untouched - never swallow it just to piggyback pending output,
	-- or notes will hang.
	return nil
end

-- Resolves a patchlist entry's label across the plausible field-name spellings MainStage might use
-- (docs/full-functionality-plan.md assumed .Label; an earlier version of this code assumed .Name;
-- neither alone was safe to trust).
function patch_label(entry)
	local candidates = { 'Label', 'Name', 'label', 'name', 'PatchName', 'patchname' }
	if type(entry) == 'table' then
		for _, key in ipairs(candidates) do
			local v = entry[key]
			if type(v) == 'string' and v ~= '' then return v end
		end
	end
	return tostring(entry)
end

-- Same idea for the fields the list model depends on (IsPatch/SetIndex/ PatchIndex): tries the
-- capitalised spelling (per docs/full-functionality-plan.md) then the all-lowercase one. Returns
-- nil (not false) when neither variant is present, so a genuinely-false IsPatch is distinguishable
-- from a missing key.
function patch_field(entry, field)
	if type(entry) ~= 'table' then return nil end
	local candidates = { field, field:lower() }
	for _, key in ipairs(candidates) do
		local v = entry[key]
		if v ~= nil then return v end
	end
	return nil
end

-- ARGUMENT HIERARCHY SHIFT: MainStage reuses this same callback for selections in Edit mode that
-- are NOT a patch - selecting a SET or the CONCERT there shifts the argument hierarchy up one
-- level, the selected thing arriving as patchname and its PARENT arriving as setname:
--   select a set:      patchname="2. Jacob & Sons / Joseph's Coat"  setname='Joseph key2'
--                       (setname is actually the CONCERT)
--   select the concert: patchname='Joseph key2'                    setname=''
-- controller_select_patch below trusts patchname/setname/concertname UNCONDITIONALLY - this is a
-- deliberate product decision (the user wants the selected value shown in the patch slot regardless
-- of hierarchy level), not an oversight. Do NOT reintroduce a 'refuse non-patch selections' guard
-- without checking with Jeroen first - see docs/config-lua-history.md#rejected-approaches.
function controller_select_patch(programchangeNumber, patchname, setname, concertname,
	patchlist, currentSetIndex, currentPatchIndex)
	local p, s, c = patchname or '', setname or '', concertname or ''

	-- CRASH-SAFETY GUARD ONLY (not the reverted 'refuse non-patch selections' behaviour above - see
	-- the ARGUMENT HIERARCHY SHIFT comment): MainStage's very first call happens before the concert
	-- has loaded, with patchlist nil/empty. There is nothing to browse yet, so bail out before
	-- touching displayed state rather than painting a blank/bogus name or letting the patchlist loop
	-- below run against nothing.
	if patchlist == nil or (type(patchlist) == 'table' and next(patchlist) == nil) then
		print('[sllink] controller_select_patch: patchlist not yet available - keeping last' ..
			' displayed patch "' .. patchName .. '"')
		return nil
	end

	-- MainStage calls this repeatedly with identical values (observed 5x for one patch change, partly
	-- because the script is loaded once per USB-MIDI interface). Repainting each time would waste a
	-- lot of MIDI - a full repaint is several messages - so only redraw on a real change.
	--
	-- Extended beyond the original name-only check to also compare currentSetIndex/currentPatchIndex:
	-- two identically named patches in different sets or positions must still move the highlight,
	-- which a name-only comparison would miss entirely.
	if p == patchName and s == setName and c == currentConcert
		and currentSetIndex == activeSetIndex and currentPatchIndex == activePatchIndex then
		return nil
	end

	patchName, setName, currentConcert = p, s, c
	activeSetIndex = currentSetIndex or activeSetIndex
	activePatchIndex = currentPatchIndex or activePatchIndex

	-- Rebuild the flat, interleaved list. ipairs(), NOT pairs(): the visual order of the continuous
	-- list IS patchlist's own array order (sets and patches interleaved as MainStage displays them -
	-- see docs/mainstage-integration.md), so this must preserve it, unlike the old per-set filter
	-- where scan order never mattered. Field names resolved via patch_label()/patch_field() above
	-- rather than trusted directly (that's what made the highlight bar blank on an earlier hardware
	-- run - see those functions' comments). patchIndex falls back to the array position when
	-- PatchIndex/patchindex is genuinely absent.
	listRows = {}
	if patchlist ~= nil then
		for i, entry in ipairs(patchlist) do
			if type(entry) == 'table' then
				local patchIndex = patch_field(entry, 'PatchIndex')
				listRows[#listRows + 1] = {
					label = patch_label(entry),
					isPatch = patch_field(entry, 'IsPatch') and true or false,
					setIndex = patch_field(entry, 'SetIndex'),
					patchIndex = patchIndex or (i - 1),
				}
			end
		end
	end

	-- Phase 1 has no independent browsing/cursor input yet (deferred to Phase 2's joystick handling) -
	-- the cursor simply tracks the active patch's position in the flat list.
	cursorIndex = find_active_row_index()

	-- currentConcert/setName logged alongside the existing fields so a blank concert line on the SL88
	-- screen can be told apart from a draw failure.
	print('[sllink] controller_select_patch: "' .. patchName .. '" (' .. #listRows .. ' rows total)' ..
		' concert="' .. currentConcert .. '" set="' .. setName .. '"' ..
		' activeSetIndex=' .. tostring(activeSetIndex) .. ' activePatchIndex=' .. tostring(activePatchIndex) ..
		' instance=' .. string.format('%02X', instanceID))

	-- Keep the visible window on the newly-set cursor - must run after listRows/cursorIndex are
	-- rebuilt above (clamp_scroll's upper bound depends on #listRows) and before the repaint below.
	clamp_scroll()

	if state == STATE_REIDENTIFY_WAIT then
		-- Don't queue or flush anything while waiting to retry identification (see
		-- handle_identification_rejected) - a flush here would send an Identification Query under an
		-- instanceID the SL88 just rejected, which would defeat the wait (see controller_midi_in's
		-- comment on the same hazard). The bookkeeping above (patchName/listRows/etc.) still ran, so once
		-- we are re-identified the ID_QUERY self-heal branch in handle_sl_frame finds lastPaintedPatch
		-- stale and repaints for real.
		return nil
	end

	-- Draw whenever MainStage says the patch changed, without waiting to be sure we are logged in: a
	-- LOGIN CONFIRMATION only arrives on a *fresh* login, and the keyboard harmlessly ignores drawing
	-- we are not entitled to do. The ID_QUERY branch repaints again once the session is confirmed.
	local opsBefore = queuedDisplayOps
	update_screen()
	if queuedDisplayOps > opsBefore then
		-- See request_quick_rearm's comment and docs/config-lua-history.md#quick-rearm-2026-08-21 - this
		-- is the exact call site the multi-second patch-change delay was measured against.
		request_quick_rearm()
	end
	return flush_pending(true)
end

-- MARK: - Device declaration

-- Items describe MIDI the SL88 **actually transmits**, captured live (notes, pitch bend,
-- modulation, second stick, sustain - all on LINK, none on CTRL). Ports use the short names for the
-- same reason outport does; see the banner at the top of this file.
function controller_info()
	return {
		model = 'SL',
		manufacturer = 'STUDIOLOGIC',

		-- usb_vendor_id = 38166,  -- 0x9516
		-- usb_product_id = 16441, -- 0x4039

		patchselector = true,

		items = {
			{name='Keyboard', label='SL88', objectType='Keyboard', midiType='Keyboard',
				startKey=21, numberKeys=88, midi={0x90,MIDI_Wildcard,MIDI_Wildcard},
				inport='LINK', outport='LINK'},

			{name='Pitch Bend', label='Pitch', objectType='Wheel', midi={0xE0,MIDI_MSB,MIDI_LSB},
				inport='LINK', outport='LINK'},
			{name='Modulation', label='Mod', objectType='Wheel', midi={0xB0,0x01,MIDI_LSB},
				inport='LINK', outport='LINK'},
			{name='Stick 2', label='Stick2', objectType='Wheel', midi={0xB0,0x10,MIDI_LSB},
				inport='LINK', outport='LINK'},

			{name='Sustain Pedal', label='Sustain', objectType='Sustain Pedal', midiType='Momentary',
				midi={0xB0,0x40,MIDI_LSB}, inport='LINK', outport='LINK'},
		}
	}
end
