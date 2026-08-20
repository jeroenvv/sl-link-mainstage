-- SL MainStage - MainStage MIDI Device Script for the Studiologic SL88 MK2
--
-- Speaks SL Link directly from Lua, with no helper application: identifies to
-- the keyboard, holds the session alive, and draws the current MainStage patch
-- on the SL88's screen.
--
-- Background is in docs/, not here:
--   docs/mainstage-device-scripts.md  writing MainStage Lua device scripts
--   docs/implementing-sl-link.md      the SL Link protocol, and where hardware
--                                     disagrees with the published spec
--   docs/mainstage-integration.md     status, and the historical record
-- SL-Link-Mainstage/SLLink/ is the Swift implementation every byte here is
-- checked against.
--
-- =========================================================================
-- FIVE RULES YOU MUST NOT BREAK. Each was found the hard way; each fails
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
--     exception, dated 2026-08-21, is set_display_mode's mode switch (see
--     that function's comment) - queued alone, never bundled with a Write
--     Text, paired with its own settle guard.
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
IT_BUTTON = 0x01 -- handled for BID_ZOOM (see handle_zoom_button); other BIDs are logged only
IT_ENCODER = 0x03 -- logged only; not otherwise handled
IT_DISPLAY = 0x04
IT_IDENTIFICATION = 0x7F

-- Button IDs (only what this script wires up so far)
BID_ZOOM = 0x10 -- confirmed on hardware; toggles set_display_mode('list'/'zoom')

-- Button press-event byte, e[9] of an IT_BUTTON frame
PRESS_SHORT = 0x01
PRESS_LONG = 0x02

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
-- SIZE_MEDIUM (0x01) is UNDOCUMENTED - the spec (docs/display-messages.md)
-- only gives pixel heights for small (21px) and big (33px). Assumed ~27px by
-- interpolation, but that is unverified: the zoom screen geometry below that
-- positions text around SIZE_MEDIUM rests on this estimate, not a
-- measurement. Recalibrate the y coordinates around 'zset' in
-- paint_zoom_screen() on hardware if the real glyph height differs.
SIZE_SMALL, SIZE_MEDIUM, SIZE_BIG = 0x00, 0x01, 0x02

-- The keyboard drops a host that goes quiet for ~5s; the app uses 3s.
KEEPALIVE_MS = 3000

-- docs/mainstage-integration.md "Open issues": MainStage tears the script
-- down and re-initialises it mid-session, which resets instanceID to
-- SL_INSTANCE_START - but the SL88 still holds the PREVIOUS incarnation's
-- registration under that id, because controller_finalize has no return
-- path to send a Logout Request. Bumping the instance byte immediately on
-- rejection "solves" it by registering as a DIFFERENT app, which is why the
-- user's APP-list selection was getting lost. Waiting comfortably longer
-- than the keyboard's ~5s host timeout (the KEEPALIVE_MS comment above) lets
-- that stale registration expire on its own, so retrying the SAME id
-- reclaims our own identity instead.
REIDENTIFY_WAIT_MS = 6000

-- Retries of the SAME instanceID (each separated by REIDENTIFY_WAIT_MS)
-- before handle_identification_rejected gives up and falls back to bumping
-- the instance byte, as before. Bounded so a GENUINE collision - e.g. the
-- other script instance loaded for the other USB-MIDI interface, which is
-- actually alive and will keep rejecting us - doesn't wait forever.
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

-- NOTES-STARVE-THE-CLOCK FIX (established on hardware 2026-08-20, rule 6 in
-- the banner above): true whenever a settriggertimer one-shot is currently
-- outstanding. controller_midi_in calls rearm_timer() on EVERY inbound MIDI
-- event, including every note on/off - while the user plays, notes arrive
-- far faster than the timer period, so an ungated settriggertimer() call
-- there just keeps cancelling and restarting the pending timer, and
-- controller_timer_trigger never fires. No tick means no keepalive Device
-- Notification, and the SL88 drops a host that goes quiet for ~5s - the
-- display dropping out WHILE PLAYING and recovering once playing stopped.
--
-- rearm_timer() now only calls settriggertimer when this is false, and sets
-- it true when it does. controller_timer_trigger() clears it at its own
-- start (the one-shot has just fired, so nothing is outstanding any more).
-- Every OTHER direct settriggertimer call must keep this flag honest too -
-- see controller_initialize, controller_timer_trigger's own top-of-function
-- call (which is a documented no-op on hardware - see the SESSION CLOCK
-- note above controller_midi_in - so it deliberately does NOT set this
-- true), and handle_identification_rejected's REIDENTIFY_WAIT_MS arm (which
-- genuinely does arm a timer, so it does set this true).
timerPending = false

-- Retries left for the CURRENT instanceID - see handle_identification_rejected.
-- Reset to MAX_SAME_ID_RETRIES whenever a FRESH instanceID is adopted
-- (controller_initialize, and the bump fallback itself) or an identification
-- succeeds; decremented on every same-id retry.
reidentifyRetriesLeft = MAX_SAME_ID_RETRIES

-- DEFECT A FIX (established on hardware 2026-08-19): controller_midi_in calls
-- flush_pending(true) on every inbound SL frame, and the Identification
-- Query's reply is itself one of those inbound frames - so before this flag
-- existed, a display item queued by flush_pending's own query reply flushed
-- again on that reply, whose reply flushed again, and so on: the queue
-- drained at the ~2ms round-trip rate, not at FLUSH_SOON_MS (100ms) as
-- intended. FLUSH_SOON_MS only ever paced the FALLBACK timer, never the
-- actual drain rate - it was inert.
--
-- CONSEQUENCE, confirmed on hardware: the SL88 cannot paint that fast and
-- silently drops a display message that arrives while it is still painting
-- the previous one. A 7-row calibration screen (one saturated colour per
-- row, since-removed diagnostic-only screen) rendered rows 0/2/4/6 and left
-- 1/3/5 black - every SECOND message lost, not a geometry bug (which would
-- leave only the last row visible). A 3-region zoom update (zset/zname/zpos,
-- flushed back to back as FLUSH #148/#149/#150) reliably lost the MIDDLE
-- one - the patch name, the one thing this screen exists to show.
--
-- Set TRUE once per timer tick, by controller_timer_trigger. flush_pending()
-- may dequeue and emit a display message (itemType IT_DISPLAY - this
-- includes queue_sacrificial_redraw's trailing duplicate, which has no
-- regionId but is still IT_DISPLAY) only while this is true, and clears it
-- the instant it does. Protocol messages (identification, keepalive, logout
-- - regionId nil, itemType IT_SYSTEM/IT_IDENTIFICATION) and the trailing
-- Identification Query are NOT gated by this flag: they go out on every
-- flush regardless, because the query's reply is the only thing that re-arms
-- the one-shot timer (see the SESSION CLOCK note above
-- controller_timer_trigger) - gating it too would stall the session clock
-- the moment any display work was queued.
--
-- Starts true so a display message queued before the very first timer tick
-- (or while the queue has been sitting idle/empty) can still go out on the
-- next available flush rather than waiting up to KEEPALIVE_MS for a tick
-- that has nothing to do with it.
displayFlushReady = true

-- CLEAR SCREEN SETTLE GUARD (2026-08-21, see set_display_mode's comment for
-- why Clear Screen is sent there at all). A full-screen clear plausibly takes
-- the panel longer to paint than an ordinary text line, and FLUSH_SOON_MS
-- dropping to 50ms (see that constant) leaves even less margin than before.
-- Set to 1 by flush_pending() the moment it emits a Clear Screen; decremented
-- by controller_timer_trigger, which withholds that tick's displayFlushReady
-- grant while this is nonzero - so the draw that follows a clear gets roughly
-- two tick periods of quiet instead of one. Protocol messages and the
-- trailing Identification Query are never gated by displayFlushReady at all,
-- so the session clock keeps running through the settle regardless.
displaySettleTicks = 0

-- Counts every display message queue_message() handles (append OR coalesced
-- replace-in-place). update_screen()/paint_screen() used to detect "did this
-- paint queue anything real" by comparing #pendingMessages before/after -
-- that broke once coalescing can replace an existing entry without changing
-- the queue's length, so they diff this counter instead.
queuedDisplayOps = 0

-- What MainStage has loaded (from controller_select_patch), and the model for
-- both display modes below. currentConcert already existed before this
-- feature and is reused rather than adding a parallel concertName.
-- The alternating-message-loss finding that used to keep 'list' parked
-- (a 7-row calibration screen showed rows 0/2/4/6 painted and 1/3/5 BLACK)
-- turned out to be the display-pacing bug fixed by displayFlushReady below,
-- not anything about the list screen itself - see docs/ for the record.
-- 'zoom' stays the default (unchanged on load/restart); the Zoom button
-- (BID_ZOOM, see handle_zoom_button) toggles to 'list' and back.
displayMode = 'zoom' -- or 'list'

activeSetIndex = 0
activePatchIndex = 0
currentConcert = ''
setName = ''
patchName = ''

-- cursorIndex is an index into listRows (0-based, matching the pattern used
-- throughout this file: listRows[cursorIndex + 1] is the Lua-array entry).
-- Phase 2 moves it independently of the active patch (joystick navigation);
-- Phase 1 has no wired input for that, so controller_select_patch simply
-- keeps it tracking whatever MainStage just loaded - see
-- find_active_row_index().
cursorIndex = 0
scrollOffset = 0

-- The flat, interleaved patchlist, normalised: { label, isPatch, setIndex,
-- patchIndex }, in the SAME order MainStage's own patchlist array uses - this
-- order IS the continuous list (sets and patches interleaved exactly as
-- MainStage displays them), so it is built with ipairs(), not pairs(), in
-- controller_select_patch: order is not just cosmetic here the way it was
-- for the old per-set filter.
listRows = {}

screenDirty = false

-- What the screen was last painted with, and when. Used to keep the display
-- self-healing: see the ID_QUERY handling in handle_sl_frame.
lastPaintedPatch = nil
lastPaintTick = -1

-- Repaint at least this often even when nothing changed, because the SL88
-- redraws its own screen when the user picks an app from the APP list and
-- there is no reliable signal for that (LOGIN CONFIRMATION only arrives on a
-- *fresh* login; if the keyboard still remembers us it never sends one).
--
-- Counted in IDLE ticks, not raw timer ticks. The tick rate is not constant -
-- it drops to FLUSH_SOON_MS while a repaint drains - so counting raw ticks
-- made "5 ticks" elapse in half a second mid-drain, which repainted, which
-- queued more work, which produced more fast ticks: a runaway repaint loop
-- that made the screen flicker and drop lines.
REPAINT_EVERY_IDLE_TICKS = 10
idleTicks = 0

-- MARK: - Outbound plumbing
--
-- A script can only send by returning MIDI from a callback, and MainStage
-- imposes a BYTE-LENGTH CEILING on what it will actually emit: measured on
-- hardware, 78 bytes render and 87 bytes render NOTHING AT ALL - the whole
-- array is discarded, not truncated. The SL Link spec itself has no such
-- limit (Write Text is `S(1)...S(N)` for arbitrary N, and Max Width truncates
-- visually in pixels - docs/display-messages.md), so this is purely a
-- MainStage constraint to work around.
--
-- Therefore: keep queued messages DISCRETE rather than pre-concatenated, and
-- emit only as many whole messages per flush as fit inside FLUSH_BUDGET.
-- Whatever is left over goes out on a following tick.
--
-- FLUSH_BUDGET sits below the 78 known to work, since the exact ceiling is
-- only bracketed to [78, 87) and there is nothing to gain from running close.
FLUSH_BUDGET = 72

-- Write Text's fixed wire overhead before the string itself: header+ids (7) +
-- itemType+func (2) + x/y/maxWidth (6) + align+size (2) + fg rgb (3) +
-- bg rgb (3) + 0x00 terminator (1) + F7 (1) = 25.
WRITE_TEXT_OVERHEAD = 25

-- While output is still queued, ask for the next tick quickly rather than
-- waiting a whole keepalive period, so a repaint converges in a fraction of a
-- second instead of one message every KEEPALIVE_MS.
--
-- DEFECT A FIX: before displayFlushReady existed, this constant was INERT -
-- it governed only the fallback timer's interval, while the actual drain
-- happened on every inbound SL frame (~2ms round trips), far faster than
-- this value. Now that flush_pending() gates display messages behind
-- displayFlushReady (set once per timer tick), this is genuinely the pace a
-- repaint drains at: one display message every FLUSH_SOON_MS.
--
-- RETUNED 2026-08-21: lowered from 100 to 50 to cut patch-change latency - a
-- hardware report found switching patches could take up to two seconds,
-- which combined with the 3s keepalive cadence to reach the SL88's ~5s host
-- timeout and drop the session (see flush_pending's DEFECT B FIX for the
-- other half of that fix). 100 was left in place when DEFECT A was fixed
-- specifically because retuning it was deferred to a later, deliberate
-- experiment - it was never itself measured as a floor, just an untested
-- holdover.
--
-- SWEEP PLAN, one value at a time, each verified on hardware before moving
-- on: 50 (current) -> 35 -> 25. Change only this one constant per hardware
-- run (see test-mainstage-script's "one variable per run" rule) and read
-- /tmp/lua.log's FLUSH/tick lines (both now carry the tick number and queue
-- depth - see their print statements) to confirm every expected region still
-- renders. 100 is the last KNOWN-GOOD value - if display messages start
-- going missing (a row or zoom region never appears, or a shorter name
-- leaves a stale tail) on any step of the sweep, that step went one too far:
-- revert to the previous value in the list, and if 50 itself already loses
-- messages, revert all the way to 100.
--
-- Reducing a captured hardware log to a per-message interval table (note:
-- /tmp/lua.log itself has no per-line timestamps - restart-mainstage.sh
-- redirects stdout raw - so capture it through a timestamping filter first,
-- e.g. `... | while IFS= read -r l; do printf '%s %s\n' "$(date
-- '+%H:%M:%S.%3N')" "$l"; done > /tmp/lua.log`, or pipe through moreutils'
-- `ts '%H:%M:.S'` if installed):
--   grep -E '\[sllink\] (FLUSH|timer tick)' /tmp/lua.log | \
--     awk '{ts=$1; if (p!="") printf "%s -> %s  %s\n", p, ts, $0; p=ts}'
-- prints each FLUSH/tick line paired with the timestamp delta since the
-- previous one - the `tick=`/`pending=`/`queueDepthAfter=` fields already in
-- each line then tell you how many ticks and how much queue depth changed
-- per interval, without needing a Lua-side clock (there isn't one - `os` is
-- absent in this environment).
FLUSH_SOON_MS = 50

-- `regionId`, when given, is stashed as a NAMED field on the message table
-- (Lua's `#`/ipairs only see the integer-keyed byte sequence, so this rides
-- along for free without disturbing flush_pending's byte-for-byte indexing
-- or drop_queued_display's `m[8]` itemType check). It is how
-- drop_queued_display() finds its way back to the `drawn[id]` memo entry a
-- discarded message came from - see that function's comment - and, below, how
-- a newer paint for the same region COALESCES with an older one still
-- sitting in the queue instead of piling up behind it.
--
-- PER-REGION COALESCING (measured on hardware: rapid patch navigation queued
-- 4, 5, 6, 7, then 10 messages in a row - at one message per ~100ms flush,
-- some rows were never painted before the next patch superseded them, i.e.
-- the black-rows bug). If the queue already holds a display message for this
-- SAME regionId, REPLACE it in place rather than appending a duplicate: the
-- newer content wins, and nothing behind it is thrown away and re-created the
-- way drop_queued_display() used to. Position is preserved deliberately - the
-- SL88 has no layers and paints strictly in message order, so an update to
-- one region must not reorder it relative to regions that were queued around
-- it, or draw order (e.g. a row's backing rect before its text - see
-- draw_row) could invert.
--
-- Protocol messages (identification, keepalive, logout - regionId nil) are
-- NEVER coalesced: they append as always. Collapsing two Identification
-- Queries, for instance, would drop one side of a request/reply pair the
-- session clock depends on (see the SESSION CLOCK note near
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

-- Counts every display message flush_pending() actually emits (not merely
-- queues). Screen content proves what was PAINTED; it cannot distinguish a
-- message that was sent and dropped by the keyboard from one that was never
-- sent at all - see the alternating-row-loss finding at the displayMode
-- declaration above. This is the observation path that tells the two apart.
flushCounter = 0

-- Emits whole messages up to the budget. `includeQuery` appends an
-- Identification Query and reserves room for it inside the budget: its reply
-- is the only thing that re-arms the one-shot timer (see the SESSION CLOCK
-- note above controller_midi_in), so a flush carrying no query can stall the
-- session clock.
function flush_pending(includeQuery)
	local out = {}
	local query = includeQuery and msg_identification_query() or nil
	local reserve = query and #query or 0

	-- Exactly ONE queued message per flush, always paired with the query.
	--
	-- Every shape that has ever rendered reliably on hardware looked like
	-- [display, query]; the ones that silently vanished were the odd ones out -
	-- a lone display message, a display bundled with the keepalive, two
	-- displays together. Position in the repaint turned out to be irrelevant
	-- (moving the draw order just moved the failure), as did size and content.
	-- Rather than keep guessing at the underlying rule, emit the one shape that
	-- has never failed. A repaint costs a few more flushes, which at
	-- FLUSH_SOON_MS still converges in well under a second.
	--
	-- DEFECT A FIX: that "a few more flushes" assumed flushes happen at
	-- FLUSH_SOON_MS. They didn't (see displayFlushReady's declaration) - so a
	-- display message (itemType IT_DISPLAY) may only be dequeued here while
	-- displayFlushReady is true, and doing so clears it. A non-display,
	-- protocol message at the front of the queue (identification, keepalive,
	-- logout) is never gated - it dequeues exactly as before, every flush.
	--
	-- DEFECT B FIX (established on hardware 2026-08-21): the above only ever
	-- looked at pendingMessages[1]. During a repaint drain, a keepalive queued
	-- BEHIND a display message sat stuck there until the whole display
	-- backlog cleared, one message every FLUSH_SOON_MS -
	-- controller_timer_trigger's "protocol messages dequeue every flush
	-- regardless" comment was only true once a protocol message actually
	-- reached the head of the queue. Combined with the 3s keepalive cadence,
	-- a slow repaint could miss the SL88's ~5s host timeout and drop the
	-- session mid-repaint.
	--
	-- Fix: if the head message can't go out this flush (it is IT_DISPLAY and
	-- displayFlushReady is false), scan forward for the FIRST protocol
	-- message (itemType ~= IT_DISPLAY) and let it jump the queue instead,
	-- removed from its own position with everything else left untouched.
	-- Display messages never reorder relative to each other - only a
	-- protocol message can jump ahead of ones still waiting on
	-- displayFlushReady. Still at most one queued message per flush, still
	-- paired with the query below.
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
			if isDisplay then
				displayFlushReady = false
				-- CLEAR SCREEN SETTLE GUARD: see displaySettleTicks'
				-- declaration. A Clear Screen going out earns the next
				-- draw an extra tick of quiet on top of the ordinary
				-- one-per-tick pacing.
				if m[9] == DISP_CLEAR_SCREEN then displaySettleTicks = 1 end
			end
			flushCounter = flushCounter + 1
			-- CADENCE INSTRUMENTATION (2026-08-21): `tick=` ties this FLUSH to
			-- controller_timer_trigger's tick print (the tick counter is a
			-- plain global, incremented there) so a captured log can be
			-- reduced to "tick N emitted region R, depth D" even though
			-- flushes can also happen off-tick (inbound-frame flushes in
			-- controller_midi_in, controller_select_patch) - a FLUSH whose
			-- tick= repeats the previous FLUSH's is exactly one of those.
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
	return { midi = out, outport = SL_PORT }
end


-- MARK: - Message builders

function sl_header()
	local m = {}
	for i = 1, #SL_HEADER do m[i] = SL_HEADER[i] end
	m[#m + 1] = SL_HOST_ID
	m[#m + 1] = instanceID
	return m
end

-- ASCII-clamps to the SLMK2 font range and 0x00-terminates, matching
-- SLLinkEncoder.asciiTerminated.
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

-- 8-bit RGB -> the 7-bit-per-channel form every SL Link colour field uses
-- (SLLinkEncoder.rgb7 drops the least significant bit).
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

-- Sent purely to elicit a reply and thereby keep the session clock running -
-- see controller_timer_trigger.
function msg_identification_query()
	local m = sl_header()
	table.insert(m, IT_IDENTIFICATION)
	table.insert(m, ID_QUERY)
	table.insert(m, SL_END)
	return m
end

-- flush_pending only ever dequeues ONE message per flush, and only if it fits
-- alongside the Identification Query it always reserves room for (see
-- flush_pending's comment) - a message that never fits is never sent AND
-- never dropped, which jams the queue and stalls the session clock forever.
-- append_text used to allow up to 96 characters with no relation to that
-- budget, so a ~48-char patch name was enough to hang the script.
--
-- This cap is NOT the rule-4 "never truncate" violation: Max Width still does
-- the *visual* truncation in pixels, with its own "..." for anything that
-- doesn't fit on screen, regardless of how many characters were sent. This is
-- a transport limit only, computed from the query builder itself (not
-- hand-counted) so it stays correct if either message's shape ever changes.
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
-- Ported from SL-Link-Mainstage/SLLink/SLLinkDisplay.swift: draw_text/draw_rect remember the
-- full parameter tuple they last sent for a given caller-supplied id, and queue nothing when
-- a call repeats it unchanged. Mandatory, not an optimisation - at one message per ~100ms
-- flush, a full list repaint costs about a second; without this every self-heal repaint would
-- cost the same again.
--
-- NON-OVERLAP RULE (same as SLLinkDisplay's doc comment): every region id must own screen
-- pixels that no other id draws. A change to one id's memo does not invalidate any other id,
-- so a caller that layers draws - e.g. a filled rect under text - will corrupt the screen the
-- moment only the bottom layer changes and the top layer is skipped as unchanged; the device
-- has no concept of layers, it paints strictly in message order. Use invalidate(ids) to force
-- every id sharing an unavoidable overlap to be resent together as one unit - see
-- draw_text_with_erase() below for the one place this project needs that escape hatch (the
-- zoom screen's zset/zname/znext, which must draw at maxWidth=0 and so cannot self-clear).

drawn = {}

function invalidate_all()
	drawn = {}
end

function invalidate(ids)
	for i = 1, #ids do
		drawn[ids[i]] = nil
	end
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
-- Each element is queued as its own message and delivered across consecutive
-- flushes, because MainStage will not emit more than ~78 bytes at once (see
-- FLUSH_BUDGET). Concatenating a whole repaint is exactly what produced a
-- completely black screen in earlier attempts.
--
-- No manual string truncation: the SL Link spec sets no text-length limit, and
-- Max Width already truncates visually in pixels, appending '...' when needed.
-- Let the keyboard do it.

SCREEN_WIDTH = 320
SCREEN_HEIGHT = 240
TEXT_X = 8
TEXT_MAXW = SCREEN_WIDTH - (2 * TEXT_X)

ROW_COUNT = 8
ROW_Y0 = 30
ROW_PITCH = 26
ROW_X = 8
ROW_MAXW = 304

-- FOUND ON HARDWARE (2026-08-19): a long patch name at SIZE_BIG with
-- maxWidth=304 rendered as a SINGLE LETTER followed by "...". The SL88's own
-- Max Width truncation is evidently unreliable at big size, so the zoom
-- screen's patch name still truncates itself (see truncate_text() and
-- paint_zoom_screen()) rather than relying on it. CONFIRMED WORKING at
-- SIZE_SMALL since - see the design doc's settled-facts table - which is why
-- every list row below uses a real, non-zero maxWidth instead.
--
-- FOUND ON HARDWARE (2026-08-20): wrapping the name across two lines (the
-- approach this constant originally served) instead left STALE TEXT on the
-- second line - a shorter name replacing a longer one did not fully
-- overwrite the old line's glyphs. Reverted to one truncated line.
--
-- HARDWARE-CALIBRATED BY EYE, not measured: nothing here reads actual glyph
-- widths. 20 is the count already confirmed to fit - "C05 Brassy Trombones"
-- (20 characters) renders in full at SIZE_BIG across the zoom screen's
-- width. Retune by eye against a name a couple of characters either side of
-- this constant if the geometry below changes (screen width, X margins,
-- font).
BIG_MAX_CHARS = 27

-- Same idea, for SIZE_MEDIUM text on the zoom screen. Only zset uses this now
-- (see that constant's comment above for why its geometry is an estimate) -
-- znext moved to SIZE_SMALL + trusted Max Width (see ZSET_TRUST_MAXWIDTH
-- below) on 2026-08-21 to cut it from 2 queued messages to 1, since it no
-- longer needs character-count truncation at all. SIZE_MEDIUM is smaller than
-- SIZE_BIG, so more characters fit in the same width; also unmeasured, retune
-- the same way as BIG_MAX_CHARS.
MEDIUM_MAX_CHARS = 36

-- truncate_text() cuts zname/zset to exactly these character counts (when
-- ZSET_TRUST_MAXWIDTH is false, for zset - see that flag below; zname always
-- truncates itself) before they are drawn (see draw_text_with_erase() below
-- for how the vacated band is cleared). znext no longer calls truncate_text()
-- at all - see MEDIUM_MAX_CHARS's comment above. Assert the budget
-- relationship rather than assuming it: TEXT_STRING_CAP is msg_write_text's
-- hard transport clamp (FLUSH_BUDGET minus wire overhead - see
-- TEXT_STRING_CAP's comment), and if either MAX_CHARS constant is ever
-- retuned past it, msg_write_text would silently re-truncate the
-- already-truncated string, losing truncate_text()'s own "..." and cutting
-- mid-word.
assert(BIG_MAX_CHARS <= TEXT_STRING_CAP,
       'BIG_MAX_CHARS must fit within TEXT_STRING_CAP or zname draws would be re-truncated on the wire')
assert(MEDIUM_MAX_CHARS <= TEXT_STRING_CAP,
       'MEDIUM_MAX_CHARS must fit within TEXT_STRING_CAP or zset draws would be re-truncated on the wire')

-- SCROLL-OFF MARGIN (vim's `scrolloff`): a scroll TRIGGERS once the cursor
-- comes within SCROLL_MARGIN rows of an edge, so at least this many rows of
-- context stay visible beyond it - Jeroen's requirement that at least one
-- patch AFTER the current one is always on screen, so you can see what you
-- are changing to. 2, not 1: set headers occupy rows in a continuous list,
-- so a margin of 1 could leave the single visible row below the current
-- patch a set header - telling you the song ended but not what plays next.
-- A margin of 2 guarantees a real patch is visible even at a set boundary -
-- see the design doc's worked example. Asserted below rather than assumed:
-- SCROLL_MARGIN must stay under half the window or this rule and the final
-- clamp fight each other. What happens ONCE triggered is PAGE_OVERLAP's and
-- clamp_scroll's concern, not this constant's - see both below.
SCROLL_MARGIN = 2
assert(SCROLL_MARGIN < ROW_COUNT / 2,
       'SCROLL_MARGIN must be less than ROW_COUNT / 2 or the margin and the final clamp fight each other')

-- PAGE JUMP (2026-08-21, replacing one-row edge-triggered scrolling - see
-- clamp_scroll's comment for the measured cost and why it was abandoned).
--
-- How many rows of the OLD window survive, unmoved, as the new window's own
-- leading rows (scrolling forward) or trailing rows (scrolling backward) -
-- some visual overlap so the eye has something familiar to re-anchor on when
-- the screen jumps, rather than every row changing at once with nothing to
-- orient by.
--
-- NOT an independently chosen 1-2 rows, even though that was the first
-- instinct: the cursor's landing position after a jump is NOT a free choice
-- once SCROLL_MARGIN and ROW_COUNT are fixed - see clamp_scroll's comment.
-- Landing the cursor right at the edge it jumped TO (the smallest possible
-- overlap) puts it back inside the OPPOSITE margin's trigger zone, and a
-- harness sweep caught this concretely: five page jumps fired back to back,
-- because a forward jump that lands at row 0 is, by definition, within
-- SCROLL_MARGIN of the TOP edge, so the very next step re-triggers a
-- BACKWARD jump, which lands at the last row - within SCROLL_MARGIN of the
-- BOTTOM edge - re-triggering forward again. That oscillation is a worse
-- version of the exact bug this change exists to fix, not a smaller overlap.
-- The only landing spot that is safe from BOTH margins at once is
-- SCROLL_MARGIN rows in from the edge just crossed, which forces
-- PAGE_OVERLAP = 2 * SCROLL_MARGIN (4 rows here, not 1-2) - derived, not
-- picked. See the design doc for the full derivation and the harness trace
-- that caught the oscillating version.
PAGE_OVERLAP = 2 * SCROLL_MARGIN
assert(PAGE_OVERLAP < ROW_COUNT,
       'PAGE_OVERLAP must be less than ROW_COUNT or a jump does not move the window at all')

-- Keeps scrollOffset such that cursorIndex is always inside the visible
-- window, with SCROLL_MARGIN rows of context beyond it wherever the list
-- itself allows.
--
-- ONE-ROW SHIFT, ABANDONED (2026-08-21, hardware report: list-mode patch
-- changes took up to ~2s and could drop the session). The original policy
-- here moved scrollOffset the MINIMUM amount needed to restore the margin -
-- and a hardware-report-driven audit (see docs/, and the harness this
-- function is tested against) found that minimum is USUALLY one row, and
-- landing the cursor with the minimum shift ALWAYS puts it exactly
-- SCROLL_MARGIN rows from the far edge (nowhere else it could land and still
-- satisfy the margin) - one row short of retriggering. During ordinary
-- monotonic browsing (advancing one patch at a time, the realistic gig
-- pattern) that meant EVERY SINGLE STEP once past the first couple of moves
-- re-triggered another one-row scroll, and a scroll costs a full
-- ROW_COUNT-row repaint (see the design doc's redraw cost table) where an
-- in-window cursor move costs 2 messages - so nearly every patch change was
-- paying for a full-window redraw it didn't need to.
--
-- PAGE JUMP, now: once triggered, the window jumps by (ROW_COUNT -
-- PAGE_OVERLAP) rows in the direction of travel, landing the cursor
-- SCROLL_MARGIN rows in from the edge it just crossed - the FIRST safe row
-- (scrolling forward: row SCROLL_MARGIN) or the LAST safe row (scrolling
-- backward: row ROW_COUNT-1-SCROLL_MARGIN). That is the landing spot with
-- maximum runway in the direction of travel while staying clear of BOTH
-- margins at once (see PAGE_OVERLAP's comment for why the naive "land right
-- at the edge" version oscillates). With ROW_COUNT=8 and SCROLL_MARGIN=2
-- that is 4 safe steps before the next trigger - i.e. roughly one jump every
-- five advances, not one every single advance.
--
-- The cursor's landing row is computed directly from cursorIndex, not as an
-- offset from the OLD scrollOffset, so this is correct for a jump of any
-- size (a single patch step, or the much bigger cursorIndex jump a set
-- change or full repaint can produce) without a separate case for either.
-- Still edge-triggered, NOT re-centring on every move - only a trigger
-- crossing SCROLL_MARGIN causes any of this; an in-window move still costs
-- nothing here (scrollOffset untouched, the cheap 2-message case).
--
-- The final clamp is what makes the list's own ends behave: near the top or
-- bottom, the landing guarantee cannot always be honoured (there may not be
-- another full page beyond it), so the offset pins at its limit and the
-- cursor moves further into the window instead - same principle as the old
-- scrolloff clamp, just with a page-sized jump instead of a one-row one.
-- This is also what keeps the LAST page a full ROW_COUNT-row window rather
-- than a short one: scrollOffset can never exceed #listRows - ROW_COUNT, so
-- the window only ever shrinks by never existing (a list shorter than
-- ROW_COUNT), never by trailing off with blank rows at the end of a jump.
--
-- Standalone rather than inlined into controller_select_patch so Phase 2's
-- joystick-driven cursor movement can call it too instead of re-deriving the
-- same clamp arithmetic.
function clamp_scroll()
	local m = SCROLL_MARGIN
	if cursorIndex - m < scrollOffset then
		-- Triggered scrolling BACKWARD: land SCROLL_MARGIN rows in from the
		-- window's LAST row - symmetric with the forward branch below, and
		-- the one landing spot that is safe from both margins (see
		-- PAGE_OVERLAP's comment).
		scrollOffset = cursorIndex - (ROW_COUNT - 1 - m)
	elseif cursorIndex + m >= scrollOffset + ROW_COUNT then
		-- Triggered scrolling FORWARD: land SCROLL_MARGIN rows in from the
		-- window's FIRST row.
		scrollOffset = cursorIndex - m
	end
	local maxOffset = math.max(0, #listRows - ROW_COUNT)
	if scrollOffset > maxOffset then scrollOffset = maxOffset end
	if scrollOffset < 0 then scrollOffset = 0 end
end

-- Three row states - deliberately fewer than the old four, because the
-- cursor is no longer a colour state at all (see draw_list_row()'s "> "
-- marker below): only what KIND of row it is, and whether it is the active
-- patch, affects colour now. { fr, fg, fb, br, bg, bb } per state - the
-- design doc's colour table. All channel values even (the wire format is
-- 7-bit per channel and halves these, dropping the low bit - odd values
-- silently round), except the conventional 255 used for "fully saturated"
-- throughout this file, which rounds to the same 127 as 254 so costs nothing.
ROW_HEADER = 0
ROW_PATCH  = 1
ROW_ACTIVE = 2

ROW_COLORS = {
	[ROW_HEADER] = { 110, 170, 230,   0,   0,   0 }, -- blue on black: structure, not a patch
	[ROW_PATCH]  = { 150, 150, 150,   0,   0,   0 }, -- grey on black: recessive, the bulk of the list
	[ROW_ACTIVE] = {   0,   0,   0, 255, 170,  40 }, -- black on amber: unmistakable at distance
}

-- Draws list row `i` (0-based, within the visible window) for `row` - one of
-- the flat, normalised listRows entries, or nil past the end of the list.
-- `isCursor` controls only the "> "/"  " marker column, never the colour:
-- active state and cursor state are deliberately on separate channels (see
-- the design doc), so there is no combined case to special-case here - a row
-- that is both simply gets ROW_ACTIVE's colours with a "> " prefix, which
-- reads correctly with nothing extra written for it.
--
-- Every row - including a past-the-end blank one - draws at the SAME x and
-- maxWidth (ROW_X, ROW_MAXW), confirmed on hardware to make Write Text's
-- background fill the whole box (see the design doc's settled-facts table),
-- so every row is self-clearing: no erase rect, ever, on this screen.
-- Indentation is two literal leading spaces in the string, placed AFTER the
-- marker column, never a change to x - that is what keeps every row's
-- background box identical (so highlight bars line up) and the ">" pinned
-- to one character position regardless of row kind.
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

-- Finds the flat, 0-based listRows index of the currently ACTIVE patch (the
-- one MainStage has loaded - activeSetIndex/activePatchIndex), or 0 if none
-- matches (e.g. before the first real patch selection). Used both to keep
-- cursorIndex tracking the active patch in Phase 1 (controller_select_patch)
-- and to find where the NEXT patch search should start (next_line_text()).
function find_active_row_index()
	for i = 1, #listRows do
		local row = listRows[i]
		if row.isPatch and row.setIndex == activeSetIndex and row.patchIndex == activePatchIndex then
			return i - 1
		end
	end
	return 0
end

-- Finds the label of the nearest set header at or before cursorIndex, for
-- the context bar. Phase 1's cursor always sits on a patch row (it tracks
-- the active patch - see controller_select_patch), so this always finds a
-- real header unless the list itself is empty.
function cursor_set_label()
	for i = cursorIndex + 1, 1, -1 do
		local row = listRows[i]
		if row and not row.isPatch then return row.label end
	end
	return ''
end

-- "concert - set": the context bar's content. A plain ASCII hyphen, not the
-- design doc's "·" - the SLMK2 font only covers 0x20-0x80 (see
-- append_text), so a middle dot would render as two spaces.
function ctx_text()
	return currentConcert .. ' - ' .. cursor_set_label()
end

-- The context bar: y=2, dim grey, replacing the old per-set header. In a
-- continuous list you routinely scroll past a set header and lose track of
-- which set you are in - this shows it in one line, and redraws only when
-- its CONTENT changes, for free, via the same per-region memoization every
-- other draw uses here (which is exactly "only when the cursor crosses into
-- a different set", since that is the only thing that can change
-- cursor_set_label()'s result while browsing within a set).
function draw_ctx()
	draw_text('ctx', ctx_text(), ROW_X, 2, ROW_MAXW, ALIGN_LEFT, SIZE_SMALL, 120, 120, 120, 0, 0, 0)
end

-- Draws the list screen's current model, memoized per region - repeat calls
-- with nothing changed queue nothing. No trailing sacrificial here - both
-- update_screen and paint_screen add it themselves, after calling this, via
-- queue_sacrificial_redraw() (see that function for why it now covers both
-- paths).
function paint_list_screen()
	draw_ctx()
	for i = 0, ROW_COUNT - 1 do
		local row = listRows[scrollOffset + i + 1]
		local isCursor = (scrollOffset + i == cursorIndex)
		draw_list_row(i, row, isCursor)
	end
end

-- Truncates `text` to at most `maxChars` characters, cutting to
-- maxChars - 3 and appending "..." (plain ASCII full stops - the SLMK2 font
-- only covers 0x20-0x80, see append_text) when it doesn't fit. Used instead
-- of the SL88's own Max Width truncation, which is confirmed broken at
-- SIZE_BIG (see BIG_MAX_CHARS's comment above) - both the patch name and the
-- set name are truncated here in the script and drawn with maxWidth=0.
function truncate_text(text, maxChars)
	text = text or ''
	if #text <= maxChars then
		return text
	end
	return text:sub(1, maxChars - 3) .. '...'
end

-- FOUND ON HARDWARE (2026-08-20): a new patch name shorter than the old one
-- left the old name's tail on screen. CAUSE: Write Text's opaque background
-- fills the MAX WIDTH BOX, not the glyph run. zname/zset draw with
-- maxWidth=0 ("print it all" per docs/implementing-sl-link.md) because Max
-- Width truncation is confirmed broken at SIZE_BIG - see BIG_MAX_CHARS's
-- comment, and it is not trusted for SIZE_MEDIUM either - but with
-- maxWidth=0 that box is only as wide as the glyphs actually drawn, so a
-- shorter string can't overwrite what a longer one painted before it.
--
-- FIRST FIX TRIED, AND REJECTED - do not reintroduce it: padding the
-- (already truncate_text()'d) string with spaces out to a CONSTANT character
-- count (BIG_MAX_CHARS/MEDIUM_MAX_CHARS) before drawing, on the theory that a
-- constant character count makes the background box a constant width. Failed
-- on hardware for two independent reasons, both confirmed by eye:
--   1. The SLMK2 font is PROPORTIONAL. N characters of space are
--      pixel-narrower than N characters of the letters they replaced, so a
--      shorter name still left a stale tail - "m.23 A32 Ready patch" ->
--      "m.31 A18 Flutes" left "tch" on screen.
--   2. Padding is symmetric in CHARACTERS, not pixels, so it also broke
--      ALIGN_CENTER's actual centring - the visible glyphs no longer sat
--      centred in the box.
--
-- REAL FIX: draw an explicit black msg_draw_rect over the full band BEFORE
-- the text, sized independently of the string's glyph width, so it clears
-- the whole line regardless of what any previous string painted - see
-- draw_text_with_erase() below.

-- Draws `text` preceded by an explicit black erase rect spanning its full
-- band, sized independently of the string's glyph width - the real fix for
-- the stale-tail/off-centre bug in the comment above. Memoized as ONE region
-- under `id`, using an id..':rect'/id..':text' coalescing-key split
-- (base_region_id() already knows how to unwind it for drop_queued_display),
-- so an unchanged name queues NOTHING and a changed name always queues both
-- halves together, in order. bg is always black to match the erase rect's
-- fill.
--
-- The rect and text are two SEPARATE queue_message() calls and therefore two
-- separate flushes under flush_pending's one-display-message-per-tick pacing
-- (see FLUSH_SOON_MS/displayFlushReady) - do NOT try to bundle them into one
-- flush to save the flicker. Two display messages back-to-back in one flush
-- is exactly the pattern that dropped alternating rows on hardware (rule 5
-- in the FIVE RULES banner at the top of this file), and they would not fit
-- anyway: a 21-byte rect plus a max-length Write Text (25 + up to
-- BIG_MAX_CHARS chars) plus the Identification Query flush_pending always
-- reserves room for exceeds FLUSH_BUDGET on its own.
--
-- COST, accepted: one extra message and, at FLUSH_SOON_MS, a ~100ms visible
-- blank band per name change. This is the price of maxWidth=0, itself
-- required because Max Width truncation is broken at SIZE_BIG (see
-- BIG_MAX_CHARS's comment).
function draw_text_with_erase(id, text, x, y, align, size, fr, fg, fb, eraseX, eraseY, eraseW, eraseH)
	local t = { text, fr, fg, fb }
	if tuple_equal(drawn[id], t, #t) then return end
	drawn[id] = t
	queue_message(msg_draw_rect(eraseX, eraseY, eraseW, eraseH, 0, 0, 0), id .. ':rect')
	queue_message(msg_write_text(text, x, y, 0, align, size, fr, fg, fb, 0, 0, 0), id .. ':text')
end

-- Governs zset ONLY (renamed from ZSET_ZNEXT_TRUST_MAXWIDTH on 2026-08-21,
-- when znext moved off this flag entirely - see below). SAFE default: false,
-- i.e. zset keeps using draw_text_with_erase() (maxWidth=0, explicit erase
-- rect) exactly like zname. Max Width truncation is only CONFIRMED broken at
-- SIZE_BIG (see BIG_MAX_CHARS's comment) - it has never been tested at
-- SIZE_MEDIUM, which is what zset uses. If a hardware check confirms it
-- truncates correctly at SIZE_MEDIUM too, flip this to true: zset then draws
-- with draw_text() at a real, non-zero maxWidth (self-clearing, like every
-- list row - see draw_list_row()), no erase rect, no truncate_text() call
-- (the device does its own pixel-exact "..." truncation, same as list rows),
-- halving its cost from 2 messages to 1 and removing the ~100ms blank-band
-- flicker on every set change. WHAT TO LOOK FOR on hardware after flipping
-- it: a long set name should truncate cleanly with a trailing "..." (not a
-- single letter, which is the SIZE_BIG failure mode) and a shorter name
-- replacing a longer one must not leave a stale tail. Flip back immediately
-- if either happens.
--
-- znext DELIBERATELY moved off this flag on 2026-08-21 (hardware report: the
-- NEXT line reads as too visually prominent, and every zoom-screen patch
-- change was paying for a second queued message it did not need). It now
-- always draws SIZE_SMALL through the ordinary self-clearing draw_text() path
-- - no truncate_text() call, no erase rect - trusting Max Width
-- unconditionally rather than gating it behind a flag: Max Width truncation
-- is only CONFIRMED broken at SIZE_BIG (see BIG_MAX_CHARS's comment above),
-- and every list row already trusts it at SIZE_SMALL without incident, which
-- is why SIZE_SMALL is the one regime where trusting it needs no hardware
-- check first. This drops znext from 2 queued messages to 1 on every patch
-- change.
ZSET_TRUST_MAXWIDTH = false

-- "NEXT" line for the zoom screen: the next listRows entry after the ACTIVE
-- patch with isPatch true, skipping set headers - i.e. what you are about to
-- change to. The prompt word itself carries whether that patch starts a new
-- song (rather than trying to also fit the set's name on the line), since a
-- song boundary matters more mid-performance than the destination set's
-- name. Returns the no-next form at the end of the concert.
function next_line_text()
	local activeIndex = find_active_row_index()
	for i = activeIndex + 2, #listRows do
		local row = listRows[i]
		if row.isPatch then
			local word = (row.setIndex ~= activeSetIndex) and 'NEXT SONG' or 'NEXT'
			return word .. '  ' .. row.label
		end
	end
	-- End of the concert: no next patch. An em dash isn't in the SLMK2 font
	-- range (append_text clamps anything outside 0x20-0x80 to a space), so
	-- this uses a plain ASCII substitute instead of the design doc's "—".
	return 'NEXT  --'
end

-- Draws the zoom screen's current model, memoized per region. Shows the
-- ACTIVE patch, not the cursor - "what am I playing right now" - plus, on
-- znext, what you are about to change to.
--
-- REVERTED (2026-08-20) from a two-line wrapped patch name back to one
-- truncated line: on hardware, the multi-line repaint left stale text on the
-- second line when a shorter name replaced a longer one (see BIG_MAX_CHARS's
-- comment).
--
-- zname always truncates itself via truncate_text() and draws through
-- draw_text_with_erase() (maxWidth=0) - Max Width truncation is CONFIRMED
-- broken at SIZE_BIG, so there is no flag for it. zset does the same UNLESS
-- ZSET_TRUST_MAXWIDTH is flipped on (see that flag above), in which case it
-- draws self-clearing at a real maxWidth like list rows. znext (2026-08-21)
-- always draws SIZE_SMALL, self-clearing, at a real maxWidth, unconditionally
-- - see ZSET_TRUST_MAXWIDTH's comment for why it no longer shares zset's flag.
-- Revised layout (design doc): zcnc y=12, zset y=44, zname y=100, znext
-- y=170, zpos y=210 - bands 12-33 / 44-71 / 100-133 / 170-191 / 210-231, all
-- non-overlapping (znext's band shrank from SIZE_MEDIUM's ~27px to
-- SIZE_SMALL's 21px on 2026-08-21, still clear of zname above and zpos
-- below). Retune together with ROW_Y0-style constants if the layout ever
-- moves again.
function paint_zoom_screen()
	draw_text('zcnc', currentConcert, 8, 12, 304, ALIGN_CENTER, SIZE_SMALL, 120, 120, 120, 0, 0, 0)

	if ZSET_TRUST_MAXWIDTH then
		draw_text('zset', setName, 8, 44, SCREEN_WIDTH - 16, ALIGN_CENTER, SIZE_MEDIUM,
			110, 170, 230, 0, 0, 0)
	else
		draw_text_with_erase('zset', truncate_text(setName, MEDIUM_MAX_CHARS),
			8, 44, ALIGN_CENTER, SIZE_MEDIUM, 110, 170, 230,
			0, 44, SCREEN_WIDTH, 27)
	end

	draw_text_with_erase('zname', truncate_text(patchName, BIG_MAX_CHARS),
		8, 100, ALIGN_CENTER, SIZE_BIG, 255, 255, 255,
		0, 100, SCREEN_WIDTH, 33)

	-- SIZE_SMALL + trusted Max Width, unconditionally - no flag, no
	-- truncate_text(), no erase rect. See ZSET_TRUST_MAXWIDTH's comment for
	-- why znext no longer shares zset's gated path: SIZE_SMALL is the one
	-- regime list rows already trust Max Width in, so it needs no hardware
	-- check first. One queued message instead of two.
	draw_text('znext', next_line_text(), 8, 170, SCREEN_WIDTH - 16, ALIGN_CENTER, SIZE_SMALL,
		80, 200, 120, 0, 0, 0)

	-- n/N is the cursor's position in the flat listRows (headers included),
	-- not a per-set patch count - the flat list has no per-set count left to
	-- show now that patchRows no longer exists.
	local n = #listRows > 0 and (cursorIndex + 1) or 0
	draw_text('zpos', n .. '/' .. #listRows, 8, 210, 304, ALIGN_CENTER, SIZE_SMALL, 120, 120, 120, 0, 0, 0)
end

-- Ordinary content-driven redraw: draws the current model, memoized per
-- region, and queues NOTHING beyond whatever actually changed (2 messages
-- for a patch change within a set, 9 for a set change, 0 if nothing
-- differs - see the design doc's redraw cost table) PLUS the trailing
-- sacrificial redraw below when anything real was queued, so a patch change
-- costs one more than that table and a set change costs one more still.
-- Used to be documented as deliberately having no trailing sacrificial, on
-- the theory that only the FULL, invalidate_all()-preceded repaint in
-- paint_screen (login, restart, the periodic self-heal) was at risk of
-- losing its last message. That theory doesn't hold: the drop was never
-- shown to depend on message count or size, only on being last in a flush,
-- and an ordinary patch/set change is exactly that shape - a short burst
-- ending in a ROW write. Losing that last message leaves a stale highlight
-- on screen, which is the failure this feature exists to prevent, so the
-- same one-message insurance now applies here too. See
-- queue_sacrificial_redraw() and paint_screen's comment for the finding.
--
-- No longer calls drop_queued_display() at the top. That used to be how a
-- newer paint superseded an older, still-undrained one - but it worked by
-- throwing everything away and re-queuing from scratch, which is exactly the
-- treadmill that starved rows under rapid patch changes (see queue_message's
-- coalescing comment). Superseding a stale queued region now happens for
-- free, in place, inside draw_text/draw_row's own queue_message() call.
function update_screen()
	local before = queuedDisplayOps
	if displayMode == 'zoom' then
		paint_zoom_screen()
	else
		paint_list_screen()
	end
	if queuedDisplayOps > before then
		queue_sacrificial_redraw()
	end
	screenDirty = false
	lastPaintedPatch = patchName
	lastPaintTick = idleTicks
	print('[sllink] update queued (' .. #pendingMessages .. ' msgs) mode=' .. displayMode ..
	      ' "' .. patchName .. '"')
end

-- Undoes queue_message's id..':rect' / id..':text' split (see draw_row) so
-- drop_queued_display can find its way back to the single drawn[] memo entry
-- both halves share, regardless of which of the two coalescing keys a given
-- queued message actually carries. Plain ids (no backing rect in play) pass
-- through unchanged.
function base_region_id(id)
	return id:match('^(.*):rect$') or id:match('^(.*):text$') or id
end

-- Repaints the screen. The SL88 keeps no display state across Standby, so this
-- is also what a Restart triggers.
-- Drops display messages still sitting in the queue. Used only where the
-- queue's content is genuinely garbage, not merely stale-but-wanted - see
-- set_display_mode, its one remaining caller: switching modes vacates the
-- whole screen, so anything still queued for the outgoing mode cannot be
-- coalesced into anything the new mode will ever draw. update_screen() and
-- paint_screen() no longer call this - per-region coalescing in
-- queue_message() now supersedes stale queued work in place instead of
-- discarding and re-queuing everything, so the "drop everything" step they
-- used to take here is no longer needed for them.
-- Protocol messages (identification, logout, ...) are preserved.
--
-- FOUND ON HARDWARE: draw_text/draw_rect record drawn[id] the moment they
-- QUEUE a message, not when it is actually sent - but this function can
-- discard that same message before it ever goes out. Left alone, drawn[id]
-- permanently claims the region was painted, so it is never re-queued: the
-- memo and the physical screen diverge for good. This one bug explained
-- three separate symptoms seen on the SL88 - rows that should have reverted
-- from orange to grey staying orange forever, a re-selected row that looked
-- like it "toggled", and rows left blank/black after a repaint raced a drop.
-- Fix: undo the memo for exactly the id(s) this function discards, so the
-- next paint re-queues them. Do not reintroduce "update the memo at queue
-- time" without also undoing it here on drop.
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

-- TRAILING SACRIFICIAL REDRAW, shared by paint_screen and update_screen.
--
-- Empirically the FINAL flush of a repaint never takes effect: whichever
-- display message ends up last is silently lost, and swapping the draw
-- order just moves the loss to whatever is now last. It is not about the
-- message's content, size, position, or what it is bundled with - a lone
-- 43-byte Write Text as the last flush is dropped just the same as one
-- paired with a keepalive. Anything with a further transmission after it
-- renders reliably.
--
-- So end any real screen update with a harmless duplicate. Re-drawing the
-- concert line is idempotent (identical pixels, same coordinates), so it
-- costs one extra message and is safe to lose - which it duly is, while
-- everything that matters now has something following it.
--
-- Originally this lived only at the end of paint_screen's FULL repaint, on
-- the theory that only a full, invalidate_all()-preceded repaint was at
-- risk. That theory doesn't hold - the drop was never shown to depend on
-- message count or size, only on being last - so update_screen calls this
-- too. Both callers gate the call on having actually queued something: an
-- all-memoized no-op call has no "last real message" that needs a harmless
-- successor, so it correctly still queues zero.
--
-- Builds and queues the message DIRECTLY, bypassing draw_text(), and with NO
-- regionId - not an oversight, a requirement now that queue_message()
-- coalesces by regionId. The real ctx/zcnc draw almost always sits earlier
-- in this exact same paint's queue (draw_ctx/paint_zoom_screen run first);
-- routing this through draw_text('ctx', ...) would hand it that SAME
-- regionId and coalesce it into that earlier entry instead of appending a
-- distinct trailing message - collapsing the one thing this mechanism exists
-- to guarantee (a disposable duplicate strictly AFTER everything real) back
-- into whatever position the real draw happened to queue at. A nil regionId
-- always appends (see queue_message), which is exactly "trailing". No memo
-- bookkeeping needed here either: drawn['ctx']/['zcnc'] already holds the
-- correct content from the real draw this call is shadowing.
function queue_sacrificial_redraw()
	if displayMode == 'zoom' then
		queue_message(msg_write_text(currentConcert, 8, 12, 304, ALIGN_CENTER, SIZE_SMALL,
			120, 120, 120, 0, 0, 0))
	else
		queue_message(msg_write_text(ctx_text(), ROW_X, 2, ROW_MAXW, ALIGN_LEFT, SIZE_SMALL,
			120, 120, 120, 0, 0, 0))
	end
end

-- FULL repaint: draws everything for the current mode, relying on the
-- caller having invalidated first (handle_login, handle_restart, and the
-- self-heal branch in handle_sl_frame all call invalidate_all() before this)
-- so every region actually resends rather than being skipped as unchanged.
-- Ordinary content-driven updates (a patch/set change from MainStage) go
-- through update_screen() instead, which also ends with
-- queue_sacrificial_redraw() - see that function's comment for why both
-- paths need it.
-- No longer calls drop_queued_display() at the top - see update_screen's
-- comment on the same change. A full, invalidate_all()-preceded repaint just
-- means every region's queue_message() call is guaranteed to find a stale
-- entry to coalesce (if one is still queued) or append fresh (if not);
-- either way nothing needs to be thrown away first.
function paint_screen()
	-- NO Clear Screen.
	--
	-- With a clear at the head of the repaint, exactly one text line went
	-- missing every time - but WHICH line varied between runs (patch, then set,
	-- then concert) even with the message order and flush shape held constant.
	-- That randomness reads like a race rather than a protocol rule: a
	-- full-screen fill plausibly takes the SL88 a while, and any text arriving
	-- while it is still painting gets wiped.
	--
	-- The clear is not needed anyway. The spec is explicit that Write Text
	-- "will completely overwrite any existing content on the screen pixels
	-- within the area where the text is printed" (docs/display-messages.md), so
	-- redrawing the same regions is self-cleaning.

	-- No longer carries a znameErase step (a black rect over y=80-180, queued
	-- only from this FULL-repaint path). That rect existed to catch stale
	-- pixels left by a since-reverted TWO-LINE patch-name layout's second
	-- line (roughly y=124-157) - a build no longer in this codebase.
	-- draw_text_with_erase() (see paint_zoom_screen()) now erases zname's own
	-- band on EVERY draw, full repaint or ordinary update alike, so the
	-- current single-line layout never needs a separate one-time pass. If a
	-- keyboard is still showing residue from that old two-line build, one
	-- manual full-screen clear (e.g. cycle set_display_mode, which paints a
	-- 0,0-320,240 black rect) clears it for good; that is a one-off migration
	-- concern, not something worth carrying as permanent code.
	local before = queuedDisplayOps
	if displayMode == 'zoom' then
		paint_zoom_screen()
	else
		paint_list_screen()
	end

	-- Trailing sacrificial redraw - see queue_sacrificial_redraw()'s comment.
	if queuedDisplayOps > before then
		queue_sacrificial_redraw()
	end

	screenDirty = false
	lastPaintedPatch = patchName
	lastPaintTick = idleTicks
	print('[sllink] paint queued (' .. #pendingMessages .. ' msgs) mode=' .. displayMode ..
	      ' "' .. patchName .. '"')
end

-- Mode switching. Wired to the Zoom button (BID_ZOOM, confirmed on hardware -
-- see handle_zoom_button).
--
-- CLEAR SCREEN EXPERIMENT (2026-08-21): this is now the ONE place in the
-- file that sends Clear Screen - see the file-header rule 3 for why it stays
-- banned everywhere else. HARDWARE REPORT: the previous full-screen black
-- msg_draw_rect left visible text remnants of the outgoing screen after a
-- mode switch - either the SL88 ignores/drops a rect that large, or paints
-- it too slowly for the repaint that follows not to race it. Clear Screen's
-- original ban came from a since-superseded finding (one text line missing
-- per repaint, later understood to be the display-pacing bug
-- displayFlushReady fixed - see that flag's declaration), so this is the
-- deliberate re-test now that the pacing bug is fixed, not a reversal of the
-- ban itself. Queued as its own discrete message with no regionId - never
-- coalesced, never bundled into an array with a Write Text, since the old
-- failure mode was always a clear bundled with drawing - and paired with a
-- SETTLE guard (see displaySettleTicks) since a full-screen clear plausibly
-- takes longer to paint than a text line. FALLBACK if remnants or dropped
-- lines return on hardware: revert to the full-screen black
-- msg_draw_rect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 0, 0, 0) this replaced.
function set_display_mode(mode)
	if mode ~= 'list' and mode ~= 'zoom' then return end
	displayMode = mode
	drop_queued_display()
	invalidate_all()
	queue_message(msg_clear_screen(0, 0, 0))
	local before = queuedDisplayOps
	if mode == 'zoom' then
		paint_zoom_screen() -- redundant with the full-screen erase above, but each name draw erases its own band anyway
	else
		paint_list_screen()
	end
	-- AUDIT FIX (2026-08-21): this repaint had no trailing sacrificial
	-- redraw, unlike paint_screen/update_screen - meaning the LAST message of
	-- a mode switch (zpos in zoom, or the last visible row in list) was
	-- exposed to the established "final flush of a repaint is silently
	-- dropped" hardware finding (see queue_sacrificial_redraw's comment).
	-- Same gate those two callers use: only queue it if this call actually
	-- queued real content.
	if queuedDisplayOps > before then
		queue_sacrificial_redraw()
	end
	screenDirty = false
	lastPaintedPatch = patchName
	lastPaintTick = idleTicks
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
	-- Cleanly cancels any pending reidentify-wait: this instanceID is now
	-- confirmed good, so a LATER rejection (a fresh re-init down the line)
	-- should get the full retry budget again, not whatever was left over.
	reidentifyRetriesLeft = MAX_SAME_ID_RETRIES
	print('[sllink] <- IDENTIFICATION APPROVED as ' ..
	      string.format('%02X %02X', SL_HOST_ID, instanceID) ..
	      ' - now in the SL88 APP list; select it there to activate')
end

-- Reason 0x00 = DeviceID taken/reserved.
--
-- docs/mainstage-integration.md "Open issues": on a MainStage-driven
-- re-init, this rejection usually means the SL88 is still holding OUR OWN
-- previous incarnation's registration under this same instanceID (no Logout
-- Request was sent - controller_finalize has no return path). Bumping to a
-- new id immediately would "solve" the rejection by registering as a
-- DIFFERENT app, silently losing the user's APP-list selection.
--
-- So: wait out REIDENTIFY_WAIT_MS (longer than the keyboard's ~5s host
-- timeout) for that stale registration to expire, then retry the SAME id -
-- reclaiming our own identity rather than creating a new one. Only after
-- MAX_SAME_ID_RETRIES failed retries (by then a genuine collision, e.g. the
-- OTHER script instance, which is actually alive and keepaliving and will
-- reject us every time) fall back to bumping the instance byte, as before.
function handle_identification_rejected(reason)
	print('[sllink] <- IDENTIFICATION REJECTED (reason ' ..
	      string.format('%02X', reason or 0) .. ') for instance ' ..
	      string.format('%02X', instanceID))

	if reidentifyRetriesLeft > 0 then
		reidentifyRetriesLeft = reidentifyRetriesLeft - 1
		state = STATE_REIDENTIFY_WAIT
		-- Not rearm_timer() - this must WIN over the FLUSH_SOON_MS/KEEPALIVE_MS
		-- that inbound traffic would otherwise re-arm it to (see rearm_timer's
		-- STATE_REIDENTIFY_WAIT guard, which is what stops that overwrite from
		-- happening on every subsequent inbound frame during the wait).
		settriggertimer(REIDENTIFY_WAIT_MS)
		-- This call genuinely arms a fresh one-shot (unlike
		-- controller_timer_trigger's own top-of-function call - see
		-- timerPending's declaration), so timerPending must reflect that: keeps
		-- rearm_timer's gating honest once the wait ends and normal inbound
		-- traffic resumes calling it.
		timerPending = true
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
	-- Fresh/re-confirmed session: make sure everything is resent rather than
	-- trusting our memo, which may record draws sent before the keyboard had
	-- actually identified/confirmed us.
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
	invalidate_all() -- SLLinkDisplay.swift: the SLMK2 forgets everything across Standby;
	                  -- without this every id's memo would wrongly think its last
	                  -- content is still on screen and skip resending it.
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
-- controller_timer_trigger's unconditional-keepalive comment for why this
-- guard exists: protocol messages are never coalesced by queue_message, so
-- calling send_keepalive() on every tick without this check would pile up a
-- duplicate behind an already-queued-but-undrained keepalive.
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
-- controller_midi_in receives the SL88's traffic, SysEx included (the VAX77
-- reference matches F0 in its own controller_midi_in the same way).

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
			-- The reply to our own keepalive query. Receiving it is what
			-- re-arms the timer, but its result byte is also the most reliable
			-- session signal we get - far more dependable than waiting for a
			-- LOGIN CONFIRMATION, which the keyboard only sends on a *fresh*
			-- login and skips entirely if it still remembers us.
			if e[9] == 0x00 then
				print('[sllink] <- query: not identified; re-identifying')
				state = STATE_IDLE
				start_identification()
			else
				-- Identified. Treat this as "the session is up" regardless of
				-- whether we ever saw APPROVED/LOGIN, and make sure the screen
				-- actually reflects the current patch.
				if state == STATE_IDENTIFYING or state == STATE_LISTED then
					state = STATE_ACTIVE
				end
				if patchName ~= '' and not has_pending() then
					local stale = (lastPaintedPatch ~= patchName)
					local due = (idleTicks - lastPaintTick) >= REPAINT_EVERY_IDLE_TICKS
					if due then
						-- Memoization means an unchanged repaint would emit ZERO
						-- messages and heal nothing, defeating the entire point of
						-- this periodic repaint (the SL88 wipes its own screen on
						-- APP-list selection with no reliable signal for it) -
						-- force every region to resend.
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
		if bid == BID_ZOOM then
			handle_zoom_button(pressKind)
		else
			local kind = (pressKind == PRESS_SHORT and 'SHORT') or (pressKind == PRESS_LONG and 'LONG')
				or tostring(pressKind)
			print('[sllink] <- BUTTON bid=' .. string.format('0x%02X', bid)
				.. ' event=' .. kind .. ' (unhandled) frame=' .. dump_event(e))
		end
	elseif itemType == IT_ENCODER then
		local eid = func
		local delta = e[9] - 0x40
		print('[sllink] <- ENCODER eid=' .. string.format('0x%02X', eid)
			.. ' tick=' .. string.format('0x%02X', e[9])
			.. ' delta=' .. tostring(delta) .. ' (unhandled) frame=' .. dump_event(e))
	else
		print('[sllink] <- unhandled itemType=' .. string.format('0x%02X', itemType)
			.. ' frame=' .. dump_event(e))
	end
end

-- SHORT toggles the display mode; LONG forces a full repaint of whichever
-- mode is currently showing. LONG must never be silently dropped - the
-- project rule (see CLAUDE.md's demo-screen interaction model: LONG_PRESSION
-- is confirmed delivered on real hardware, and every button case must give
-- it a distinct effect or run the same action as SHORT) - so it gets its
-- own, always-safe effect: a manual on-demand version of the periodic
-- self-heal repaint above (paint_screen() after invalidate_all()), useful if
-- the SL88's screen has drifted from what the script thinks it last painted.
function handle_zoom_button(pressKind)
	if pressKind == PRESS_LONG then
		print('[sllink] <- BUTTON zoom LONG - forcing full repaint of mode=' .. displayMode)
		invalidate_all()
		paint_screen()
	else
		local newMode = (displayMode == 'zoom') and 'list' or 'zoom'
		print('[sllink] <- BUTTON zoom SHORT - toggling display mode -> ' .. newMode)
		set_display_mode(newMode)
	end
end

-- MARK: - MainStage callbacks

function controller_initialize(applicationName, deviceNewlyDetected)
	settriggertimer(KEEPALIVE_MS)
	-- This is the very first arm for a fresh script instance - nothing was
	-- outstanding before it, and this call genuinely arms a timer (unlike
	-- controller_timer_trigger's own top-of-function call), so timerPending
	-- must say so or the first rearm_timer() from inbound traffic would
	-- wrongly re-arm on top of it.
	timerPending = true
	state = STATE_IDLE
	instanceID = SL_INSTANCE_START
	reidentifyRetriesLeft = MAX_SAME_ID_RETRIES
	pendingMessages = {}
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

-- NOTE: deliberately does NOT send a Logout Request.
--
-- MainStage tears this script down and re-initialises it repeatedly (observed:
-- init -> finalize -> init -> ... within seconds, partly because the script is
-- loaded once per matched USB-MIDI interface). An earlier version sent a
-- Logout Request here, which meant every one of those spurious teardowns
-- actively removed us from the SL88's APP list - guaranteeing the "showed up
-- briefly, then disappeared" symptom. Staying quiet lets the entry survive a
-- churn; if the script really is going away for good, the keyboard's own ~5s
-- keepalive timeout removes us anyway.
function controller_finalize()
	print('[sllink] controller_finalize (no logout sent - see note)')
	pendingMessages = {}
	state = STATE_IDLE
	return nil
end

-- Periodic. Re-arms itself so it keeps firing for as long as the device stays
-- selected. This is the only clock the session has, so the keepalive cadence
-- depends on it.
timerTicks = 0

function controller_timer_trigger()
	-- The one-shot has just fired, so nothing is outstanding any more - clear
	-- this BEFORE the settriggertimer call below, which (per the SESSION
	-- CLOCK note further down, established on hardware) does NOT actually
	-- re-arm anything when called from inside this function. Leaving
	-- timerPending false here is what is factually correct AND what lets the
	-- real re-arm - rearm_timer(), from the next inbound frame, almost always
	-- the reply to the Identification Query this function's own return
	-- flushes - go ahead instead of being gated out by a flag claiming a
	-- timer is already pending when none actually is.
	timerPending = false
	settriggertimer(KEEPALIVE_MS)
	timerTicks = timerTicks + 1

	-- DEFECT A FIX: grant this tick's one-display-message permit. See
	-- displayFlushReady's declaration for why this exists and what it fixes.
	-- If nothing is queued this tick simply arrives and leaves unconsumed -
	-- harmless, and means the next thing queued gets to go out immediately
	-- rather than waiting for a tick it had nothing to do with.
	--
	-- CLEAR SCREEN SETTLE GUARD (2026-08-21, see displaySettleTicks'
	-- declaration and set_display_mode's comment): withhold this tick's
	-- grant while a Clear Screen is still settling, so the draw that follows
	-- one gets roughly two tick periods of quiet instead of one. Protocol
	-- messages and the trailing Identification Query are unaffected - they
	-- are never gated by displayFlushReady in the first place (see
	-- flush_pending's comment) - so the session clock keeps running through
	-- the settle regardless.
	if displaySettleTicks > 0 then
		displaySettleTicks = displaySettleTicks - 1
	else
		displayFlushReady = true
	end
	-- Only ticks that arrive at the full keepalive cadence count towards the
	-- periodic refresh; fast drain ticks must not.
	local draining = has_pending()
	if not draining then idleTicks = idleTicks + 1 end
	-- CADENCE INSTRUMENTATION (2026-08-21): pending/draining here, plus this
	-- tick's number, is what lets a captured hardware log (LUA_DEBUG ->
	-- /tmp/lua.log, timestamped at capture time - see the FLUSH_SOON_MS sweep
	-- comment below for the reduction one-liner) be read as "N drain ticks
	-- elapsed while M messages went out": pair this line's tick number against
	-- the `tick=` field the FLUSH print (below, in flush_pending) now carries.
	-- No new print statements - this is the existing tick line, extended.
	print('[sllink] timer tick #' .. timerTicks .. ' (idle ' .. idleTicks .. ') state=' .. state ..
	      ' pending=' .. #pendingMessages .. ' draining=' .. tostring(draining))

	-- Keepalive UNCONDITIONALLY once we have sent an Identification Request.
	--
	-- Originally this only fired in LISTED/ACTIVE, i.e. only after seeing an
	-- IDENTIFICATION APPROVED come back. That stalled: if the keyboard still
	-- remembers us from a previous run it sends neither APPROVED nor LOGIN, so
	-- the state machine sat in IDENTIFYING, no keepalive went out, and the
	-- entry aged out of the APP list after ~5s - "MainStage showed up briefly,
	-- then disappeared". (SysEx *is* delivered to controller_midi_in; an
	-- earlier note here claiming otherwise was wrong. The query reply is the
	-- reliable session signal - see handle_sl_frame's ID_QUERY branch.)
	--
	-- So announce ourselves regardless of what we have observed. Harmless if
	-- the keyboard already has us logged in, and it is what keeps us listed if
	-- it does not.
	if state == STATE_IDLE then
		start_identification()
	elseif state == STATE_REIDENTIFY_WAIT then
		-- This tick firing at all means REIDENTIFY_WAIT_MS actually elapsed
		-- (rearm_timer() refuses to shorten it while waiting - see there), so
		-- this is the retry, not an ordinary keepalive tick. Falling through
		-- to the send_keepalive() branch below would be wrong here: it would
		-- announce the still-rejected instanceID instead of retrying it.
		start_identification()
	else
		-- SECOND FIX, same hardware session as rule 6 (2026-08-20): send the
		-- keepalive UNCONDITIONALLY on every keepalive-cadence tick, even
		-- while display work is still queued.
		--
		-- This used to be gated on `not has_pending()`, on the theory that
		-- bundling a System Device Notification (00/00) into the same array
		-- as a Write Text makes the SL88 discard the drawing - measured
		-- repeatedly, a repaint drained as
		--     F1 [clear, text]            -> rendered
		--     F2 [text, query 7F/03]      -> rendered
		--     F3 [text, keepalive 00/00]  -> NOT rendered
		-- That finding is still true and still matters, but gating the
		-- keepalive on an EMPTY queue was the wrong fix for it: a display
		-- message paces at one per tick (displayFlushReady), so a multi-
		-- message repaint can leave has_pending() true for several ticks in a
		-- row - and for every one of those ticks, no keepalive went out
		-- either. That is a second, independent route to the exact same ~5s
		-- APP-list timeout rule 6 fixes: a mid-repaint session could starve
		-- the keepalive without a single note being played.
		--
		-- This is safe to do unconditionally because send_keepalive() queues
		-- a PROTOCOL message (itemType IT_SYSTEM, regionId nil), and
		-- flush_pending never gates non-display messages behind
		-- displayFlushReady - they dequeue every flush regardless, jumping
		-- ahead of any display backlog sitting in front of them if necessary
		-- (see flush_pending's DEFECT B FIX comment: it scans past a gated
		-- display message at the head to find the first protocol message,
		-- rather than only ever looking at the head). So a keepalive never
		-- waits for, or consumes, the one-display-message-per-tick permit a
		-- Write Text needs - it neither competes with the repaint's own
		-- pacing nor risks reintroducing the bundled-drop finding above (it
		-- is queued as its own discrete message, never appended into the
		-- same array as a Write Text).
		--
		-- has_keepalive_queued() guards against PILE-UP: protocol messages
		-- are deliberately never coalesced by queue_message (two
		-- Identification Queries must both survive - see queue_message's
		-- comment), so without this guard a keepalive that is queued but not
		-- yet flushed would get ANOTHER one appended behind it on every
		-- subsequent tick, growing without bound. flush_pending's scan-
		-- forward fix now lets a queued keepalive jump ahead of a display
		-- backlog and go out on the very next flush rather than waiting for
		-- the whole backlog to drain, but it still emits at most one queued
		-- message per flush - this guard is what stops a rarer same-tick or
		-- budget-miss race from ever growing the queue.
		if not has_keepalive_queued() then
			send_keepalive()
		end
	end

	if screenDirty then
		paint_screen()
	end

	-- Also send an Identification Query. Its only purpose is to make the
	-- keyboard send something back: `settriggertimer` is a ONE-SHOT that
	-- cannot be re-armed from inside this callback (established on hardware,
	-- see the SESSION CLOCK note above controller_midi_in), so the only thing
	-- that keeps the clock running is inbound MIDI arriving at
	-- controller_midi_in. The query's reply is that inbound event, which
	-- re-arms the timer and schedules the next tick - a self-sustaining
	-- request/response heartbeat that does not depend on anyone playing.
	-- flush_pending appends the query itself and reserves budget for it.
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

-- SESSION CLOCK (established on hardware 2026-08-19)
--
-- `settriggertimer` is a ONE-SHOT, and crucially it does NOT re-arm when
-- called from inside controller_timer_trigger - that callback fired exactly
-- once per script instance no matter what. It DOES re-arm when called from
-- here. (VAX77, the one reference using a repeating timer, arms it from
-- controller_midi_in for exactly this reason.)
--
-- So the heartbeat is: timer tick -> send keepalive + Identification Query ->
-- keyboard replies -> that reply lands here -> re-arm -> next tick. Without
-- the query there is nothing to reply, the chain stops after one tick, and the
-- SL88 drops us from its APP list after ~5s - which is exactly the
-- "showed up briefly, then disappeared" symptom.
-- Re-arms the one-shot timer. Called at the END of controller_midi_in, after
-- any queued output has been drained, so the interval reflects what is still
-- outstanding rather than what was outstanding on entry.
--
-- NOTES-STARVE-THE-CLOCK FIX (rule 6 in the banner, established on hardware
-- 2026-08-20): controller_midi_in calls this on EVERY inbound MIDI event,
-- including every note on/off - not just SL frames. settriggertimer is a
-- ONE-SHOT: each call cancels and restarts whatever is already pending.
-- While the user plays, notes arrive far faster than the timer period, so an
-- unconditional settriggertimer() call here just kept pushing the deadline
-- back forever and controller_timer_trigger never fired - no tick, no
-- keepalive, and the SL88 drops a host that goes quiet for ~5s. That
-- explained the display dropping out WHILE PLAYING and recovering the
-- moment playing stopped.
--
-- Fix: only actually call settriggertimer when timerPending is false, i.e.
-- no one-shot is currently outstanding, and set it true when this does arm
-- one. A note arriving while a timer is already pending now leaves it alone
-- and passes straight through untouched (see controller_midi_in) - the
-- first inbound frame after a tick fires (in practice almost always the
-- Identification Query's reply, which arrives within ~2ms of the tick - see
-- the SESSION CLOCK note below) is what gets to choose the next interval,
-- exactly as before; only the REPEATED re-arming on every subsequent frame
-- is gone.
function rearm_timer()
	if state == STATE_REIDENTIFY_WAIT then
		-- CRITICAL: rearm_timer() runs on EVERY inbound frame. The rejection
		-- handler sets the one-shot timer to REIDENTIFY_WAIT_MS to wait out the
		-- SL88's ~5s host timeout (see handle_identification_rejected) - if this
		-- function touched the timer here too, that wait would be overwritten
		-- with FLUSH_SOON_MS/KEEPALIVE_MS by the very next inbound frame,
		-- typically within milliseconds, and the wait would never actually
		-- happen. Leave the pending timer alone until the wait state ends.
		return
	end
	if timerPending then
		-- A one-shot is already outstanding; it will fire on its own. This is
		-- the notes-starve-the-clock fix - see this function's comment above.
		return
	end
	if has_pending() then
		settriggertimer(FLUSH_SOON_MS) -- still draining a repaint; come back soon
	else
		settriggertimer(KEEPALIVE_MS)
	end
	timerPending = true
end

function controller_midi_in(midiEvent, portName)
	if midiEvent[0] == 0xF0 then
		print('[sllink] <- SYSEX on port=' .. tostring(portName) .. ': ' .. dump_event(midiEvent))
	end

	if is_our_sl_frame(midiEvent) then
		handle_sl_frame(midiEvent)
		-- Protocol traffic, not music: swallow it, and use the opportunity to
		-- flush whatever the handler queued. Do NOT include the Identification
		-- Query while state == STATE_REIDENTIFY_WAIT: flush_pending(true)
		-- appends it unconditionally, and the SL88 would truthfully answer
		-- "not identified" for an id it just rejected - which the ID_QUERY
		-- branch in handle_sl_frame treats as licence to re-identify right
		-- away, defeating the wait handle_identification_rejected just started.
		local out = flush_pending(state ~= STATE_REIDENTIFY_WAIT)
		rearm_timer()
		if out ~= nil then return out end
		return { midi = {} }
	end

	rearm_timer()

	if midiEvent[0] == 0xC0 then
		return { midi = {} } -- swallow Program Change (patchselector handles it)
	end

	-- Musical traffic must pass through untouched - never swallow it just to
	-- piggyback pending output, or notes will hang.
	return nil
end

-- Resolves a patchlist entry's label across the plausible field-name
-- spellings MainStage might use (the design doc assumed .Label; an earlier
-- version of this code assumed .Name; neither alone was safe to trust).
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

-- Same idea for the fields the list model depends on (IsPatch/SetIndex/
-- PatchIndex): tries the capitalised spelling (per the design doc) then the
-- all-lowercase one. Returns nil (not false) when neither variant is
-- present, so a genuinely-false IsPatch is distinguishable from a missing key.
function patch_field(entry, field)
	if type(entry) ~= 'table' then return nil end
	local candidates = { field, field:lower() }
	for _, key in ipairs(candidates) do
		local v = entry[key]
		if v ~= nil then return v end
	end
	return nil
end

-- ARGUMENT HIERARCHY SHIFT: MainStage reuses this same callback for
-- selections in Edit mode that are NOT a patch - selecting a SET or the
-- CONCERT there shifts the argument hierarchy up one level, the selected
-- thing arriving as patchname and its PARENT arriving as setname:
--   select a set:      patchname="2. Jacob & Sons / Joseph's Coat"  setname="Joseph key2"   (setname is actually the CONCERT)
--   select the concert: patchname="Joseph key2"                    setname=""
-- A DEFECT B FIX here used to detect that shift (via currentSetIndex/
-- currentPatchIndex plus patchlist's IsPatch/SetIndex/PatchIndex fields,
-- resolved through patch_field() above) and refuse to display anything for a
-- non-patch selection, keeping the last real patch on screen instead.
--
-- REVERTED 2026-08-20 - deliberate product decision, not an oversight: the
-- user wants the selected value shown in the patch slot regardless of what
-- level of the hierarchy it came from - selecting a set shows the set's
-- name, selecting the concert shows the concert's name. controller_select_patch
-- below now trusts patchname/setname/concertname unconditionally again. Do
-- not reintroduce a "refuse non-patch selections" guard without checking
-- first.
function controller_select_patch(programchangeNumber, patchname, setname, concertname,
                                 patchlist, currentSetIndex, currentPatchIndex)
	local p, s, c = patchname or '', setname or '', concertname or ''

	-- CRASH-SAFETY GUARD ONLY (not the reverted "refuse non-patch selections"
	-- behaviour above - see the ARGUMENT HIERARCHY SHIFT comment): MainStage's
	-- very first call happens before the concert has loaded, with patchlist
	-- nil/empty. There is nothing to browse yet, so bail out before touching
	-- displayed state rather than painting a blank/bogus name or letting the
	-- patchlist loop below run against nothing.
	if patchlist == nil or (type(patchlist) == 'table' and next(patchlist) == nil) then
		print('[sllink] controller_select_patch: patchlist not yet available - keeping last' ..
		      ' displayed patch "' .. patchName .. '"')
		return nil
	end

	-- MainStage calls this repeatedly with identical values (observed 5x for
	-- one patch change, partly because the script is loaded once per USB-MIDI
	-- interface). Repainting each time would waste a lot of MIDI - a full
	-- repaint is several messages - so only redraw on a real change.
	--
	-- Extended beyond the original name-only check to also compare
	-- currentSetIndex/currentPatchIndex: two identically named patches in
	-- different sets or positions must still move the highlight, which a
	-- name-only comparison would miss entirely.
	if p == patchName and s == setName and c == currentConcert
	   and currentSetIndex == activeSetIndex and currentPatchIndex == activePatchIndex then
		return nil
	end

	patchName, setName, currentConcert = p, s, c
	activeSetIndex = currentSetIndex or activeSetIndex
	activePatchIndex = currentPatchIndex or activePatchIndex

	-- Rebuild the flat, interleaved list. ipairs(), NOT pairs(): the visual
	-- order of the continuous list IS patchlist's own array order (sets and
	-- patches interleaved as MainStage displays them - see the design doc),
	-- so this must preserve it, unlike the old per-set filter where scan
	-- order never mattered. Field names resolved via patch_label()/
	-- patch_field() above rather than trusted directly (that's what made the
	-- highlight bar blank on an earlier hardware run - see those functions'
	-- comments). patchIndex falls back to the array position when
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

	-- Phase 1 has no independent browsing/cursor input yet (deferred to
	-- Phase 2's joystick handling) - the cursor simply tracks the active
	-- patch's position in the flat list.
	cursorIndex = find_active_row_index()

	-- currentConcert/setName added alongside the existing fields so a blank
	-- concert line on the SL88 screen can be told apart from a draw failure
	-- (2026-08-19 hardware run: concert line never appeared, cause unknown).
	print('[sllink] controller_select_patch: "' .. patchName .. '" (' .. #listRows .. ' rows total)' ..
	      ' concert="' .. currentConcert .. '" set="' .. setName .. '"')

	-- Keep the visible window on the newly-set cursor - must run after
	-- listRows/cursorIndex are rebuilt above (clamp_scroll's upper bound
	-- depends on #listRows) and before the repaint below.
	clamp_scroll()

	if state == STATE_REIDENTIFY_WAIT then
		-- Don't queue or flush anything while waiting to retry identification
		-- (see handle_identification_rejected) - a flush here would send an
		-- Identification Query under an instanceID the SL88 just rejected,
		-- which would defeat the wait (see controller_midi_in's comment on the
		-- same hazard). The bookkeeping above (patchName/listRows/etc.) still
		-- ran, so once we are re-identified the ID_QUERY self-heal branch in
		-- handle_sl_frame finds lastPaintedPatch stale and repaints for real.
		return nil
	end

	-- Draw whenever MainStage says the patch changed, without waiting to be
	-- sure we are logged in: a LOGIN CONFIRMATION only arrives on a *fresh*
	-- login, and the keyboard harmlessly ignores drawing we are not entitled
	-- to do. The ID_QUERY branch repaints again once the session is confirmed.
	update_screen()
	return flush_pending(true)
end

-- MARK: - Device declaration

-- Items describe MIDI the SL88 **actually transmits**, captured live on
-- 2026-08-19 (notes, pitch bend, modulation, second stick, sustain - all on
-- LINK, none on CTRL). Ports use the short names for the same reason outport
-- does; see the banner at the top of this file.
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
