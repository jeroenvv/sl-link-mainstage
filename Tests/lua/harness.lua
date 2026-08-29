-- Offline regression harness for MainStageScript/STUDIOLOGIC/SL.device/config.lua.
--
-- Plain top-level assertions (no test framework), run by `lua`, the same
-- "why not XCTest" shape as Tests/SLLinkCodecTests.swift (see that file /
-- Scripts/run-codec-tests.sh for the rationale: no Xcode test target).
--
-- config.lua is driven directly - it is plain Lua, no CoreMIDI, no MainStage
-- - by stubbing exactly what MainStage injects (settriggertimer, the MIDI_*
-- constants) per .claude/skills/lua-harness/SKILL.md. Byte-shape assertions
-- (golden vectors) are cross-checked against SL-Link-Mainstage/SLLink/
-- SLLinkEncoder.swift separately - see Scripts/run-lua-tests.sh's header.
--
-- Run via Scripts/run-lua-tests.sh, not directly - that script also gates on
-- `luac -p` first. Path to config.lua is passed as arg[1].

-- MARK: - MainStage stubs (see docs/mainstage-device-scripts.md §7: `io`/`os`
-- do not exist in the real sandbox - config.lua must never touch them, but
-- this HARNESS is plain `lua`, so using `os.exit` etc. here is fine)

MIDI_Wildcard, MIDI_MSB, MIDI_LSB = 0, 0, 0
armed = nil
function settriggertimer(ms) armed = ms end

-- config.lua's own print() noise (session/flush/CC-batch logging) is
-- silenced by default so PASS/FAIL stays readable - SLLINK_VERBOSE=1 turns
-- it back on, e.g. while chasing a failing assertion.
local realPrint = print
local verbose = os.getenv('SLLINK_VERBOSE') == '1'
if not verbose then
	print = function() end
end

local configPath = arg[1] or 'MainStageScript/STUDIOLOGIC/SL.device/config.lua'
dofile(configPath)

-- MARK: - Helpers (SKILL.md)

-- MainStage passes inbound MIDI events as 0-indexed tables; frame(...)
-- converts a 1-indexed varargs list to match.
local function frame(...)
	local a, e = { ... }, {}
	for i, v in ipairs(a) do e[i - 1] = v end
	return e
end

local function hex(t)
	local s = {}
	for i = 1, #t do s[#s + 1] = string.format('%02X', t[i]) end
	return table.concat(s, ' ')
end

-- The reply to our own Identification Query - what drives the session
-- clock (see config.lua's SESSION CLOCK note). Reads instanceID live so it
-- stays correct even if a test upstream has bumped it.
local function qreply()
	return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, 0x7F, 0x03, 0x01, 0xF7)
end

-- Splits a flat 1-indexed byte array (as returned in a flush's .midi field, which may carry
-- several F0...F7 messages concatenated - e.g. [display, query]) back into individual
-- per-message byte arrays, so a flush's CONTENTS can be inspected by itemType/function rather
-- than just its total length.
local function split_messages(bytes)
	local msgs, cur = {}, nil
	for i = 1, #bytes do
		local b = bytes[i]
		if b == 0xF0 then cur = {} end
		if cur then cur[#cur + 1] = b end
		if b == 0xF7 and cur then
			msgs[#msgs + 1] = cur
			cur = nil
		end
	end
	return msgs
end

-- itemType/function live at fixed offsets after the 7-byte header+ids (F0 00 20 1A 16 id1 id2) -
-- same indexing config.lua's own flush_pending uses (m[8]/m[9]).
local function item_type_of(msg) return msg[8] end
local function func_of(msg) return msg[9] end

-- MARK: - Test framework

local failures = {}
local passCount = 0

local function check(name, condition)
	if condition then
		passCount = passCount + 1
	else
		failures[#failures + 1] = name
		realPrint('FAIL: ' .. name)
	end
end

local function checkHex(name, actual, expectedHex)
	local actualHex = hex(actual)
	check(name, actualHex == expectedHex)
	if actualHex ~= expectedHex then
		realPrint('       actual:   ' .. actualHex)
		realPrint('       expected: ' .. expectedHex)
	end
end

-- MARK: - 1. Golden byte vectors for every msg_* builder
--
-- Cross-checked against SLLinkEncoder.swift by hand at id1=SL_HOST_ID
-- (0x03), id2=SL_INSTANCE_START (0x6D) - see Scripts/run-lua-tests.sh's
-- header for the swiftc invocation used to derive these. Do NOT "fix" one
-- of these to match whatever config.lua currently emits - a mismatch here
-- means the Lua codec has drifted from the Swift one, which is the exact
-- regression this harness exists to catch.

checkHex(
	'msg_identification_request',
	msg_identification_request(),
	'F0 00 20 1A 16 03 6D 7F 00 4D 61 69 6E 53 74 61 67 65 00 F7'
)

checkHex(
	'msg_identification_query',
	msg_identification_query(),
	'F0 00 20 1A 16 03 6D 7F 03 F7'
)

checkHex(
	'msg_system(SYS_DEVICE_NOTIFICATION)',
	msg_system(SYS_DEVICE_NOTIFICATION),
	'F0 00 20 1A 16 03 6D 00 00 F7'
)

checkHex(
	'msg_clear_screen(255, 128, 1)',
	msg_clear_screen(255, 128, 1),
	'F0 00 20 1A 16 03 6D 04 01 7F 40 00 F7'
)

checkHex(
	'msg_write_text("Hi!", ...)',
	msg_write_text('Hi!', 5, 6, 100, ALIGN_CENTER, SIZE_BIG, 255, 0, 0, 0, 255, 0),
	'F0 00 20 1A 16 03 6D 04 00 00 05 00 06 00 64 01 02 7F 00 00 00 7F 00 48 69 21 00 F7'
)

checkHex(
	'msg_draw_rect(10, 20, 30, 40, 200, 100, 50)',
	msg_draw_rect(10, 20, 30, 40, 200, 100, 50),
	'F0 00 20 1A 16 03 6D 04 02 00 0A 00 14 00 1E 00 28 64 32 19 F7'
)

-- Cross-checked against SLLinkEncoder.displayPlotBitmap(id1: 0x03, id2: 0x6D, x: 100, y: 50,
-- groupIndex: 0x00, iconIndex: 0x05, foreground: SLColor(r: 255, g: 140, b: 0),
-- background: SLColor(r: 0, g: 0, b: 0)) via the swiftc recipe in .claude/skills/lua-harness/
-- SKILL.md. groupIndex/iconIndex are single bytes (0x00, 0x05), NOT msb/lsb split, unlike x/y.
checkHex(
	'msg_plot_bitmap(100, 50, BMP_GROUP_KNOB, 5, 255, 140, 0, 0, 0, 0)',
	msg_plot_bitmap(100, 50, BMP_GROUP_KNOB, 5, 255, 140, 0, 0, 0, 0),
	'F0 00 20 1A 16 03 6D 04 03 00 64 00 32 00 05 7F 46 00 00 00 00 F7'
)

-- MARK: - 2. Flush budget
--
-- Every flush_pending(true) must stay <= FLUSH_BUDGET and end with an
-- Identification Query - its reply is the only thing that re-arms the
-- session clock (see flush_pending's comment), so a flush that queued one
-- without carrying it would silently stall the whole session.
do
	pendingMessages = {}
	invalidate_all()
	displayFlushReady = true
	queue_message(msg_draw_rect(0, 0, 10, 10, 0, 0, 0), 'test:flush-budget')

	local out = flush_pending(true)
	check('flush_pending(true) returns output when something is queued', out ~= nil and out.midi ~= nil)
	if out then
		check('flush_pending(true) respects FLUSH_BUDGET', #out.midi <= FLUSH_BUDGET)

		local query = msg_identification_query()
		local tail = {}
		for i = #out.midi - #query + 1, #out.midi do tail[#tail + 1] = out.midi[i] end
		check('flush_pending(true) ends with the Identification Query', hex(tail) == hex(query))
	end
end

-- MARK: - 3. Queue convergence
--
-- A full repaint must drain to zero rather than growing - the exact failure
-- mode a runaway repaint loop (see REPAINT_EVERY_IDLE_TICKS's comment)
-- produces. displayFlushReady is re-granted each iteration to stand in for
-- controller_timer_trigger's one-tick, one-display-message pacing grant.
do
	displayMode = 'zoom'
	patchName, setName, currentConcert = 'Test Patch', 'Test Set', 'Test Concert'
	pendingMessages = {}
	invalidate_all()
	paint_screen()

	local flushes, cap = 0, 200
	displayFlushReady = true
	while has_pending() and flushes <= cap do
		flushes = flushes + 1
		flush_pending(true)
		displayFlushReady = true
	end

	check(
		'queue convergence: a full repaint drains to zero within ' .. cap .. ' flushes (not growing)',
		not has_pending() and flushes <= cap and flushes > 0
	)
end

-- MARK: - 4. Musical MIDI passthrough
--
-- controller_midi_in must return nil for ordinary musical MIDI - returning
-- a table swallows the event and hangs notes (file-header rule set).
do
	state = STATE_ACTIVE
	timerPending = false
	local result = controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	check('musical MIDI (Note On) passes through untouched (returns nil)', result == nil)
end

-- MARK: - 5. Program Change swallowed
--
-- patchselector, not this script, drives patch selection - Program Change
-- must be swallowed with an empty midi array, not passed through and not
-- left nil (nil would let it double up with patchselector's own handling).
do
	timerPending = false
	local result = controller_midi_in(frame(0xC0, 0x05), 'LINK')
	check('Program Change is swallowed (returns a table)', type(result) == 'table')
	check(
		'Program Change swallowed with an empty midi array',
		result ~= nil and type(result.midi) == 'table' and #result.midi == 0
	)
end

-- MARK: - 6. CC batch cap
--
-- flush_pending_cc() must emit exactly CC_BATCH_CAP controls per call and
-- leave the rest queued for the next round - not drop them, not truncate an
-- oversized array into MainStage's byte ceiling (see CC_BATCH_CAP's comment).
do
	pendingCC = {}
	pendingCCOrder = {}

	local controls = {}
	for key in pairs(CC_MAP) do controls[#controls + 1] = key end
	table.sort(controls) -- deterministic order, independent of pairs()'s own order

	local queuedCount = CC_BATCH_CAP + 5 -- comfortably over the cap
	check('CC_MAP has enough distinct controls for this test', #controls >= queuedCount)
	for i = 1, queuedCount do
		queue_cc(controls[i], 64)
	end

	local result = flush_pending_cc()
	check('flush_pending_cc emits exactly CC_BATCH_CAP * 3 bytes', #result.midi == CC_BATCH_CAP * 3)
	check(
		'flush_pending_cc leaves the remainder queued rather than dropping it',
		#pendingCCOrder == queuedCount - CC_BATCH_CAP
	)
	check(
		'a deferred control keeps its queued value',
		pendingCC[controls[queuedCount]] == 64
	)
end

-- MARK: - 7. clamp_scroll page-jump behaviour
--
-- Walks cursorIndex forward one row at a time over a synthetic ~40-row list
-- and checks the three invariants the design doc derives SCROLL_MARGIN/
-- PAGE_OVERLAP from: the cursor stays inside the visible window, the offset
-- stays inside the list, and consecutive single-row steps do not each
-- trigger a scroll (the one-row-shift policy this replaced did exactly
-- that - see clamp_scroll's ABANDONED comment).
do
	listRows = {}
	for i = 1, 40 do
		listRows[i] = { label = 'Row ' .. i, isPatch = true, setIndex = 0, patchIndex = i - 1 }
	end
	cursorIndex = 0
	scrollOffset = 0

	local maxOffset = math.max(0, #listRows - ROW_COUNT)
	local windowOk, offsetOk = true, true
	local jumpSteps = {}

	for step = 1, #listRows - 1 do
		cursorIndex = step
		local before = scrollOffset
		clamp_scroll()
		if cursorIndex < scrollOffset or cursorIndex >= scrollOffset + ROW_COUNT then
			windowOk = false
		end
		if scrollOffset < 0 or scrollOffset > maxOffset then
			offsetOk = false
		end
		if scrollOffset ~= before then
			jumpSteps[#jumpSteps + 1] = step
		end
	end

	check('clamp_scroll: cursorIndex always stays within [scrollOffset, scrollOffset + ROW_COUNT)', windowOk)
	check('clamp_scroll: scrollOffset always stays within [0, #listRows - ROW_COUNT]', offsetOk)
	check('clamp_scroll: at least one page jump occurs walking the whole list', #jumpSteps > 0)

	-- Once triggered, clamp_scroll moves the window by (ROW_COUNT - PAGE_OVERLAP)
	-- rows (see its comment) - so two page jumps can never be closer together
	-- than that, which is exactly "does not scroll on every single-row step".
	local minGap = ROW_COUNT - PAGE_OVERLAP
	local noOscillation = true
	for i = 2, #jumpSteps do
		if (jumpSteps[i] - jumpSteps[i - 1]) < minGap then noOscillation = false end
	end
	check(
		'clamp_scroll: page jumps stay at least (ROW_COUNT - PAGE_OVERLAP) steps apart (no oscillation)',
		noOscillation
	)
end

-- MARK: - 8. Repaint rate
--
-- Simulates many timer-tick/query-reply rounds with nothing changing (the
-- self-heal path in handle_sl_frame's ID_QUERY branch, gated on `due`, is
-- the only thing that calls paint_screen() once screenDirty is primed
-- false and lastPaintedPatch matches - see controller_timer_trigger and
-- REPAINT_EVERY_IDLE_TICKS's comment for why this must be a RATE, not a
-- per-tick repaint).
do
	displayMode = 'zoom'
	patchName, setName, currentConcert = 'Steady Patch', 'Steady Set', 'Steady Concert'
	lastPaintedPatch = patchName -- primes "not stale", isolating the periodic (due) path
	state = STATE_ACTIVE
	pendingMessages = {}
	idleTicks = 0
	lastPaintTick = 0
	timerPending = false
	displayFlushReady = true

	local originalPaintScreen = paint_screen
	local paintCalls = 0
	paint_screen = function()
		paintCalls = paintCalls + 1
		originalPaintScreen()
	end

	local rounds = REPAINT_EVERY_IDLE_TICKS * 4
	for _ = 1, rounds do
		controller_timer_trigger()
		controller_midi_in(qreply(), 'LINK')

		-- Drain whatever this round queued (a keepalive, and a full repaint's
		-- worth of display messages on a `due` round) so idleTicks keeps
		-- incrementing normally on the next round - see convergence test above.
		local drains, drainCap = 0, 100
		while has_pending() and drains < drainCap do
			flush_pending(true)
			displayFlushReady = true
			drains = drains + 1
		end
	end

	paint_screen = originalPaintScreen

	check(
		'repaint rate: paint_screen fires at idleTicks / REPAINT_EVERY_IDLE_TICKS, not every tick',
		paintCalls == math.floor(idleTicks / REPAINT_EVERY_IDLE_TICKS)
	)
	check('repaint rate: does not repaint on every tick', paintCalls < rounds)
end

-- MARK: - 9. Timer re-arm interval
--
-- rearm_timer() must choose FLUSH_SOON_MS while draining, KEEPALIVE_MS when
-- idle, and POPUP_TICK_MS while the encoder popup is active and idle - see
-- that function's comment and POPUP_TICK_MS's declaration.
do
	state = STATE_ACTIVE

	pendingMessages = {}
	queue_message(msg_draw_rect(0, 0, 1, 1, 0, 0, 0), 'test:timer-rearm')
	popupActive = false
	timerPending = false
	armed = nil
	rearm_timer()
	check('rearm_timer: FLUSH_SOON_MS while draining', armed == FLUSH_SOON_MS)

	pendingMessages = {}
	popupActive = false
	timerPending = false
	armed = nil
	rearm_timer()
	check('rearm_timer: KEEPALIVE_MS when idle', armed == KEEPALIVE_MS)

	pendingMessages = {}
	popupActive = true
	timerPending = false
	armed = nil
	rearm_timer()
	check('rearm_timer: POPUP_TICK_MS while popupActive and idle', armed == POPUP_TICK_MS)
	popupActive = false
end

-- MARK: - 10. A flush never contains two display messages
--
-- flush_pending() dequeues at most ONE queued message per flush (see
-- config.lua's "the display, query flush shape" comment). Queues two
-- display messages under different regionIds (so they don't coalesce) and
-- checks the first flush's output carries only one of them - the second
-- stays queued for a later flush.
do
	pendingMessages = {}
	invalidate_all()
	displayFlushReady = true
	queue_message(msg_draw_rect(0, 0, 10, 10, 0, 0, 0), 'test:two-display-a')
	queue_message(msg_draw_rect(20, 20, 10, 10, 0, 0, 0), 'test:two-display-b')

	local out = flush_pending(true)
	local displayCount = 0
	if out then
		for _, m in ipairs(split_messages(out.midi)) do
			if item_type_of(m) == IT_DISPLAY then displayCount = displayCount + 1 end
		end
	end
	check('a flush never contains two display messages', displayCount <= 1)
	check('the second display message is still queued after one flush', has_pending())
end

-- MARK: - 11. A flush never bundles a display message with the keepalive
--
-- Covers both orderings: display queued ahead of a ready-to-send keepalive
-- (displayFlushReady true - the display goes, the keepalive waits), and a
-- display that can't go out yet with a keepalive behind it
-- (displayFlushReady false - flush_pending's scan-forward lets the keepalive
-- jump the queue instead, per its "DEFECT B" comment). Neither shape may
-- ever emit both itemTypes in the same flush.
do
	pendingMessages = {}
	invalidate_all()
	displayFlushReady = true
	queue_message(msg_draw_rect(0, 0, 10, 10, 0, 0, 0), 'test:display-then-keepalive')
	queue_message(msg_system(SYS_DEVICE_NOTIFICATION))

	local out1 = flush_pending(true)
	local d1, k1 = 0, 0
	if out1 then
		for _, m in ipairs(split_messages(out1.midi)) do
			if item_type_of(m) == IT_DISPLAY then d1 = d1 + 1 end
			if item_type_of(m) == IT_SYSTEM and func_of(m) == SYS_DEVICE_NOTIFICATION then k1 = k1 + 1 end
		end
	end
	check(
		'a flush never bundles a display message with the keepalive (display ready)',
		not (d1 >= 1 and k1 >= 1)
	)

	pendingMessages = {}
	invalidate_all()
	displayFlushReady = false
	queue_message(msg_draw_rect(0, 0, 10, 10, 0, 0, 0), 'test:display-blocked-keepalive-behind')
	queue_message(msg_system(SYS_DEVICE_NOTIFICATION))

	local out2 = flush_pending(true)
	local d2, k2 = 0, 0
	if out2 then
		for _, m in ipairs(split_messages(out2.midi)) do
			if item_type_of(m) == IT_DISPLAY then d2 = d2 + 1 end
			if item_type_of(m) == IT_SYSTEM and func_of(m) == SYS_DEVICE_NOTIFICATION then k2 = k2 + 1 end
		end
	end
	check(
		'a flush never bundles a display message with the keepalive (display blocked, keepalive jumps ahead)',
		not (d2 >= 1 and k2 >= 1)
	)
	check('the keepalive jumps ahead of a display message it cannot dequeue yet', k2 == 1)
	displayFlushReady = true
end

-- MARK: - 12. queue_message: regionId coalesces, protocol messages never do
do
	pendingMessages = {}
	invalidate_all()
	queue_message(msg_draw_rect(0, 0, 10, 10, 0, 0, 0), 'test:coalesce')
	queue_message(msg_draw_rect(0, 0, 10, 10, 5, 5, 5), 'test:coalesce')
	local coalescedCount = 0
	for i = 1, #pendingMessages do
		if pendingMessages[i].regionId == 'test:coalesce' then coalescedCount = coalescedCount + 1 end
	end
	check('queue_message coalesces two calls with the same regionId into one', coalescedCount == 1)

	pendingMessages = {}
	queue_message(msg_identification_query())
	queue_message(msg_identification_query())
	check(
		'queue_message never coalesces protocol messages (two queued Identification Queries both survive)',
		#pendingMessages == 2
	)
end

-- MARK: - 13. drop_queued_display clears the corresponding drawn[] entries
--
-- See config.lua's drop_queued_display comment: leaving a discarded message's
-- drawn[] entry in place lets the memo and the physical screen diverge for
-- good, since the region is never re-queued.
do
	pendingMessages = {}
	invalidate_all()
	draw_rect('test:drop-memo', 0, 0, 10, 10, 1, 2, 3)
	check('draw_rect primes drawn[] for the id it queues', drawn['test:drop-memo'] ~= nil)
	queue_message(msg_identification_query())

	drop_queued_display()
	check('drop_queued_display clears the drawn[] entry for a message it discards', drawn['test:drop-memo'] == nil)
	check(
		'drop_queued_display preserves protocol messages while dropping display ones',
		has_pending() and #pendingMessages == 1
	)
end

-- Same property, but for the id..':rect'/id..':text' split draw_text_with_erase
-- queues (see base_region_id's comment) rather than a plain id - drawn[] is
-- keyed on the UNSUFFIXED id while the two queued messages carry the suffixed
-- regionIds, so drop_queued_display must unwind the suffix via
-- base_region_id() to find the memo entry at all. A plain-id-only test cannot
-- catch a regression here, since base_region_id() is a no-op on a plain id.
do
	pendingMessages = {}
	invalidate_all()
	draw_text_with_erase('test:drop-memo-split', 'Hi', 0, 0, ALIGN_LEFT, SIZE_SMALL, 1, 2, 3, 0, 0, 10, 10)
	check(
		'draw_text_with_erase primes drawn[] under the UNSUFFIXED id',
		drawn['test:drop-memo-split'] ~= nil
	)
	check(
		'draw_text_with_erase queues both the :rect and :text halves',
		#pendingMessages == 2 and pendingMessages[1].regionId == 'test:drop-memo-split:rect' and
		pendingMessages[2].regionId == 'test:drop-memo-split:text'
	)

	drop_queued_display()
	check(
		'drop_queued_display clears the split id..":rect"/id..":text" pair back to the unsuffixed drawn[] entry',
		drawn['test:drop-memo-split'] == nil
	)
end

-- MARK: - 14. The trailing sacrificial redraw carries no regionId
--
-- A nil regionId always appends rather than coalescing (see queue_message) -
-- this is what guarantees the sacrificial redraw lands strictly AFTER
-- whatever real content this same paint queued, instead of coalescing into
-- an earlier entry for the same region. See queue_sacrificial_redraw's
-- comment.
--
-- queue_sacrificial_redraw has TWO branches - displayMode == 'zoom' draws the
-- concert line, and the else branch (list, popup - set_display_mode's mode
-- check confirms both reach this same function) draws the ctx bar via
-- ctx_text() - so this must be checked under every mode that reaches it, not
-- just zoom, or a regionId regression in the else branch goes uncaught. A
-- small synthetic listRows/cursorIndex is set up once so ctx_text()'s
-- dependency chain (cursor_set_label(), which reads listRows/cursorIndex)
-- produces a real string for the list/popup branch.
do
	listRows = {
		{ label = 'Test Set', isPatch = false },
		{ label = 'Test Patch', isPatch = true, setIndex = 0, patchIndex = 0 },
	}
	cursorIndex = 1
	currentConcert = 'Test Concert'

	for _, mode in ipairs({ 'zoom', 'list', 'popup' }) do
		pendingMessages = {}
		displayMode = mode
		queue_sacrificial_redraw()
		local last = pendingMessages[#pendingMessages]
		check('the trailing sacrificial redraw is queued (mode=' .. mode .. ')', last ~= nil)
		check(
			'the trailing sacrificial redraw carries no regionId (mode=' .. mode .. ')',
			last ~= nil and last.regionId == nil
		)
	end
end

-- MARK: - 15. controller_finalize returns nil and queues no Logout Request
--
-- A script can only send by RETURNING MIDI from a callback (see config.lua's
-- MainStage-host notes) - so a nil return is itself the guarantee that no
-- Logout Request (or anything else) goes out from this callback.
do
	state = STATE_ACTIVE
	pendingMessages = {}
	local result = controller_finalize()
	check('controller_finalize returns nil (no MIDI, so no Logout Request can go out)', result == nil)
end

-- MARK: - 16. append_text clamps bytes outside 0x20-0x80 to a space
do
	local msg = {}
	-- 0x01 (control char, below range), 0x41 ('A', in range), 0x90 (above range, non-ASCII)
	append_text(msg, string.char(0x01, 0x41, 0x90), 10)
	check('append_text clamps a byte below 0x20 to 0x20', msg[1] == 0x20)
	check('append_text passes a byte within 0x20-0x80 through unchanged', msg[2] == 0x41)
	check('append_text clamps a byte above 0x80 to 0x20', msg[3] == 0x20)
	check('append_text 0x00-terminates', msg[4] == 0x00)

	-- nil-text path: the `if text ~= nil then` guard skips the whole loop -
	-- must still terminate rather than erroring on string.byte(nil, ...) or
	-- leaving msg empty.
	local nilMsg = {}
	append_text(nilMsg, nil, 10)
	check('append_text with nil text appends only the 0x00 terminator', #nilMsg == 1 and nilMsg[1] == 0x00)

	-- maxLength clamp: `limit = math.min(#text, maxLength or 32)` - a string
	-- longer than maxLength must be truncated to maxLength bytes before the
	-- terminator, not copied in full.
	local clampMsg = {}
	append_text(clampMsg, 'ABCDEFGH', 3)
	check(
		'append_text clamps output length to maxLength before the terminator',
		#clampMsg == 4 and clampMsg[1] == 0x41 and clampMsg[2] == 0x42 and clampMsg[3] == 0x43 and clampMsg[4] == 0x00
	)
end

-- MARK: - 17. draw_bitmap memoizes, same idiom as draw_text/draw_rect
--
-- pendingMessages is reset between steps (rather than accumulated) because queue_message
-- COALESCES same-regionId updates in place (see its own comment) - counting cumulatively would
-- conflate "queued nothing" with "replaced the existing entry", both of which leave the array the
-- same length.
do
	drawn = {}
	pendingMessages = {}
	draw_bitmap('test:bitmap', 10, 20, BMP_GROUP_KNOB, 3, 255, 140, 0, 0, 0, 0)
	check('draw_bitmap queues a message on first draw', #pendingMessages == 1)

	pendingMessages = {}
	draw_bitmap('test:bitmap', 10, 20, BMP_GROUP_KNOB, 3, 255, 140, 0, 0, 0, 0)
	check(
		'draw_bitmap queues nothing when the repeat call is byte-for-byte identical',
		#pendingMessages == 0
	)

	draw_bitmap('test:bitmap', 10, 20, BMP_GROUP_KNOB, 4, 255, 140, 0, 0, 0, 0)
	check(
		'draw_bitmap queues exactly one message when only the icon index changes',
		#pendingMessages == 1
	)
end

-- MARK: - 18. popup_knob_icon: value/127 -> icon/(BMP_KNOB_LEVELS-1), both endpoints and a midpoint
--
-- v6 replaced the popup's 20-segment ring with the native Knob bitmap (13 icons, 0x00 empty -
-- 0x0C full - see docs/config-lua-history.md#the-knob-bitmap-replaces-the-ring-2026-08-29). Same
-- /127-not-/128 reasoning as the old popup_lit_count: value=0 must land on icon 0 and value=127
-- (the actual maximum) must land on the actual last icon, not one short of it.
check('popup_knob_icon: value 0 -> icon 0', popup_knob_icon(0) == 0)
check('popup_knob_icon: value 127 -> icon 12 (BMP_KNOB_LEVELS-1)', popup_knob_icon(127) == BMP_KNOB_LEVELS - 1)
check('popup_knob_icon: value 64 -> icon 6 (midpoint)', popup_knob_icon(64) == 6)

do
	local allInRange = true
	for v = 0, 127 do
		local icon = popup_knob_icon(v)
		if icon < 0 or icon > BMP_KNOB_LEVELS - 1 then allInRange = false end
	end
	check('popup_knob_icon stays within 0..BMP_KNOB_LEVELS-1 across the whole 0-127 range', allInRange)
end

-- BMP_ICON_W (61) is odd, so centring it (POPUP_CENTER_X - BMP_ICON_W / 2) lands on a half-pixel
-- unless floored - append_msb_lsb's value%128 on a non-integer x would corrupt the Plot Bitmap
-- message's x byte pair, not just draw one pixel off. math.floor(POPUP_CENTER_X - BMP_ICON_W/2)
-- with POPUP_CENTER_X=160 gives 129, matching the suggested screen-centred x directly.
check('POPUP_KNOB_X is a whole pixel (floored, not a fractional centring result)',
	POPUP_KNOB_X == math.floor(POPUP_KNOB_X))
check('POPUP_KNOB_X centres the 61px-wide icon on the 320px screen', POPUP_KNOB_X == 129)

-- MARK: - 19. paint_popup_screen: reduced message count, every message fits FLUSH_BUDGET
--
-- The Knob-bitmap redesign collapses the old bg + 4 border strips + label + 20 ring segments +
-- value (27 messages) down to bg + 4 border strips + label + knob + value (8 messages) - see
-- docs/config-lua-history.md#the-knob-bitmap-replaces-the-ring-2026-08-29 for the before/after.
do
	drawn = {}
	pendingMessages = {}
	popupControlName, popupCcNumber, popupValue = 'ENC 1', 59, 64

	paint_popup_screen()

	check(
		'paint_popup_screen queues bg + 4 border strips + label + knob + value = 8 messages',
		#pendingMessages == 8
	)

	local allWithinBudget = true
	for i = 1, #pendingMessages do
		if #pendingMessages[i] > FLUSH_BUDGET then allWithinBudget = false end
	end
	check('every message paint_popup_screen queues fits within FLUSH_BUDGET', allWithinBudget)
end

-- MARK: - 20. Popup label names the physical encoder AND its CC number
--
-- draw_popup_label's text is 'ENC 1 - CC 59'-shaped (name .. ' - CC ' .. ccNumber). Decoded back
-- from the Write Text message's own byte layout (msg_write_text: 7-byte header, IT_DISPLAY,
-- DISP_WRITE_TEXT, x(2)/y(2)/maxWidth(2), align, size, fg(3), bg(3), then the 0x00-terminated
-- text - text starts at byte 24) rather than re-deriving the string, so this catches a real
-- encoding bug, not just a Lua string-concatenation bug.
local function write_text_body(msg)
	local chars = {}
	for i = 24, #msg do
		if msg[i] == 0x00 then break end
		chars[#chars + 1] = string.char(msg[i])
	end
	return table.concat(chars)
end

do
	drawn = {}
	pendingMessages = {}
	local name = ENCODER_NAME[EID_ZONE1]
	local ccNumber = CC_MAP[ENCODER_CC[EID_ZONE1]]

	draw_popup_label(name, ccNumber)

	local text = write_text_body(pendingMessages[1])
	check('popup label contains the encoder name (ENC 1)', text:find(name, 1, true) ~= nil)
	check('popup label contains the CC number (CC 59)', text:find('CC ' .. ccNumber, 1, true) ~= nil)
end

-- MARK: - Summary

realPrint('')
if #failures == 0 then
	realPrint('PASS: ' .. passCount .. '/' .. passCount .. ' Lua harness checks passed.')
	os.exit(0)
else
	realPrint('FAIL: ' .. #failures .. ' of ' .. (passCount + #failures) .. ' Lua harness checks failed:')
	for _, name in ipairs(failures) do
		realPrint('  - ' .. name)
	end
	os.exit(1)
end
