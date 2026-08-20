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
--  3. Never send Clear Screen. It races with the draws that follow it and
--     loses a line - a different one each run. Write Text overwrites the
--     pixels it covers, so redrawing is self-cleaning.
--  4. Never truncate strings. Max Width truncates visually in pixels and
--     appends '...' itself.
--  5. Display messages must be paced to at most ONE per timer tick. The
--     Identification Query's reply is itself an inbound SL frame, so an
--     ungated flush_pending() re-enters controller_midi_in and drains the
--     whole queue at the ~2ms round-trip rate instead of the timer's rate -
--     FLUSH_SOON_MS looks like it paces this but does not. The SL88 silently
--     drops a display message that arrives while it is still painting the
--     previous one. See displayFlushReady.
-- =========================================================================

-- MARK: - Protocol constants (mirror SLLinkProtocol.swift exactly)

SL_PORT = 'LINK' -- see the banner above; NOT 'SL LINK'

SL_HEADER = { 0xF0, 0x00, 0x20, 0x1A, 0x16 }
SL_END = 0xF7

SL_HOST_ID = 0x03 -- SLLinkHeader.defaultHostID
SL_INSTANCE_START = 0x6D -- first instance byte tried; bumped on rejection

-- Item types
IT_SYSTEM = 0x00
IT_BUTTON = 0x01 -- spike instrumentation only (Q2/Q7, docs/full-functionality-plan.md); not otherwise handled
IT_ENCODER = 0x03 -- spike instrumentation only (Q2), see above
IT_DISPLAY = 0x04
IT_IDENTIFICATION = 0x7F

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
-- row, DIAG_ROW_EXTENT) rendered rows 0/2/4/6 and left 1/3/5 black - every
-- SECOND message lost, not a geometry bug (which would leave only the last
-- row visible). A 3-region zoom update (zset/zname/zpos, flushed back to
-- back as FLUSH #148/#149/#150) reliably lost the MIDDLE one - the patch
-- name, the one thing this screen exists to show.
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

-- Counts every display message queue_message() handles (append OR coalesced
-- replace-in-place). update_screen()/paint_screen() used to detect "did this
-- paint queue anything real" by comparing #pendingMessages before/after -
-- that broke once coalescing can replace an existing entry without changing
-- the queue's length, so they diff this counter instead.
queuedDisplayOps = 0

-- What MainStage has loaded (from controller_select_patch), and the model for
-- both display modes below. currentConcert already existed before this
-- feature and is reused rather than adding a parallel concertName.
-- 'zoom' is the only active mode for now. A 7-row calibration screen (each
-- row a full-width Write Text, one message per ~100ms flush) showed rows
-- 0/2/4/6 painted and rows 1/3/5 BLACK - never painted, full width, so every
-- SECOND display message is being lost in transmission, not geometry (a
-- geometry bug would leave only the last row visible). Leading theory: the
-- SL88 drops a message that arrives while it is still painting the previous
-- one, the same shape as this file's "Clear Screen races the draws that
-- follow it" finding. The list screen's per-flush cadence is exactly the
-- shape that would trip this, so it stays parked - not deleted, see
-- paint_list_screen() - until that alternating-loss finding is understood.
displayMode = 'zoom' -- or 'list' (parked - see comment above)

activeSetIndex = 0
activePatchIndex = 0
currentConcert = ''
setName = ''
patchName = ''

-- The set being browsed and the row the cursor sits on. Phase 2 moves these
-- independently of the active patch (joystick navigation); Phase 1 has no
-- wired input for that, so controller_select_patch simply keeps them tracking
-- whatever MainStage just loaded.
browseSetIndex = 0
cursorIndex = 0
scrollOffset = 0

patchRows = {} -- { {label=..., setIndex=..., patchIndex=...}, ... } for browseSetIndex

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
-- repaint drains at: one display message every FLUSH_SOON_MS. Left at 100 in
-- this change - retuning it is a separate, later experiment.
FLUSH_SOON_MS = 100

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
				print('[sllink][spike] coalesced regionId=' .. tostring(regionId) ..
				      ' (queue depth now ' .. #pendingMessages .. ')')
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
	if #pendingMessages > 0 then
		local m = pendingMessages[1]
		local isDisplay = (m[8] == IT_DISPLAY)
		if (not isDisplay or displayFlushReady) and #m + reserve <= FLUSH_BUDGET then
			table.remove(pendingMessages, 1)
			for i = 1, #m do out[#out + 1] = m[i] end
			if isDisplay then displayFlushReady = false end
			flushCounter = flushCounter + 1
			print('[sllink][spike] FLUSH #' .. flushCounter ..
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
-- ROW_NEEDS_BACKING_RECT below for the one place this project needs that escape hatch.

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

ROW_COUNT = 7
ROW_Y0 = 52
ROW_PITCH = 27
ROW_X = 8
ROW_MAXW = 304

-- FOUND ON HARDWARE (2026-08-19): a long patch name at SIZE_BIG with
-- maxWidth=304 rendered as a SINGLE LETTER followed by "...". The SL88's own
-- Max Width truncation is evidently unreliable at big size, so the zoom
-- screen no longer relies on it (maxWidth=0, "print it all" per
-- docs/implementing-sl-link.md) and instead wraps the name across two lines
-- itself - see wrap_two_lines() and paint_zoom_screen().
--
-- PROVISIONAL - this is an estimate, not a measurement: nothing here reads
-- actual glyph widths, so it is a guess at how many SIZE_BIG characters fit
-- in the zoom screen's width before the real thing gets recalibrated on
-- hardware. If a two-line name still overflows visually (or has room to
-- spare), retune this single constant - nothing else needs to change.
BIG_CHARS_PER_LINE = 20

-- TEMPORARY SPIKE INSTRUMENTATION - remove once row geometry is settled.
--
-- Hypothesis under test: Write Text paints an OPAQUE background box TALLER
-- than ROW_PITCH (27px), so each row's background erases the row drawn
-- above it - matching the hardware symptoms of a full repaint showing
-- mostly-black rows, a selected row "appearing" because nothing draws after
-- it to erase it, and stale text surviving a set switch until a row is
-- selected. When true, paint_list_screen() paints a calibration screen of 7
-- saturated, distinctly-coloured rows instead of the real list, so the
-- actual painted extent of each Write Text box is visible on the physical
-- screen. See paint_diag_row_extent() below.
DIAG_ROW_EXTENT = false

-- FOUND ON HARDWARE: controller_select_patch used to set cursorIndex without
-- ever touching scrollOffset, which stayed 0 forever - so on any set with
-- more than ROW_COUNT patches, selecting patch 8+ left the highlight off the
-- visible window entirely (nothing on screen looked selected). Keeps
-- scrollOffset such that cursorIndex is always inside the visible window
-- [scrollOffset, scrollOffset + ROW_COUNT). Edge-triggered, NOT re-centring:
-- the window moves the minimum amount needed to keep the cursor in view,
-- because a scroll costs a full ROW_COUNT-row repaint where an in-window
-- cursor move costs 2 messages (docs/full-functionality-plan.md Phase 1).
-- Standalone rather than inlined into controller_select_patch so Phase 2's
-- joystick-driven cursor movement can call it too instead of re-deriving the
-- same clamp arithmetic.
function clamp_scroll()
	if cursorIndex < scrollOffset then
		scrollOffset = cursorIndex
	elseif cursorIndex >= scrollOffset + ROW_COUNT then
		scrollOffset = cursorIndex - ROW_COUNT + 1
	end
	local maxOffset = math.max(0, #patchRows - ROW_COUNT)
	if scrollOffset > maxOffset then scrollOffset = maxOffset end
	if scrollOffset < 0 then scrollOffset = 0 end
end

ROW_NORMAL = 0
ROW_ACTIVE = 1
ROW_CURSOR = 2
ROW_CURSOR_ACTIVE = 3

-- { fr, fg, fb, br, bg, bb } per row state - SLLinkDisplay.swift's design table.
ROW_COLORS = {
	[ROW_NORMAL]        = { 150, 150, 150,   0,   0,   0 },
	[ROW_ACTIVE]         = { 255, 170,  40,   0,   0,   0 },
	[ROW_CURSOR]          = {   0,   0,   0, 255, 255, 255 },
	[ROW_CURSOR_ACTIVE]   = {   0,   0,   0, 255, 170,  40 },
}

-- UNVERIFIED on hardware: whether Write Text's background fills the WHOLE Max
-- Width x line-height box, or only the glyph run. If only the glyphs, an
-- inverted row would show a white/amber bar only as wide as the text instead
-- of a full bar. Default false (rely on the fill). Flip this after the
-- hardware probe in the design doc ("the one thing this design depends on")
-- if the fill turns out to only track glyphs.
ROW_NEEDS_BACKING_RECT = false

-- Single entry point for row drawing so ROW_NEEDS_BACKING_RECT is honoured in
-- exactly one place. `label` is passed in rather than looked up from
-- patchRows here, because the caller is responsible for scrollOffset.
function draw_row(i, label, state)
	local y = ROW_Y0 + ROW_PITCH * i
	local c = ROW_COLORS[state]
	local fr, frg, frb, brr, brg, brb = c[1], c[2], c[3], c[4], c[5], c[6]
	local id = 'row' .. i

	if ROW_NEEDS_BACKING_RECT then
		-- Fallback if the probe finds the text background does NOT fill the
		-- whole box: paint a backing rect first, then the text on top. The
		-- rect and text now overlap by construction, so per the non-overlap
		-- rule above they are memoized and resent as ONE unit under a single
		-- id - draw_rect/draw_text alone would let one half go stale relative
		-- to the other, so this checks a combined tuple by hand instead of
		-- calling them.
		-- Both messages share the drawn[] memo under the same `id`: they are
		-- one unit under the non-overlap rule, so dropping either one
		-- (drop_queued_display) must invalidate drawn[id] for both, not just
		-- whichever one happened to be discarded - see base_region_id().
		--
		-- But queue_message's regionId is now also a COALESCING key, and the
		-- rect and text must coalesce INDEPENDENTLY of each other - keying
		-- both under plain `id` would let a second draw's text replace the
		-- first draw's rect in the queue, silently losing the rect half. So
		-- they get distinct internal keys derived from `id` (id..':rect',
		-- id..':text'): each coalesces only against its own kind, while both
		-- still resolve back to the same logical region for the memo and for
		-- drop_queued_display (base_region_id strips the suffix).
		local t = { label, fr, frg, frb, brr, brg, brb }
		if tuple_equal(drawn[id], t, #t) then return end
		drawn[id] = t
		queue_message(msg_draw_rect(0, y - 1, SCREEN_WIDTH, 25, brr, brg, brb), id .. ':rect')
		queue_message(msg_write_text(label, ROW_X, y, ROW_MAXW, ALIGN_LEFT, SIZE_SMALL,
			fr, frg, frb, brr, brg, brb), id .. ':text')
	else
		draw_text(id, label, ROW_X, y, ROW_MAXW, ALIGN_LEFT, SIZE_SMALL,
			fr, frg, frb, brr, brg, brb)
	end
end

-- Two-line header: concert (dim, outermost context, changes least often) over
-- set name + position counter. ALIGN_RIGHT (0x02, docs/implementing-sl-link.md)
-- right-aligns hdrpos inside its narrow box against the right margin.
function draw_header()
	draw_text('hdrcnc', currentConcert, 8, 2, 304, ALIGN_LEFT, SIZE_SMALL, 120, 120, 120, 0, 0, 0)
	draw_text('hdrset', setName, 8, 25, 232, ALIGN_LEFT, SIZE_SMALL, 110, 170, 230, 0, 0, 0)
	local n = #patchRows > 0 and (cursorIndex + 1) or 0
	draw_text('hdrpos', n .. '/' .. #patchRows, 248, 25, 64, ALIGN_RIGHT, SIZE_SMALL,
		110, 170, 230, 0, 0, 0)
end

-- TEMPORARY SPIKE INSTRUMENTATION - see DIAG_ROW_EXTENT above; remove this
-- table and paint_diag_row_extent() together once the measurement is done.
--
-- One distinct, saturated background colour per row (8-bit RGB; append_rgb
-- halves to the wire's 7-bit-per-channel form) so the actual painted extent
-- of each row's Write Text box is visible on hardware even where it
-- oversteps ROW_PITCH into a neighbour.
DIAG_ROW_COLORS = {
	{ 255,   0,   0 }, -- red
	{   0, 180,   0 }, -- green
	{   0,  80, 255 }, -- blue
	{ 220, 220,   0 }, -- yellow
	{ 255,   0, 255 }, -- magenta
	{   0, 200, 200 }, -- cyan
	{ 255, 255, 255 }, -- white
}

-- TEMPORARY SPIKE INSTRUMENTATION - see DIAG_ROW_EXTENT above.
--
-- Deliberately bypasses per-region memoization (drawn[]) and coalescing:
-- every row is queued UNCONDITIONALLY, every call, via a direct
-- queue_message(msg_write_text(...)) with no regionId, so nothing is ever
-- skipped as "unchanged" and nothing coalesces two calls together - the
-- colours themselves are the measurement, so every call must actually hit
-- the wire. Rows are queued strictly top to bottom (row 0 first), matching
-- the real code's draw order, because the overwrite behaviour under test
-- depends on that order. queuedDisplayOps is bumped by hand for each row
-- since queue_message only counts regionId'd calls - this is what makes
-- paint_screen()/update_screen()'s "did this queue anything real" check
-- (queuedDisplayOps > before) fire so the trailing sacrificial redraw still
-- runs for this path too.
function paint_diag_row_extent()
	for i = 0, ROW_COUNT - 1 do
		local y = ROW_Y0 + ROW_PITCH * i
		local c = DIAG_ROW_COLORS[(i % #DIAG_ROW_COLORS) + 1]
		queue_message(msg_write_text(i .. ' y=' .. y, ROW_X, y, ROW_MAXW, ALIGN_LEFT, SIZE_SMALL,
			0, 0, 0, c[1], c[2], c[3]))
		queuedDisplayOps = queuedDisplayOps + 1
	end
end

-- Draws the list screen's current model, memoized per region - repeat calls
-- with nothing changed queue nothing. No trailing sacrificial here - both
-- update_screen and paint_screen add it themselves, after calling this, via
-- queue_sacrificial_redraw() (see that function for why it now covers both
-- paths).
function paint_list_screen()
	draw_header()
	if DIAG_ROW_EXTENT then
		-- TEMPORARY: see DIAG_ROW_EXTENT above. Header still paints normally
		-- (memoized, as always) so the calibration run also shows whether the
		-- first row's box eats into it; only the rows themselves are replaced
		-- by the unconditional calibration paint.
		paint_diag_row_extent()
		return
	end
	for i = 0, ROW_COUNT - 1 do
		local row = patchRows[scrollOffset + i + 1]
		local label = row and row.label or ''
		local state = ROW_NORMAL
		if row ~= nil then
			local isActive = (row.setIndex == activeSetIndex and row.patchIndex == activePatchIndex)
			local isCursor = (scrollOffset + i == cursorIndex)
			if isCursor and isActive then state = ROW_CURSOR_ACTIVE
			elseif isCursor then state = ROW_CURSOR
			elseif isActive then state = ROW_ACTIVE
			end
		end
		draw_row(i, label, state)
	end
end

-- Wraps `text` across at most two lines for the zoom screen's SIZE_BIG patch
-- name (see BIG_CHARS_PER_LINE above for why maxWidth=0 pushed this wrap into
-- the script instead of leaving it to the SL88). Prefers a word boundary:
-- breaks at the LAST space at or before charsPerLine, so "Grand Piano Warm"
-- breaks after "Piano" rather than mid-word. A single word with no space in
-- that range is hard-split at exactly charsPerLine rather than overflowing
-- the line. Anything left over after two lines is dropped, not wrapped to a
-- third - the zoom screen has room for exactly two.
--
-- Returns line2 = '' (never nil) when the whole name fits on line 1, so the
-- caller always has a real string to draw into the second region - drawing
-- an explicit empty string is what clears a STALE line 2 left over from a
-- previous, longer name; skipping the draw would leave it on screen (see
-- draw_text's memoization comment - a caller-side "don't bother" skip and a
-- content-driven memoization skip look identical from here, but only the
-- latter is safe).
function wrap_two_lines(text, charsPerLine)
	text = text or ''
	if #text <= charsPerLine then
		return text, ''
	end

	local breakAt = nil
	for i = charsPerLine, 1, -1 do
		if text:sub(i, i) == ' ' then
			breakAt = i
			break
		end
	end

	local line1, rest
	if breakAt then
		line1 = text:sub(1, breakAt - 1)
		rest = text:sub(breakAt + 1)
	else
		-- No space at or before the limit: one word longer than charsPerLine.
		-- Hard-split it rather than letting it overflow the line.
		line1 = text:sub(1, charsPerLine)
		rest = text:sub(charsPerLine + 1)
	end
	-- Whatever doesn't fit on line 2 is dropped - no third line.
	local line2 = rest:sub(1, charsPerLine)
	return line1, line2
end

-- Draws the zoom screen's current model, memoized per region. Shows the
-- ACTIVE patch, not the cursor - "what am I playing right now". The patch
-- name is wrapped across zname1/zname2 (see wrap_two_lines) rather than
-- relying on the SL88's own Max Width truncation, which is unreliable at
-- SIZE_BIG (see BIG_CHARS_PER_LINE's comment) - both are drawn with
-- maxWidth=0 ("print it all", docs/implementing-sl-link.md) so nothing
-- double-truncates.
function paint_zoom_screen()
	draw_text('zcnc', currentConcert, 8, 12, 304, ALIGN_CENTER, SIZE_SMALL, 120, 120, 120, 0, 0, 0)
	draw_text('zset', setName, 8, 40, 304, ALIGN_CENTER, SIZE_SMALL, 110, 170, 230, 0, 0, 0)
	local nameLine1, nameLine2 = wrap_two_lines(patchName, BIG_CHARS_PER_LINE)
	draw_text('zname1', nameLine1, 8, 86, 0, ALIGN_CENTER, SIZE_BIG, 255, 255, 255, 0, 0, 0)
	draw_text('zname2', nameLine2, 8, 124, 0, ALIGN_CENTER, SIZE_BIG, 255, 255, 255, 0, 0, 0)
	local n = #patchRows > 0 and (cursorIndex + 1) or 0
	draw_text('zpos', n .. '/' .. #patchRows, 8, 176, 304, ALIGN_CENTER, SIZE_SMALL, 120, 120, 120, 0, 0, 0)
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
-- coalesces by regionId. The real hdrcnc/zcnc draw almost always sits
-- earlier in this exact same paint's queue (draw_header/paint_zoom_screen run
-- first); routing this through draw_text('hdrcnc', ...) would hand it that
-- SAME regionId and coalesce it into that earlier entry instead of appending
-- a distinct trailing message - collapsing the one thing this mechanism
-- exists to guarantee (a disposable duplicate strictly AFTER everything real)
-- back into whatever position the real draw happened to queue at. A nil
-- regionId always appends (see queue_message), which is exactly "trailing".
-- No memo bookkeeping needed here either: drawn['hdrcnc']/['zcnc'] already
-- holds the correct content from the real draw this call is shadowing.
function queue_sacrificial_redraw()
	if displayMode == 'zoom' then
		queue_message(msg_write_text(currentConcert, 8, 12, 304, ALIGN_CENTER, SIZE_SMALL,
			120, 120, 120, 0, 0, 0))
	else
		queue_message(msg_write_text(currentConcert, 8, 2, 304, ALIGN_LEFT, SIZE_SMALL,
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

-- Mode switching. Not wired to the Zoom button yet - its BID is unconfirmed
-- (full-functionality-plan.md Q7) - so this is only reachable from the
-- harness or a future callback. Clear Screen stays banned, so the erase is a
-- single full-screen black rect, which is the only message in its flush and
-- therefore already has ~100ms of quiet after it structurally, unlike the old
-- Clear Screen failure which was bundled into a repaint. Verify on hardware
-- anyway before wiring a button to this.
function set_display_mode(mode)
	if mode ~= 'list' and mode ~= 'zoom' then return end
	displayMode = mode
	drop_queued_display()
	invalidate_all()
	queue_message(msg_draw_rect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 0, 0, 0))
	if mode == 'zoom' then
		paint_zoom_screen()
	else
		paint_list_screen()
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
		print('[sllink][spike] re-identify retry ' ..
		      (MAX_SAME_ID_RETRIES - reidentifyRetriesLeft) .. '/' .. MAX_SAME_ID_RETRIES ..
		      ' as (' .. string.format('%02X %02X', SL_HOST_ID, instanceID) .. ')')
		return
	end

	instanceID = instanceID + 1
	if instanceID > 0x7E then instanceID = 0x10 end
	reidentifyRetriesLeft = MAX_SAME_ID_RETRIES
	print('[sllink][spike] bumping instance to ' ..
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
	else
		-- SPIKE INSTRUMENTATION (Q2/Q7, docs/full-functionality-plan.md) - remove
		-- or gate once the spike answers whether Button/Encoder frames reach us
		-- at all, and which BID the Zoom button sends. Everything else that
		-- reaches here previously fell through in total silence.
		if itemType == IT_BUTTON then
			local pressKind = (e[9] == 0x01 and 'SHORT') or (e[9] == 0x02 and 'LONG') or tostring(e[9])
			print('[sllink][spike] <- BUTTON bid=' .. string.format('0x%02X', e[8])
				.. ' event=' .. pressKind .. ' frame=' .. dump_event(e))
		elseif itemType == IT_ENCODER then
			local delta = e[9] - 0x40
			print('[sllink][spike] <- ENCODER eid=' .. string.format('0x%02X', e[8])
				.. ' tick=' .. string.format('0x%02X', e[9])
				.. ' delta=' .. tostring(delta) .. ' frame=' .. dump_event(e))
		else
			print('[sllink][spike] <- unhandled itemType=' .. string.format('0x%02X', itemType)
				.. ' frame=' .. dump_event(e))
		end
	end
end

-- MARK: - MainStage callbacks

function controller_initialize(applicationName, deviceNewlyDetected)
	settriggertimer(KEEPALIVE_MS)
	state = STATE_IDLE
	instanceID = SL_INSTANCE_START
	reidentifyRetriesLeft = MAX_SAME_ID_RETRIES
	pendingMessages = {}
	displayMode = 'zoom' -- see the displayMode declaration above for why
	patchName, setName, currentConcert = '', '', ''
	activeSetIndex, activePatchIndex = 0, 0
	browseSetIndex, cursorIndex, scrollOffset = 0, 0, 0
	patchRows = {}
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
	settriggertimer(KEEPALIVE_MS)
	timerTicks = timerTicks + 1

	-- DEFECT A FIX: grant this tick's one-display-message permit. See
	-- displayFlushReady's declaration for why this exists and what it fixes.
	-- If nothing is queued this tick simply arrives and leaves unconsumed -
	-- harmless, and means the next thing queued gets to go out immediately
	-- rather than waiting for a tick it had nothing to do with.
	displayFlushReady = true
	-- Only ticks that arrive at the full keepalive cadence count towards the
	-- periodic refresh; fast drain ticks must not.
	if not has_pending() then idleTicks = idleTicks + 1 end
	print('[sllink] timer tick #' .. timerTicks .. ' (idle ' .. idleTicks .. ') state=' .. state)

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
	elseif not has_pending() then
		-- Only send the keepalive when no display work is queued.
		--
		-- Bundling a System Device Notification (00/00) into the same array as
		-- a Write Text makes the SL88 discard the drawing: measured repeatedly,
		-- a repaint drained as
		--     F1 [clear, text]            -> rendered
		--     F2 [text, query 7F/03]      -> rendered
		--     F3 [text, keepalive 00/00]  -> NOT rendered
		-- and swapping the draw order moved the failure to whichever text
		-- landed in that last keepalive-bearing flush. The Identification Query
		-- rides along with display messages perfectly happily, and it is what
		-- actually drives the session clock, so deferring the keepalive until
		-- the queue is empty costs nothing.
		send_keepalive()
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
	if has_pending() then
		settriggertimer(FLUSH_SOON_MS) -- still draining a repaint; come back soon
	else
		settriggertimer(KEEPALIVE_MS)
	end
end

function controller_midi_in(midiEvent, portName)
	if midiEvent[0] == 0xF0 then
		print('[sllink] <- SYSEX on port=' .. tostring(portName) .. ': ' .. dump_event(midiEvent))
	end

	-- SPIKE INSTRUMENTATION (Q2, docs/full-functionality-plan.md) - checking
	-- whether the SL88's buttons also reach us as plain channel-voice MIDI,
	-- alongside (or instead of) SL Link SysEx. Remove or gate once answered.
	-- Deliberately CC/PC only: Note On/Off, pitch bend, aftertouch and clock
	-- fire continuously while the keyboard is played and would flood the log,
	-- burying the signal this spike actually needs. Do not widen this to
	-- other status bytes without re-adding a rate limit.
	if midiEvent[0] ~= nil and midiEvent[0] >= 0xB0 and midiEvent[0] <= 0xCF then
		local status = midiEvent[0]
		local channel = (status % 0x10) + 1 -- 1-based, matches how the UI names channels
		local kind = (status < 0xC0) and 'CC' or 'PC'
		print('[sllink][spike] <- ' .. kind .. ' on port=' .. tostring(portName)
			.. ' ch=' .. tostring(channel)
			.. ' data=' .. tostring(midiEvent[1]) .. ',' .. tostring(midiEvent[2]))
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

patchlistDumped = false -- guards the one-time debug dump below, see controller_select_patch
patchLabelKeyLogged = false -- guards the one-time patch_label() key-resolution log below
patchFieldKeyLogged = {} -- per-field one-time key-resolution log guard, see patch_field()

-- SPIKE INSTRUMENTATION - candidate-key lookups for patchlist entries. Real
-- field names were never confirmed against hardware (the design doc assumed
-- .Label; the code before this used .Name; neither was right, hence the
-- blank orange highlight bar observed on 2026-08-19). These try the
-- plausible spellings in order and self-report which one won, once, so the
-- next hardware round-trip both fixes the bug and answers the question
-- instead of needing a follow-up spike.
function patch_label(entry)
	local candidates = { 'Label', 'Name', 'label', 'name', 'PatchName', 'patchname' }
	if type(entry) == 'table' then
		for _, key in ipairs(candidates) do
			local v = entry[key]
			if type(v) == 'string' and v ~= '' then
				if not patchLabelKeyLogged then
					patchLabelKeyLogged = true
					print('[sllink][spike] patch_label: using key "' .. key .. '"')
				end
				return v
			end
		end
	end
	if not patchLabelKeyLogged then
		patchLabelKeyLogged = true
		local keys = {}
		if type(entry) == 'table' then
			for k in pairs(entry) do keys[#keys + 1] = tostring(k) end
		end
		print('[sllink][spike] patch_label: NO candidate key matched (tried ' ..
		      table.concat(candidates, ', ') .. '), entry keys = { ' ..
		      table.concat(keys, ', ') .. ' } - falling back to tostring()')
	end
	return tostring(entry)
end

-- Same idea for the fields the set/patch filter depends on. Tries the
-- capitalised spelling (per the design doc) then the all-lowercase one;
-- logs which won, once per field name, since if the label key was wrong
-- these may be too - and if they are, the "N rows in set" count downstream
-- is wrong along with them. Returns nil (not false) when neither variant is
-- present, so a genuinely-false IsPatch is distinguishable from a missing key.
function patch_field(entry, field)
	if type(entry) ~= 'table' then return nil end
	local candidates = { field, field:lower() }
	for _, key in ipairs(candidates) do
		local v = entry[key]
		if v ~= nil then
			if not patchFieldKeyLogged[field] then
				patchFieldKeyLogged[field] = true
				print('[sllink][spike] patch_field(' .. field .. '): using key "' .. key .. '"')
			end
			return v
		end
	end
	if not patchFieldKeyLogged[field] then
		patchFieldKeyLogged[field] = true
		print('[sllink][spike] patch_field(' .. field .. '): NEITHER "' .. field ..
		      '" nor "' .. field:lower() .. '" present')
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

	-- SPIKE INSTRUMENTATION - one-time dump of the raw patchlist structure,
	-- so the field names below (IsPatch/SetIndex/Name/PatchIndex) can be
	-- confirmed against what MainStage actually sends rather than trusted
	-- from the docs. Only latches patchlistDumped once we've actually
	-- dumped a NON-EMPTY list: MainStage's first call happens before the
	-- concert has loaded, so patchlist is empty/nil then - latching on that
	-- call burned the one shot without ever printing a real entry (observed
	-- on hardware 2026-08-19). pcall-guarded so a nil/odd entry can't throw
	-- and kill the callback outright.
	if not patchlistDumped then
		local ok, err = pcall(function()
			local n = 0
			if type(patchlist) == 'table' then
				for _ in pairs(patchlist) do n = n + 1 end
			end
			if n == 0 then
				return -- empty/nil this call; try again next call, don't latch yet
			end
			patchlistDumped = true
			print('[sllink][spike] controller_select_patch: one-time patchlist dump' ..
			      ' (n=' .. n ..
			      ' currentSetIndex=' .. tostring(currentSetIndex) ..
			      ' currentPatchIndex=' .. tostring(currentPatchIndex) .. ')')
			local shown = 0
			for k, entry in pairs(patchlist) do
				shown = shown + 1
				if shown > 5 then break end
				print('[sllink][spike]   patchlist[' .. tostring(k) .. '] raw = ' .. tostring(entry))
				if type(entry) == 'table' then
					for fk, fv in pairs(entry) do
						print('[sllink][spike]     ' .. tostring(fk) .. ' (' .. type(fv) ..
						      ') = ' .. tostring(fv))
					end
				else
					print('[sllink][spike]     (entry is not a table - type=' .. type(entry) .. ')')
				end
			end
		end)
		if not ok then
			print('[sllink][spike] controller_select_patch: patchlist dump FAILED: ' .. tostring(err))
		end
	end

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
	-- Phase 1 has no independent browsing/cursor input yet (deferred to
	-- Phase 2's joystick handling) - both simply track the active patch.
	browseSetIndex = activeSetIndex
	cursorIndex = activePatchIndex

	-- Field names resolved via patch_label()/patch_field() above rather than
	-- trusted directly (that's what made the highlight bar blank - see
	-- those functions' comments). patchIndex falls back to the pairs() key
	-- when PatchIndex/patchindex is genuinely absent, same as before.
	patchRows = {}
	if patchlist ~= nil then
		for i, entry in pairs(patchlist) do
			local isPatch = patch_field(entry, 'IsPatch')
			local setIndex = patch_field(entry, 'SetIndex')
			if type(entry) == 'table' and isPatch and setIndex == browseSetIndex then
				local patchIndex = patch_field(entry, 'PatchIndex')
				patchRows[#patchRows + 1] = {
					label = patch_label(entry),
					setIndex = setIndex,
					patchIndex = patchIndex or i,
				}
			end
		end
	end

	-- currentConcert/setName added alongside the existing fields so a blank
	-- concert line on the SL88 screen can be told apart from a draw failure
	-- (2026-08-19 hardware run: concert line never appeared, cause unknown).
	print('[sllink] controller_select_patch: "' .. patchName .. '" (' .. #patchRows .. ' rows in set)' ..
	      ' concert="' .. currentConcert .. '" set="' .. setName .. '"')

	-- Keep the visible window on the newly-set cursor - must run after
	-- patchRows is rebuilt above (clamp_scroll's upper bound depends on
	-- #patchRows) and before the repaint below.
	clamp_scroll()

	if state == STATE_REIDENTIFY_WAIT then
		-- Don't queue or flush anything while waiting to retry identification
		-- (see handle_identification_rejected) - a flush here would send an
		-- Identification Query under an instanceID the SL88 just rejected,
		-- which would defeat the wait (see controller_midi_in's comment on the
		-- same hazard). The bookkeeping above (patchName/patchRows/etc.) still
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
