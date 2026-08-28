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
