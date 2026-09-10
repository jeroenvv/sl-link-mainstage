-- Offline regression harness for MainStageScript/STUDIOLOGIC/SL.device/config.lua.
--
-- Plain top-level assertions (no test framework), run by `lua` - this repo has no Xcode test
-- target and never did one for the Lua side; the analogous Swift-side rationale, back when a Swift
-- companion app lived in this repo, is preserved on the archive/swift-app branch.
--
-- config.lua is driven directly - it is plain Lua, no CoreMIDI, no MainStage
-- - by stubbing exactly what MainStage injects (settriggertimer, the MIDI_*
-- constants) per .claude/skills/lua-harness/SKILL.md. Byte-shape assertions (golden vectors) were
-- originally cross-checked by hand against this project's Swift SLLinkEncoder.swift (now on
-- archive/swift-app); they are maintained today against docs/implementing-sl-link.md and the
-- upstream spec - see Scripts/run-lua-tests.sh's header.
--
-- Run via Scripts/run-lua-tests.sh, not directly - that script also gates on
-- `luac -p` first. Path to config.lua is passed as arg[1].

-- MARK: - MainStage stubs (see docs/mainstage-device-scripts.md §7: `io`/`os`
-- do not exist in the real sandbox - config.lua must never touch them, but
-- this HARNESS is plain `lua`, so using `os.exit` etc. here is fine)

-- Observed runtime values (2026-09-05 hardware log); the first three are strings, not numbers.
MIDI_Wildcard, MIDI_MSB, MIDI_LSB, MIDI_CtrChange = '??', 'bb', 'aa', 176
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
-- Derived from the spec's message tables (docs/implementing-sl-link.md, the upstream spec pinned
-- at 4c0824d) at id1=SL_HOST_ID (0x03), id2=SL_INSTANCE_START (0x6D). Originally cross-checked by
-- hand against this project's own Swift SLLinkEncoder.swift too - see Scripts/run-lua-tests.sh's
-- header for that history and for the archive/swift-app recipe if a byte-for-byte second opinion
-- is ever wanted again. Do NOT "fix" one of these to match whatever config.lua currently emits - a
-- mismatch here means the Lua codec has drifted from the spec, which is the exact regression this
-- harness exists to catch.

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

-- Derived from the spec's Plot Bitmap message table (id1: 0x03, id2: 0x6D, x: 100, y: 50,
-- groupIndex: 0x00, iconIndex: 0x05, foreground RGB: 255, 140, 0, background RGB: 0, 0, 0).
-- Originally cross-checked against SLLinkEncoder.displayPlotBitmap via the swiftc recipe now
-- documented for a checkout of archive/swift-app in .claude/skills/lua-harness/SKILL.md.
-- groupIndex/iconIndex are single bytes (0x00, 0x05), NOT msb/lsb split, unlike x/y.
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

-- draw_text_with_erase()/base_region_id() - which used to need a second version of this test for the
-- id..':rect'/id..':text' coalescing-key split they produced - were removed 2026-08-29 when the zoom
-- screen moved to device-side centring at a real maxWidth (see
-- docs/config-lua-history.md#zoom-screen-centring-moved-to-the-device-2026-08-29). Nothing in
-- config.lua produces a split regionId any more, so the plain-id case above is the only one left to
-- cover.

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

-- MARK: - 21. paint_zoom_screen: zset/zname centre via the device now, at a real non-zero maxWidth
--
-- 2026-08-29: zset/zname moved from a Lua pixel-width estimate (maxWidth=0, manual ALIGN_LEFT
-- centring via the since-removed draw_text_with_erase()/estimate_text_width_px()) to the device's
-- own ALIGN_CENTER at a real maxWidth - see
-- docs/config-lua-history.md#zoom-screen-centring-moved-to-the-device-2026-08-29. This collapses a
-- full zoom repaint from 7 queued display messages (zcnc + zset rect/text + zname rect/text + znext
-- + zpos) to 5 (zcnc + zset + zname + znext + zpos) - one message each for zset/zname instead of
-- two - and every message must still fit FLUSH_BUDGET. align/maxWidth are decoded from the message's
-- own bytes (msg_write_text: 7-byte header, itemType, func, x msb/lsb, y msb/lsb, then maxWidth
-- msb/lsb at 14/15 and align at 16), the same "decode the wire bytes, don't re-derive the string"
-- idiom write_text_body (test 20) uses, so this catches a real encoding regression rather than just
-- a Lua-side argument-passing bug.
local function align_of(msg) return msg[16] end
local function max_width_of(msg) return msg[14] * 128 + msg[15] end

do
	displayMode = 'zoom'
	patchName, setName, currentConcert =
		'A Reasonably Long Patch Name', 'A Reasonably Long Set Name', 'Test Concert'
	drawn = {}
	pendingMessages = {}

	paint_zoom_screen()

	check(
		'paint_zoom_screen queues zcnc + zset + zname + znext + zpos = 5 messages (was 7 before the device-centring migration)',
		#pendingMessages == 5
	)

	local allWithinBudget = true
	for i = 1, #pendingMessages do
		if #pendingMessages[i] > FLUSH_BUDGET then allWithinBudget = false end
	end
	check('every message paint_zoom_screen queues fits within FLUSH_BUDGET', allWithinBudget)

	local byRegion = {}
	for i = 1, #pendingMessages do
		byRegion[pendingMessages[i].regionId] = pendingMessages[i]
	end

	check('zset draws ALIGN_CENTER', byRegion['zset'] ~= nil and align_of(byRegion['zset']) == ALIGN_CENTER)
	check('zset draws at a real, non-zero maxWidth', byRegion['zset'] ~= nil and max_width_of(byRegion['zset']) > 0)
	check('zname draws ALIGN_CENTER', byRegion['zname'] ~= nil and align_of(byRegion['zname']) == ALIGN_CENTER)
	check('zname draws at a real, non-zero maxWidth', byRegion['zname'] ~= nil and max_width_of(byRegion['zname']) > 0)
end

-- MARK: - 22. SCRIPT_VERSION: strict semver shape, and matches the repo-root VERSION file
--
-- The harness runs under real `lua` (io exists here - this is NOT config.lua's MainStage sandbox,
-- see the stub notes at the top of this file), so it can read VERSION directly rather than trusting
-- the two stay in sync by hand. repoRoot is derived from THIS FILE's own location (Tests/lua/
-- harness.lua is always two directories below the repo root) via debug.getinfo, not from configPath
-- (arg[1]) - so this stays correct even when config.lua is driven from a mutated copy living
-- elsewhere, e.g. a temp file used to prove this assertion actually fails on drift.
do
	check(
		'SCRIPT_VERSION matches strict semver shape (MAJOR.MINOR.PATCH)',
		SCRIPT_VERSION:match('^%d+%.%d+%.%d+$') ~= nil
	)

	local harnessSource = debug.getinfo(1, 'S').source:sub(2) -- strip the leading '@'
	local harnessDir = harnessSource:match('^(.*)[/\\][^/\\]+$') or '.'
	local versionPath = harnessDir .. '/../../VERSION'
	local f = io.open(versionPath, 'r')
	check('VERSION file is readable at ' .. versionPath, f ~= nil)
	if f then
		local contents = f:read('*a')
		f:close()
		local trimmed = contents:gsub('^%s+', ''):gsub('%s+$', '')
		check('SCRIPT_VERSION matches the repo-root VERSION file', SCRIPT_VERSION == trimmed)
	end
end

-- MARK: - 23. controller_info(): hand-written CC_MAP items (Layout mode names/types)
--
-- controller_info() lists one item per CC_MAP key, after the 5 physical-MIDI items, written out
-- literally (2026-09-05) rather than generated, for eyeball comparison against CC_MAP/CC_LABEL. These
-- checks are now the only thing standing between that literal list and drift from CC_MAP/CC_LABEL.
do
	local info = controller_info()
	local items = info.items
	local PHYSICAL_ITEM_COUNT = 5
	local generated = {}
	for i = PHYSICAL_ITEM_COUNT + 1, #items do
		generated[#generated + 1] = items[i]
	end

	local ccMapCount = 0
	for _ in pairs(CC_MAP) do ccMapCount = ccMapCount + 1 end

	check(
		'controller_info() generates exactly one item per CC_MAP key (' .. ccMapCount .. ')',
		#generated == ccMapCount
	)

	-- Index generated items by their own CC number and by name, to check both "every CC_MAP key
	-- produced exactly one item" and "no two items collide on CC number" without assuming order.
	local byCcNumber = {}
	local byName = {}
	local duplicateCc = false
	for _, item in ipairs(generated) do
		local ccNumber = item.midi[2]
		if byCcNumber[ccNumber] ~= nil then duplicateCc = true end
		byCcNumber[ccNumber] = item
		if item.name ~= nil then byName[item.name] = item end
	end
	check('no two generated items share a CC number', not duplicateCc)

	local everyControlHasOneItem = true
	for control, ccNumber in pairs(CC_MAP) do
		if byCcNumber[ccNumber] == nil or byCcNumber[ccNumber].name ~= CC_LABEL[control] then
			everyControlHasOneItem = false
		end
	end
	check('every CC_MAP key has exactly one generated item, at its own CC number', everyControlHasOneItem)

	local everyItemOnChannel16 = true
	for _, item in ipairs(generated) do
		if item.midi[1] ~= 0xB0 + CC_CHANNEL then everyItemOnChannel16 = false end
	end
	check('every generated item addresses CC_CHANNEL', everyItemOnChannel16)

	-- CC_MAP <-> CC_LABEL: every key has exactly one label, no orphaned label.
	local everyMapKeyHasLabel = true
	for control in pairs(CC_MAP) do
		if CC_LABEL[control] == nil then everyMapKeyHasLabel = false end
	end
	check('every CC_MAP key has a CC_LABEL entry', everyMapKeyHasLabel)

	local noOrphanedLabel = true
	for control in pairs(CC_LABEL) do
		if CC_MAP[control] == nil then noOrphanedLabel = false end
	end
	check('no CC_LABEL entry is orphaned (missing from CC_MAP)', noOrphanedLabel)

	-- CC_TURN gestures -> Knob; a spot-checked button gesture -> Button.
	local allTurnsAreKnobs = true
	for control in pairs(CC_TURN) do
		local item = byName[CC_LABEL[control]]
		if item == nil or item.objectType ~= 'Knob' then allTurnsAreKnobs = false end
	end
	check('all CC_TURN gestures generate objectType Knob', allTurnsAreKnobs)

	-- CC_TURN gestures are also the only ones declared Relative2C (Change 1, 2026-09-05) - see
	-- docs/mainstage-integration.md's "Encoders send relative deltas" section.
	local allTurnsAreRelative2C = true
	for control in pairs(CC_TURN) do
		local item = byName[CC_LABEL[control]]
		if item == nil or item.midiType ~= 'Relative2C' then allTurnsAreRelative2C = false end
	end
	check('all CC_TURN gestures declare midiType Relative2C', allTurnsAreRelative2C)

	-- JOY_ROTATE joined CC_TURN (fix 2026-09-05): its item must match the other five turn gestures,
	-- not the Momentary Button it was wrongly declared as when it still emitted relative deltas.
	check('JOY_ROTATE is a member of CC_TURN', CC_TURN['JOY_ROTATE'] == true)
	local joyRotateItem = byName[CC_LABEL['JOY_ROTATE']]
	check(
		'JOY_ROTATE declares objectType Knob',
		joyRotateItem ~= nil and joyRotateItem.objectType == 'Knob'
	)
	check(
		'JOY_ROTATE declares midiType Relative2C',
		joyRotateItem ~= nil and joyRotateItem.midiType == 'Relative2C'
	)

	local joyUpItem = byName[CC_LABEL['JOY_UP_SHORT']]
	check(
		'a spot-checked button gesture (JOY_UP_SHORT) generates objectType Button',
		joyUpItem ~= nil and joyUpItem.objectType == 'Button'
	)

	-- Determinism: items must come out in ascending CC order (guards the hand-written list's order).
	local ascending = true
	for i = 2, #generated do
		if generated[i].midi[2] <= generated[i - 1].midi[2] then ascending = false end
	end
	check('generated items are in strictly ascending CC order', ascending)
end

-- MARK: - 24. handle_sl_frame(IT_ENCODER) + flush_pending_cc: relative delta emission (Change 1,
-- 2026-09-05; coalescing fix 2026-09-05)
--
-- CC_TURN/JOY_ROTATE encoders emit each tick's signed delta, Relative2C-encoded (two's complement,
-- 7-bit), instead of the tracked absolute value - see docs/mainstage-integration.md's "Encoders send
-- relative deltas" section. encoderValue must keep accumulating/clamping 0-127 regardless, since
-- show_popup's ring gauge still reads it. The clamp/modulo encoding now happens in flush_pending_cc,
-- not in handle_sl_frame - see queue_relative_cc() - so these checks flush before inspecting the byte.
local function encoder_frame(eid, tick)
	return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, eid, tick, 0xF7)
end

-- Scans a flat flush_pending_cc() byte array (3 bytes per CC: status, ccNumber, value) for one CC
-- number's emitted value; nil if that CC number was not emitted this flush.
local function cc_value_in(bytes, ccNumber)
	for i = 1, #bytes, 3 do
		if bytes[i + 1] == ccNumber then return bytes[i + 2] end
	end
	return nil
end

do
	local savedEncoderValue = encoderValue[EID_ZONE1]
	local ENC1_CC = CC_MAP['ENC1_TURN']

	-- One tick, one flush: wire-encodes to the Relative2C byte for that raw delta.
	local function tick(delta)
		pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
		encoderValue[EID_ZONE1] = 64
		handle_sl_frame(encoder_frame(EID_ZONE1, 0x40 + delta))
		local out = flush_pending_cc()
		return cc_value_in(out.midi, ENC1_CC)
	end

	check('encoder tick +1 emits wire value 0x01', tick(1) == 0x01)
	check('encoder tick -1 emits wire value 0x7F', tick(-1) == 0x7F)
	check('encoder tick +5 emits wire value 0x05', tick(5) == 0x05)
	check('encoder tick -5 emits wire value 0x7B', tick(-5) == 0x7B)
	check('encoder tick of 0 emits nothing', tick(0) == nil)

	pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
	encoderValue[EID_ZONE1] = 125
	handle_sl_frame(encoder_frame(EID_ZONE1, 0x40 + 5))
	check('encoderValue still accumulates and clamps to 127', encoderValue[EID_ZONE1] == 127)

	pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
	encoderValue[EID_ZONE1] = 2
	handle_sl_frame(encoder_frame(EID_ZONE1, 0x40 - 5))
	check('encoderValue still accumulates and clamps to 0', encoderValue[EID_ZONE1] == 0)

	encoderValue[EID_ZONE1] = savedEncoderValue
end

-- MARK: - 25. Relative CC coalescing: accumulate, don't replace (fix 2026-09-05)
--
-- queue_cc's per-control coalescing REPLACES a pending value - correct for an absolute control, wrong
-- for a relative delta, where two ticks for the same control before a flush must SUM rather than lose
-- the first tick's motion. queue_relative_cc/flush_pending_cc fix this - closes the "Known gap, not yet
-- fixed" note in docs/mainstage-integration.md's "Encoders send relative deltas" section.
do
	local ENC1_CC = CC_MAP['ENC1_TURN']
	local SEL1_CC = CC_MAP['SEL1_SHORT']

	pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
	queue_relative_cc('ENC1_TURN', 1)
	queue_relative_cc('ENC1_TURN', 1)
	local out = flush_pending_cc()
	check('two +1 ticks before a flush emit a single +2 (0x02)', cc_value_in(out.midi, ENC1_CC) == 0x02)
	check('two coalesced +1 ticks emit only one CC message (3 bytes)', #out.midi == 3)

	pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
	queue_relative_cc('ENC1_TURN', 1)
	queue_relative_cc('ENC1_TURN', -1)
	out = flush_pending_cc()
	check('a +1 then a -1 before a flush emits nothing for that control', #out.midi == 0)
	check('a net-zero relative control does not remain queued', pendingCCOrder[1] == nil)

	pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
	queue_relative_cc('ENC1_TURN', 100)
	out = flush_pending_cc()
	check('a large positive accumulated total clamps to +63 (0x3F)', cc_value_in(out.midi, ENC1_CC) == 0x3F)

	pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
	queue_relative_cc('ENC1_TURN', -100)
	out = flush_pending_cc()
	check('a large negative accumulated total clamps to -63 (0x41)', cc_value_in(out.midi, ENC1_CC) == 0x41)

	-- A relative and an absolute control queued in the same round both come out correctly in one batch.
	pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
	queue_relative_cc('ENC1_TURN', 1)
	queue_cc('SEL1_SHORT', 127)
	out = flush_pending_cc()
	check('mixed batch: relative control comes out correctly', cc_value_in(out.midi, ENC1_CC) == 0x01)
	check('mixed batch: absolute control comes out correctly', cc_value_in(out.midi, SEL1_CC) == 127)
	check('mixed batch: both controls emitted (6 bytes)', #out.midi == 6)
end

-- MARK: - 26. Cancel button (BID_CANCEL) logs out of SL Link
--
-- SHORT sends a Logout Request (the keyboard never confirms it - see request_logout()'s comment) and
-- LONG skips straight to silence (force_logout()) since the request is ignored anyway. Both end in
-- STATE_LOGGED_OUT, which controller_timer_trigger's own branch (section 29) suspends the keepalive
-- for.
do
	local function button_frame(bid, pressKind)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_BUTTON, bid, pressKind, 0xF7)
	end

	local savedState = state

	pendingMessages = {}
	state = STATE_ACTIVE
	handle_sl_frame(button_frame(BID_CANCEL, PRESS_SHORT))
	checkHex(
		'Cancel button SHORT queues exactly a Logout Request',
		pendingMessages[1],
		'F0 00 20 1A 16 03 6D 00 02 F7'
	)
	check('Cancel button SHORT ends in STATE_LOGGED_OUT', state == STATE_LOGGED_OUT)

	pendingMessages = {}
	state = STATE_ACTIVE
	handle_sl_frame(button_frame(BID_CANCEL, PRESS_LONG))
	check('Cancel button LONG queues NO Logout Request', #pendingMessages == 0)
	check('Cancel button LONG ends in STATE_LOGGED_OUT', state == STATE_LOGGED_OUT)

	pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
	pendingMessages = {}
	state = STATE_ACTIVE
	handle_sl_frame(button_frame(BID_CANCEL, PRESS_SHORT))
	local ccOut = flush_pending_cc()
	check('Cancel button emits no CC (BID_CANCEL is not in BUTTON_CC)', #ccOut.midi == 0)

	local function system_frame(func)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_SYSTEM, func, 0xF7)
	end

	state = STATE_ACTIVE
	handle_sl_frame(system_frame(SYS_LOGOUT_CONFIRMATION))
	check('inbound SYS_LOGOUT_CONFIRMATION leaves state at STATE_IDLE', state == STATE_IDLE)

	state = savedState
end

-- MARK: - 27. EID_A drives Master Volume (IT_MASTER_VOLUME), not a CC
--
-- EID_A ticks bypass ENCODER_CC entirely: they clamp/store masterVolume (0-100) and queue a Master
-- Volume write under its own 'mvol' regionId so a fast twist's many ticks coalesce to one queued
-- write (see queue_message's PER-REGION COALESCING comment) - not one per tick. Assertions filter
-- pendingMessages down to the 'mvol' entry so the popup's own display traffic (a separate concern,
-- covered by the existing per-region memoization tests) doesn't interfere.
do
	local function encoder_frame(eid, tickByte)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, eid, tickByte, 0xF7)
	end

	local function mvol_messages()
		local out = {}
		for i = 1, #pendingMessages do
			if pendingMessages[i].regionId == 'mvol' then out[#out + 1] = pendingMessages[i] end
		end
		return out
	end

	local savedPopupActive, savedDisplayMode = popupActive, displayMode
	-- Pre-seat the popup as already showing (the 'repeat call' branch) so show_master_volume_popup
	-- doesn't run the full mode-switch machinery on every sub-test below - kept separate from what
	-- this section actually tests (the Master Volume write itself).
	popupActive = true
	popupPreviousMode = 'zoom'
	displayMode = 'popup'

	pendingMessages = {}
	masterVolume = 50
	handle_sl_frame(encoder_frame(EID_A, 0x41)) -- delta +1
	check('EID_A tick queues exactly one Master Volume write', #mvol_messages() == 1)
	check('EID_A +1 tick updates masterVolume to 51', masterVolume == 51)
	checkHex(
		'EID_A +1 tick queues the exact Master Volume write vector (MVOL_WRITE, no MUTE byte)',
		mvol_messages()[1],
		'F0 00 20 1A 16 03 6D 07 01 33 F7'
	)

	-- Clamp at 100: starting at 100, a further +5 must not exceed it.
	pendingMessages = {}
	masterVolume = 100
	handle_sl_frame(encoder_frame(EID_A, 0x45)) -- delta +5
	check('masterVolume clamps at 100', masterVolume == 100)
	checkHex(
		'clamped write at 100 carries VOL=100 (0x64), not 105, no MUTE byte',
		mvol_messages()[1],
		'F0 00 20 1A 16 03 6D 07 01 64 F7'
	)

	-- Clamp at 0: starting at 0, a further -5 must not go negative.
	pendingMessages = {}
	masterVolume = 0
	handle_sl_frame(encoder_frame(EID_A, 0x3B)) -- delta -5
	check('masterVolume clamps at 0', masterVolume == 0)
	checkHex(
		'clamped write at 0 carries VOL=0, not negative, no MUTE byte',
		mvol_messages()[1],
		'F0 00 20 1A 16 03 6D 07 01 00 F7'
	)

	-- Several A ticks before a flush must coalesce to ONE queued write carrying the latest value -
	-- proving the 'mvol' regionId actually coalesces rather than piling up (queue_message's
	-- PER-REGION COALESCING only fires when regionId is given; this is the check that it was).
	pendingMessages = {}
	masterVolume = 50
	handle_sl_frame(encoder_frame(EID_A, 0x41)) -- 50 -> 51
	handle_sl_frame(encoder_frame(EID_A, 0x41)) -- 51 -> 52
	handle_sl_frame(encoder_frame(EID_A, 0x41)) -- 52 -> 53
	check('three EID_A ticks before a flush leave exactly one queued Master Volume write', #mvol_messages() == 1)
	check('...carrying the latest value (53), not an intermediate one', masterVolume == 53)
	checkHex(
		'...and its bytes reflect VOL=53 (0x35), no MUTE byte',
		mvol_messages()[1],
		'F0 00 20 1A 16 03 6D 07 01 35 F7'
	)

	popupActive, displayMode = savedPopupActive, savedDisplayMode

	-- Inbound Master Volume reply updates masterVolume - tolerant of the trailing MUTE byte being
	-- present or absent (docs/implementing-sl-link.md §7: trailing bytes are optional more often than
	-- documented).
	masterVolume = 0
	handle_sl_frame(frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_MASTER_VOLUME, MVOL_WRITE, 65, 0, 0xF7))
	check('inbound Master Volume WITH trailing MUTE byte decodes VOL correctly', masterVolume == 65)

	masterVolume = 0
	handle_sl_frame(frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_MASTER_VOLUME, MVOL_WRITE, 42, 0xF7))
	check('inbound Master Volume WITHOUT trailing MUTE byte decodes VOL correctly', masterVolume == 42)
end

-- MARK: - 28. popup_knob_icon scales by popupMax, not a hardcoded 127
--
-- Master Volume's popup uses popupMax=100 (see show_master_volume_popup); the ring must still hit
-- its full icon at the control's own maximum, whether that's 127 (CC encoders) or 100 (Master
-- Volume).
do
	local savedMax = popupMax

	popupMax = 127
	check('popup_knob_icon at popupMax=127 returns the full icon', popup_knob_icon(127) == BMP_KNOB_LEVELS - 1)

	popupMax = 100
	check('popup_knob_icon at popupMax=100 returns the full icon', popup_knob_icon(100) == BMP_KNOB_LEVELS - 1)

	popupMax = savedMax
end

-- MARK: - 29. STATE_LOGGED_OUT suspends the keepalive, then resumes identification
--
-- request_logout()/force_logout() (section 26) move to STATE_LOGGED_OUT. controller_timer_trigger's
-- STATE_LOGGED_OUT branch must not call send_keepalive() - that silence is what lets the SL88's own
-- ~5s no-keepalive timeout drop us from the APP list - but must still count down LOGOUT_SILENT_TICKS
-- and resume identification once it reaches zero, so our name returns to the APP list. Spied via a
-- send_keepalive stub rather than inspecting pendingMessages/flush output, since a flush drains at
-- most one message per call regardless of whether a keepalive was ever queued.
do
	local savedState, savedTimerPending, savedLogoutTicksLeft, savedPending, savedArmed =
		state, timerPending, logoutTicksLeft, pendingMessages, armed

	local originalSendKeepalive = send_keepalive
	local keepaliveCalls = 0
	send_keepalive = function()
		keepaliveCalls = keepaliveCalls + 1
		originalSendKeepalive()
	end

	pendingMessages = {}
	state = STATE_LOGGED_OUT
	timerPending = true -- as if a one-shot were already outstanding, same as a real session
	logoutTicksLeft = LOGOUT_SILENT_TICKS

	controller_timer_trigger()
	check('STATE_LOGGED_OUT timer tick queues no Device Notification', keepaliveCalls == 0)
	check(
		'STATE_LOGGED_OUT timer tick decrements the silent-tick counter',
		logoutTicksLeft == LOGOUT_SILENT_TICKS - 1
	)
	check('STATE_LOGGED_OUT stays logged out before the count expires', state == STATE_LOGGED_OUT)

	for _ = 1, LOGOUT_SILENT_TICKS - 1 do
		controller_timer_trigger()
	end
	check('STATE_LOGGED_OUT never queues a Device Notification across the whole silent window', keepaliveCalls == 0)
	check(
		'after LOGOUT_SILENT_TICKS silent ticks, identification resumes and state leaves STATE_LOGGED_OUT',
		state == STATE_IDENTIFYING
	)

	send_keepalive = originalSendKeepalive
	state, timerPending, logoutTicksLeft, pendingMessages, armed =
		savedState, savedTimerPending, savedLogoutTicksLeft, savedPending, savedArmed
end

-- MARK: - 30. handle_login() queues the Master Volume read with the exact expected bytes
do
	local savedState, savedPending = state, pendingMessages

	patchName, setName, currentConcert = 'Test Patch', 'Test Set', 'Test Concert'
	pendingMessages = {}
	handle_login()

	local reads = {}
	for i = 1, #pendingMessages do
		local m = pendingMessages[i]
		if item_type_of(m) == IT_MASTER_VOLUME and func_of(m) == MVOL_READ then
			reads[#reads + 1] = m
		end
	end
	check('handle_login() queues exactly one Master Volume read', #reads == 1)
	if #reads == 1 then
		checkHex(
			'handle_login()\'s Master Volume read carries the exact expected bytes',
			reads[1],
			'F0 00 20 1A 16 03 6D 07 00 F7'
		)
	end

	state, pendingMessages = savedState, savedPending
end

-- MARK: - 31. STATE_LOGGED_OUT suspends display traffic and pins the tick at KEEPALIVE_MS
--
-- Two reinforcing halves of the fix (see request_logout()'s and rearm_timer()'s comments): (a)
-- entering STATE_LOGGED_OUT with a popup up must dismiss it and drop whatever display traffic is
-- left queued - including the repaint dismiss_popup() itself queues - so logout actually suspends
-- display traffic instead of quietly draining it; (b) rearm_timer() must pin KEEPALIVE_MS while
-- logged out regardless of has_pending()/popupActive, or LOGOUT_SILENT_TICKS maps to far less than
-- the ~9s it is meant to.
do
	local savedState, savedPopupActive, savedDisplayMode, savedPopupPreviousMode, savedPending, savedTimerPending, savedArmed, savedTimerArmedInterval =
		state, popupActive, displayMode, popupPreviousMode, pendingMessages, timerPending, armed, timerArmedInterval

	local function button_frame(bid, pressKind)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_BUTTON, bid, pressKind, 0xF7)
	end

	-- (a) Cancel while a popup is up and other display work is queued: both must be gone afterward.
	state = STATE_ACTIVE
	popupActive = true
	popupPreviousMode = 'zoom'
	displayMode = 'popup'
	pendingMessages = {}
	queue_message(msg_draw_rect(0, 0, 1, 1, 0, 0, 0), 'test:logout-drop')
	handle_sl_frame(button_frame(BID_CANCEL, PRESS_SHORT))

	check('Cancel press dismisses an active popup', popupActive == false)
	local displayLeft = 0
	for i = 1, #pendingMessages do
		if item_type_of(pendingMessages[i]) == IT_DISPLAY then displayLeft = displayLeft + 1 end
	end
	check('Cancel press leaves no display traffic queued', displayLeft == 0)

	-- (b) rearm_timer() must pin KEEPALIVE_MS while logged out, even when has_pending() or
	-- popupActive would normally pick a shorter interval.
	state = STATE_LOGGED_OUT
	pendingMessages = {}
	queue_message(msg_draw_rect(0, 0, 1, 1, 0, 0, 0), 'test:logout-pin')
	popupActive = false
	timerPending = false
	armed = nil
	rearm_timer()
	check('STATE_LOGGED_OUT: rearm_timer() pins KEEPALIVE_MS even with has_pending() true', armed == KEEPALIVE_MS)

	pendingMessages = {}
	popupActive = true
	timerPending = false
	armed = nil
	rearm_timer()
	check('STATE_LOGGED_OUT: rearm_timer() pins KEEPALIVE_MS even with popupActive true', armed == KEEPALIVE_MS)

	-- request_quick_rearm() must not shorten an already-outstanding logout tick either -
	-- dismiss_popup()'s set_display_mode() call reaches it during exactly the request_logout()/
	-- force_logout() sequence tested above.
	timerPending = true
	timerArmedInterval = POPUP_TICK_MS
	armed = nil
	request_quick_rearm()
	check(
		'STATE_LOGGED_OUT: request_quick_rearm() does not shorten the outstanding tick',
		armed == nil and timerArmedInterval == POPUP_TICK_MS
	)

	state, popupActive, displayMode, popupPreviousMode, pendingMessages, timerPending, armed, timerArmedInterval =
		savedState, savedPopupActive, savedDisplayMode, savedPopupPreviousMode, savedPending, savedTimerPending, savedArmed, savedTimerArmedInterval
end

-- MARK: - 32. enter_active_session(): every transition into STATE_ACTIVE queues one Master Volume
-- read, and a reaffirmation while already active queues no further read
--
-- Covers the fix for the hardware bug where handle_login() alone never ran (the SL88 remembers the
-- host across runs and skips APPROVED/LOGIN entirely - see enter_active_session()'s comment), so the
-- ID_QUERY self-heal path in handle_sl_frame is the one that actually fires in practice.
do
	local savedState, savedPending = state, pendingMessages

	local function mvol_reads()
		local reads = {}
		for i = 1, #pendingMessages do
			local m = pendingMessages[i]
			if item_type_of(m) == IT_MASTER_VOLUME and func_of(m) == MVOL_READ then
				reads[#reads + 1] = m
			end
		end
		return reads
	end

	-- controller_midi_in() flushes what it queues before returning (see flush_pending's "one message
	-- per flush" rule), so by the time this function returns pendingMessages is already empty - the
	-- queued read must be found in the returned flush output instead.
	local function mvol_reads_in(bytes)
		local reads = {}
		for _, m in ipairs(split_messages(bytes or {})) do
			if item_type_of(m) == IT_MASTER_VOLUME and func_of(m) == MVOL_READ then
				reads[#reads + 1] = m
			end
		end
		return reads
	end

	-- (a) ID_QUERY reply path: STATE_IDENTIFYING -> STATE_ACTIVE queues exactly one read.
	state = STATE_IDENTIFYING
	pendingMessages = {}
	local out = controller_midi_in(qreply(), 'LINK')
	local reads = mvol_reads_in(out and out.midi)
	check('ID_QUERY reply into STATE_ACTIVE queues exactly one Master Volume read', #reads == 1)
	if #reads == 1 then
		checkHex(
			'ID_QUERY reply\'s Master Volume read carries the exact expected bytes',
			reads[1],
			'F0 00 20 1A 16 03 6D 07 00 F7'
		)
	end
	check('ID_QUERY reply into STATE_ACTIVE actually sets state', state == STATE_ACTIVE)

	-- (b) A second reaffirmation while already STATE_ACTIVE queues NO further read - the ID_QUERY
	-- reply path can be reached on every keepalive round-trip, so this is the case that would flood
	-- the outbound queue without enter_active_session()'s idempotency guard.
	pendingMessages = {}
	out = controller_midi_in(qreply(), 'LINK')
	check('a second ID_QUERY reply while already active queues no further read', #mvol_reads_in(out and out.midi) == 0)

	-- (c) handle_restart() queues one read on a genuine transition into active.
	state = STATE_STANDBY
	pendingMessages = {}
	handle_restart()
	reads = mvol_reads()
	check('handle_restart() queues exactly one Master Volume read', #reads == 1)
	if #reads == 1 then
		checkHex(
			'handle_restart()\'s Master Volume read carries the exact expected bytes',
			reads[1],
			'F0 00 20 1A 16 03 6D 07 00 F7'
		)
	end

	-- (d) handle_restart() reaffirming an already-active session queues no further read either.
	pendingMessages = {}
	handle_restart()
	check('a second handle_restart() while already active queues no further read', #mvol_reads() == 0)

	state, pendingMessages = savedState, savedPending
end

-- MARK: - 33. handle_login()/handle_restart() still repaint unconditionally, even on a
-- reaffirmation - the enter_active_session() idempotency guard covers only the volume read, not the
-- repaint the call sites are responsible for.
do
	local savedState, savedPending, savedLastPaintedPatch = state, pendingMessages, lastPaintedPatch

	patchName, setName, currentConcert = 'Test Patch', 'Test Set', 'Test Concert'

	local originalPaintScreen = paint_screen
	local paintCalls = 0
	paint_screen = function()
		paintCalls = paintCalls + 1
		originalPaintScreen()
	end

	state = STATE_ACTIVE -- already active; only the repaint call, not the transition, is under test
	pendingMessages = {}
	paintCalls = 0
	handle_login()
	check('handle_login() still repaints when called while already active', paintCalls == 1)

	pendingMessages = {}
	paintCalls = 0
	handle_restart()
	check('handle_restart() still repaints when called while already active', paintCalls == 1)

	paint_screen = originalPaintScreen
	state, pendingMessages, lastPaintedPatch = savedState, savedPending, savedLastPaintedPatch
end

-- MARK: - 34. rearm_timer() watchdog: recovers a one-shot MainStage never delivered
--
-- If timerPending latches true forever (the one-shot MainStage was supposed to fire never
-- arrives), rearm_timer() must force a re-arm after TIMER_WATCHDOG_FRAMES inbound events - but only
-- while there is queued work to push out; idle play must never trip it (rule 6) - see
-- docs/config-lua-history.md#timer-watchdog-a-lost-one-shot-latches-timerpending-forever-2026-09-07.
do
	local savedState, savedTimerPending, savedFramesSinceTick, savedArmed, savedPending, savedPopupActive =
		state, timerPending, framesSinceTick, armed, pendingMessages, popupActive

	state = STATE_ACTIVE
	popupActive = false

	-- Below the threshold, with pending work queued: rule 6's protection must hold - no re-arm yet.
	pendingMessages = {}
	queue_message(msg_draw_rect(0, 0, 1, 1, 0, 0, 0), 'test:timer-watchdog')
	timerPending = true
	framesSinceTick = 0
	armed = nil
	for i = 1, TIMER_WATCHDOG_FRAMES - 1 do
		controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	end
	check('rearm_timer watchdog: below threshold does not re-arm', armed == nil)
	check('rearm_timer watchdog: timerPending still latched below threshold', timerPending == true)

	-- One more frame reaches the threshold, with pending work still queued: the watchdog must force
	-- a re-arm.
	controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	check('rearm_timer watchdog: re-arms once TIMER_WATCHDOG_FRAMES is reached with pending work',
		armed == FLUSH_SOON_MS)
	check('rearm_timer watchdog: framesSinceTick resets once it fires', framesSinceTick == 0)

	-- At/over the threshold but with NO pending work: the watchdog must NOT re-arm - this is the
	-- rule 6 case where a slow tick during idle play is not a dead clock.
	pendingMessages = {}
	timerPending = true
	framesSinceTick = TIMER_WATCHDOG_FRAMES
	armed = nil
	rearm_timer()
	check('rearm_timer watchdog: does not re-arm with no pending work even at threshold', armed == nil)
	check('rearm_timer watchdog: timerPending stays latched with no pending work', timerPending == true)

	-- A real tick resets the counter too, independent of the watchdog.
	framesSinceTick = 42
	timerPending = true
	controller_timer_trigger()
	check('controller_timer_trigger resets framesSinceTick', framesSinceTick == 0)

	state, timerPending, framesSinceTick, armed, pendingMessages, popupActive =
		savedState, savedTimerPending, savedFramesSinceTick, savedArmed, savedPending, savedPopupActive
end

-- MARK: - 35. A genuine login confirmation still resyncs Master Volume when the self-heal path
-- already made the session ACTIVE; a self-heal reaffirmation alone still queues nothing.
--
-- Reproduces the hardware bug: ID_QUERY self-heal reaches STATE_ACTIVE before the user selects the
-- app, so the keyboard ignores that READ; the real SYS_LOGIN_CONFIRMATION arrives later while state
-- is already STATE_ACTIVE, and enter_active_session()'s idempotency guard used to swallow it.
-- Inspects pendingMessages directly rather than a flush's .midi output: handle_login() queues its
-- repaint (display messages) BEFORE the volume read, and flush_pending sends only one queued
-- message per call, so a single controller_midi_in round-trip would return the display message
-- and leave the read still queued rather than proving it absent.
do
	local savedState, savedPending = state, pendingMessages

	local function mvol_reads()
		local reads = {}
		for i = 1, #pendingMessages do
			local m = pendingMessages[i]
			if item_type_of(m) == IT_MASTER_VOLUME and func_of(m) == MVOL_READ then
				reads[#reads + 1] = m
			end
		end
		return reads
	end

	-- Self-heal reaffirming an already-ACTIVE session (enter_active_session()'s own idempotency
	-- guard, exercised end-to-end via ID_QUERY in test 32) must still queue no read.
	state = STATE_ACTIVE
	pendingMessages = {}
	enter_active_session()
	check('enter_active_session() reaffirming an already-ACTIVE session queues no read',
		#mvol_reads() == 0)

	-- A genuine login confirmation arriving while the self-heal path already made the session
	-- ACTIVE - exactly the hardware sequence - must still queue exactly one read.
	state = STATE_ACTIVE
	pendingMessages = {}
	handle_login()
	local reads = mvol_reads()
	check('a genuine login confirmation while already ACTIVE queues exactly one Master Volume read',
		#reads == 1)
	if #reads == 1 then
		checkHex(
			'that Master Volume read carries the exact expected bytes',
			reads[1],
			'F0 00 20 1A 16 03 6D 07 00 F7'
		)
	end

	state, pendingMessages = savedState, savedPending
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
