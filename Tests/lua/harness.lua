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

-- Baseline "a READ reply has landed at least once" state for the rest of the suite. masterVolumeRead
-- no longer feeds masterVolume at all (see
-- docs/config-lua-history.md#master-volume-read-reply-does-not-track-writes-2026-09-12), so this is
-- just a plausible logging value - sections that care about it manage it themselves (save/restore).
masterVolumeRead = 50

-- MARK: - Helpers (SKILL.md)

-- MainStage passes inbound MIDI events as 0-indexed tables; frame(...)
-- converts a 1-indexed varargs list to match.
local function frame(...)
	local a, e = { ... }, {}
	for i, v in ipairs(a) do e[i - 1] = v end
	return e
end

-- nil-tolerant on purpose: a mutation under test can leave a message missing, and crashing here
-- aborts the run so every later section goes unchecked - which silently hides whether those
-- sections would have caught the mutation. Report it as a failed check instead.
local function hex(t)
	if t == nil then return '<nil>' end
	local s = {}
	for i = 1, #t do s[#s + 1] = string.format('%02X', t[i]) end
	return table.concat(s, ' ')
end

-- instanceID is now derived per-instance (from instanceTag) rather than a fixed SL_INSTANCE_START,
-- so golden vectors can no longer bake in a literal '6D' - this reads the live value. instanceID is
-- never reassigned across this whole run (see test 36's own save/restore), so it's safe to inline
-- into expected hex strings anywhere in this file.
local function id2() return string.format('%02X', instanceID) end

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
-- at 4c0824d) at id1=SL_HOST_ID (0x03), id2=instanceID (derived per-instance - see id2() above, and
-- derive_instance_start in config.lua). Originally cross-checked by
-- hand against this project's own Swift SLLinkEncoder.swift too - see Scripts/run-lua-tests.sh's
-- header for that history and for the archive/swift-app recipe if a byte-for-byte second opinion
-- is ever wanted again. Do NOT "fix" one of these to match whatever config.lua currently emits - a
-- mismatch here means the Lua codec has drifted from the spec, which is the exact regression this
-- harness exists to catch.

checkHex(
	'msg_identification_request',
	msg_identification_request(),
	'F0 00 20 1A 16 03 ' .. id2() .. ' 7F 00 4D 61 69 6E 53 74 61 67 65 00 F7'
)

checkHex(
	'msg_identification_query',
	msg_identification_query(),
	'F0 00 20 1A 16 03 ' .. id2() .. ' 7F 03 F7'
)

checkHex(
	'msg_system(SYS_DEVICE_NOTIFICATION)',
	msg_system(SYS_DEVICE_NOTIFICATION),
	'F0 00 20 1A 16 03 ' .. id2() .. ' 00 00 F7'
)

checkHex(
	'msg_clear_screen(255, 128, 1)',
	msg_clear_screen(255, 128, 1),
	'F0 00 20 1A 16 03 ' .. id2() .. ' 04 01 7F 40 00 F7'
)

checkHex(
	'msg_write_text("Hi!", ...)',
	msg_write_text('Hi!', 5, 6, 100, ALIGN_CENTER, SIZE_BIG, 255, 0, 0, 0, 255, 0),
	'F0 00 20 1A 16 03 ' .. id2() .. ' 04 00 00 05 00 06 00 64 01 02 7F 00 00 00 7F 00 48 69 21 00 F7'
)

checkHex(
	'msg_draw_rect(10, 20, 30, 40, 200, 100, 50)',
	msg_draw_rect(10, 20, 30, 40, 200, 100, 50),
	'F0 00 20 1A 16 03 ' .. id2() .. ' 04 02 00 0A 00 14 00 1E 00 28 64 32 19 F7'
)

-- Derived from the spec's Plot Bitmap message table (id1: 0x03, id2: instanceID, x: 100, y: 50,
-- groupIndex: 0x00, iconIndex: 0x05, foreground RGB: 255, 140, 0, background RGB: 0, 0, 0).
-- Originally cross-checked against SLLinkEncoder.displayPlotBitmap via the swiftc recipe now
-- documented for a checkout of archive/swift-app in .claude/skills/lua-harness/SKILL.md.
-- groupIndex/iconIndex are single bytes (0x00, 0x05), NOT msb/lsb split, unlike x/y.
checkHex(
	'msg_plot_bitmap(100, 50, BMP_GROUP_KNOB, 5, 255, 140, 0, 0, 0, 0)',
	msg_plot_bitmap(100, 50, BMP_GROUP_KNOB, 5, 255, 140, 0, 0, 0, 0),
	'F0 00 20 1A 16 03 ' .. id2() .. ' 04 03 00 64 00 32 00 05 7F 46 00 00 00 00 F7'
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
	slFlushReady = true
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
	slFlushReady = true
	while has_pending() and flushes <= cap do
		flushes = flushes + 1
		flush_pending(true)
		displayFlushReady = true
		slFlushReady = true
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
	slFlushReady = true

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
			slFlushReady = true
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
	slFlushReady = true
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
	slFlushReady = true
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
	slFlushReady = true -- tick permit fresh; only the display grant is spent
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
	slFlushReady = true
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

-- MARK: - 12b. queue_repeated: N calls reach the queue as N separate entries, not one coalesced entry
--
-- The mechanism section 68's mute/LED repeats rely on. A regression that gave queue_repeated's
-- copies a shared regionId would hit section 12's own coalescing behaviour and collapse them back to
-- one - this pins that it does not.
do
	pendingMessages = {}
	queue_repeated(function() return msg_white_led(WLID_A_ENC, true) end, 5)
	check('queue_repeated(builder, 5) queues 5 separate messages', #pendingMessages == 5)
	for i = 1, #pendingMessages do
		check('...entry ' .. i .. ' carries no regionId (never coalesced)', pendingMessages[i].regionId == nil)
	end
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
-- queue_sacrificial_redraw has TWO branches - the underlying mode == 'zoom' draws the concert
-- line, else it draws the ctx bar via ctx_text(). For displayMode == 'popup' the underlying mode
-- is popupPreviousMode, not 'popup' itself (see fix in MARK: - 61 below) - pinned here to 'list'
-- so this test exercises the else branch deterministically regardless of leftover global state. A
-- small synthetic listRows/cursorIndex is set up once so ctx_text()'s dependency chain
-- (cursor_set_label(), which reads listRows/cursorIndex) produces a real string for the list/popup
-- branch.
do
	listRows = {
		{ label = 'Test Set', isPatch = false },
		{ label = 'Test Patch', isPatch = true, setIndex = 0, patchIndex = 0 },
	}
	cursorIndex = 1
	currentConcert = 'Test Concert'
	local savedPopupPreviousMode = popupPreviousMode
	popupPreviousMode = 'list'

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

	popupPreviousMode = savedPopupPreviousMode
end

-- MARK: - 15. controller_finalize tears down unconditionally
--
-- What it SENDS is section 77's concern (a gated Logout Request); this section covers only the
-- teardown, which happens either way.
do
	state = STATE_ACTIVE
	timerTicks = 0 -- inside the churn window, so nothing is sent - see section 77
	pendingMessages = { msg_draw_rect(0, 0, 10, 10, 0, 0, 0) }
	local result = controller_finalize()
	check('controller_finalize sends nothing from inside the churn window', result == nil)
	check('controller_finalize still clears pendingMessages', #pendingMessages == 0)
	check('controller_finalize still sets state to STATE_IDLE', state == STATE_IDLE)
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

-- The Master Volume popup (popupCcNumber == nil) adds a 9th message: the "PUSH TO MUTE/UNMUTE" hint,
-- absent on every mapped-encoder popup (see docs/config-lua-history.md#a-encoder-button-mute-2026-09-14).
do
	drawn = {}
	pendingMessages = {}
	popupControlName, popupCcNumber, popupValue = 'Main Volume', nil, 60

	paint_popup_screen()

	check(
		'paint_popup_screen on the Master Volume popup queues the base 8 + the mute hint = 9 messages',
		#pendingMessages == 9
	)

	local allWithinBudget = true
	for i = 1, #pendingMessages do
		if #pendingMessages[i] > FLUSH_BUDGET then allWithinBudget = false end
	end
	check('every message the Master Volume popup queues fits within FLUSH_BUDGET', allWithinBudget)
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

	-- The ring has NO CC at all any more: it selects patches with Bank Select + Program Change, which is
	-- not a CC, so JOY_ROTATE was removed from every table rather than left emitting nothing. CC 50 stays
	-- unused rather than reassigned - renumbering would break every learned mapping after it.
	check('the ring has no CC mapping', CC_MAP['JOY_ROTATE'] == nil)
	check('...and no label', CC_LABEL['JOY_ROTATE'] == nil)
	check('...and is not a CC_TURN gesture', CC_TURN['JOY_ROTATE'] == nil)
	check('...and no encoder is wired to it', ENCODER_CC[EID_JOYSTICK] == nil)
	local ccFiftyUsed = false
	for _, n in pairs(CC_MAP) do
		if n == 50 then ccFiftyUsed = true end
	end
	check('CC 50 is left unused, not reassigned', ccFiftyUsed == false)

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
		-- nil is the "nothing emitted" return (a net-zero delta) - not an empty table, which would
		-- swallow the inbound event. See flush_pending_cc's own comment.
		if out == nil then return nil end
		return cc_value_in(out.midi, ENC1_CC)
	end

	check('encoder tick +1 emits wire value 0x01', tick(1) == 0x01)
	check('encoder tick -1 emits wire value 0x7F', tick(-1) == 0x7F)
	check('encoder tick +5 emits wire value 0x05', tick(5) == 0x05)
	check('encoder tick -5 emits wire value 0x7B', tick(-5) == 0x7B)
	check('encoder tick of 0 emits nothing', tick(0) == nil)

	-- THE REGRESSION: a net-zero batch must return nil, never { midi = {} } - an empty table swallows
	-- the inbound event and costs the round its SL flush for no MIDI at all.
	pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
	encoderValue[EID_ZONE1] = 64
	handle_sl_frame(encoder_frame(EID_ZONE1, 0x40 + 1))
	handle_sl_frame(encoder_frame(EID_ZONE1, 0x40 - 1))
	check('THE REGRESSION: a net-zero CC batch returns nil, not an event-swallowing empty table',
		flush_pending_cc() == nil)

	-- ...and controller_midi_in must then FALL THROUGH to the SL flush, not return that nil. A
	-- net-zero batch pre-empting the flush costs the round its display drain and its keepalive query.
	do
		local savedState, savedPending = state, pendingMessages
		state, pendingMessages = STATE_ACTIVE, {}
		pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
		queue_relative_cc('ENC1_TURN', 1)
		queue_relative_cc('ENC1_TURN', -1) -- queued, nets to zero, so the batch emits nothing
		local inOut = controller_midi_in(encoder_frame(EID_ZONE2, 0x40), 'LINK')
		local sawQuery = false
        if inOut ~= nil and inOut.midi ~= nil then
            for _, m in ipairs(split_messages(inOut.midi)) do
                if item_type_of(m) == IT_IDENTIFICATION and func_of(m) == ID_QUERY then sawQuery = true end
            end
        end
		check('THE REGRESSION: a net-zero CC batch still lets the round take its SL flush',
			sawQuery == true)
		state, pendingMessages = savedState, savedPending
	end

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
	-- nil, not { midi = {} }: an empty table would swallow the inbound event - see flush_pending_cc.
	check('a +1 then a -1 before a flush emits nothing for that control', out == nil)
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
		'F0 00 20 1A 16 03 ' .. id2() .. ' 00 02 F7'
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
	check('Cancel button emits no CC (BID_CANCEL is not in BUTTON_CC)', ccOut == nil)

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

	local savedPopupActive, savedDisplayMode, savedMasterVolumeRead =
		popupActive, displayMode, masterVolumeRead
	-- Pre-seat the popup as already showing (the 'repeat call' branch) so show_master_volume_popup
	-- doesn't run the full mode-switch machinery on every sub-test below - kept separate from what
	-- this section actually tests (the Master Volume write itself).
	popupActive = true
	popupPreviousMode = 'zoom'
	displayMode = 'popup'

	local savedMasterMuted = masterMuted

	pendingMessages = {}
	masterVolume = 50
	masterMuted = true
	handle_sl_frame(encoder_frame(EID_A, 0x41)) -- delta +1
	check('EID_A tick queues exactly one Master Volume write', #mvol_messages() == 1)
	check('EID_A +1 tick updates masterVolume to 51', masterVolume == 51)
	check('EID_A tick never touches masterMuted (a volume turn must not disturb mute)', masterMuted == true)
	checkHex(
		'EID_A +1 tick queues the exact Master Volume write vector (MVOL_WRITE, no MUTE byte)',
		mvol_messages()[1],
		'F0 00 20 1A 16 03 ' .. id2() .. ' 07 01 33 F7'
	)
	masterMuted = savedMasterMuted

	-- Clamp at 100: starting at 100, a further +5 must not exceed it.
	pendingMessages = {}
	masterVolume = 100
	handle_sl_frame(encoder_frame(EID_A, 0x45)) -- delta +5
	check('masterVolume clamps at 100', masterVolume == 100)
	checkHex(
		'clamped write at 100 carries VOL=100 (0x64), not 105, no MUTE byte',
		mvol_messages()[1],
		'F0 00 20 1A 16 03 ' .. id2() .. ' 07 01 64 F7'
	)

	-- Clamp at 0: starting at 0, a further -5 must not go negative.
	pendingMessages = {}
	masterVolume = 0
	handle_sl_frame(encoder_frame(EID_A, 0x3B)) -- delta -5
	check('masterVolume clamps at 0', masterVolume == 0)
	checkHex(
		'clamped write at 0 carries VOL=0, not negative, no MUTE byte',
		mvol_messages()[1],
		'F0 00 20 1A 16 03 ' .. id2() .. ' 07 01 00 F7'
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
		'F0 00 20 1A 16 03 ' .. id2() .. ' 07 01 35 F7'
	)

	-- A genuine mid-range decrease (not just the floor clamp tested above, which starts already at 0
	-- and so never demonstrates an actual decrease): a negative delta away from either boundary must
	-- lower masterVolume and the queued write must carry that lower value.
	pendingMessages = {}
	masterVolume = 50
	handle_sl_frame(encoder_frame(EID_A, 0x3B)) -- delta -5
	check('a negative EID_A delta actually decreases masterVolume (50 - 5 = 45)', masterVolume == 45)
	checkHex(
		'...and the queued write carries the decreased value (VOL=45, 0x2D), no MUTE byte',
		mvol_messages()[1],
		'F0 00 20 1A 16 03 ' .. id2() .. ' 07 01 2D F7'
	)

	-- EID_A no longer queues a Master Volume READ per tick (see
	-- docs/config-lua-history.md#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13):
	-- a write takes effect with no read anywhere near it, so the per-tick poll and its rate limit are
	-- gone. The single session-entry read is covered by sections 30/32/35.
	local function mvol_read_messages()
		local out = {}
		for i = 1, #pendingMessages do
			if pendingMessages[i].regionId == 'mvolRead' then out[#out + 1] = pendingMessages[i] end
		end
		return out
	end

	pendingMessages = {}
	handle_sl_frame(encoder_frame(EID_A, 0x41))
	check('EID_A tick queues no Master Volume read', #mvol_read_messages() == 0)

	popupActive, displayMode =
		savedPopupActive, savedDisplayMode

	-- Inbound Master Volume reply updates masterVolume - tolerant of the trailing MUTE byte being
	-- present or absent (docs/implementing-sl-link.md §7: trailing bytes are optional more often than
	-- documented).
	masterVolume = 0
	masterVolumeRead = nil
	handle_sl_frame(frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_MASTER_VOLUME, MVOL_WRITE, 65, 0, 0xF7))
	check('inbound Master Volume WITH trailing MUTE byte decodes VOL correctly', masterVolume == 65)
	check('...but a WRITE-shaped frame (func=MVOL_WRITE) is not a READ reply, so masterVolumeRead stays nil',
		masterVolumeRead == nil)

	masterVolume = 0
	handle_sl_frame(frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_MASTER_VOLUME, MVOL_WRITE, 42, 0xF7))
	check('inbound Master Volume WITHOUT trailing MUTE byte decodes VOL correctly', masterVolume == 42)

	masterVolumeRead = savedMasterVolumeRead
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
			'F0 00 20 1A 16 03 ' .. id2() .. ' 07 00 F7'
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

	-- controller_midi_in() flushes only ONE queued message before returning (flush_pending's
	-- one-message-per-tick permit, slFlushReady), and entering ACTIVE queues the LED alongside the
	-- read - so the read may still be sitting in pendingMessages. Count both places.
	local function mvol_reads_in(bytes)
		local reads = {}
		for _, m in ipairs(split_messages(bytes or {})) do
			if item_type_of(m) == IT_MASTER_VOLUME and func_of(m) == MVOL_READ then
				reads[#reads + 1] = m
			end
		end
		return reads
	end

	-- (a) ID_QUERY reply path: STATE_LISTED (already APPROVED) -> STATE_ACTIVE queues exactly one
	-- read. STATE_IDENTIFYING must NOT be promoted this way - see
	-- docs/config-lua-history.md#identification-approval-and-rejection-are-lost-in-mainstages-init-window-2026-09-10.
	state = STATE_LISTED
	pendingMessages = {}
	local out = controller_midi_in(qreply(), 'LINK')
	local reads = mvol_reads_in(out and out.midi)
	for _, m in ipairs(mvol_reads()) do reads[#reads + 1] = m end
	check('ID_QUERY reply into STATE_ACTIVE queues exactly one Master Volume read', #reads == 1)
	if #reads == 1 then
		checkHex(
			'ID_QUERY reply\'s Master Volume read carries the exact expected bytes',
			reads[1],
			'F0 00 20 1A 16 03 ' .. id2() .. ' 07 00 F7'
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
			'F0 00 20 1A 16 03 ' .. id2() .. ' 07 00 F7'
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
			'F0 00 20 1A 16 03 ' .. id2() .. ' 07 00 F7'
		)
	end

	state, pendingMessages = savedState, savedPending
end

-- MARK: - 36. Identification resend while identifying, and the ID_QUERY self-heal no longer fakes
-- an approval - see
-- docs/config-lua-history.md#identification-approval-and-rejection-are-lost-in-mainstages-init-window-2026-09-10.
do
	local savedState, savedPending, savedInstanceID, savedIdentifyResendsLeft, savedIdentifyFallback,
		savedReidentifyRetriesLeft, savedArmed, savedTimerPending =
		state, pendingMessages, instanceID, identifyResendsLeft, identifyFallback, reidentifyRetriesLeft,
		armed, timerPending

	local function approved_frame()
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_IDENTIFICATION, ID_APPROVED,
			0x01, 0x01, 0x02, 0x01, 0xF7)
	end

	local function rejected_frame(reason)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_IDENTIFICATION, ID_REJECTED,
			reason, 0x01, 0x01, 0x02, 0x01, 0xF7)
	end

	local function id_requests_in(bytes)
		local n = 0
		for _, m in ipairs(split_messages(bytes or {})) do
			if item_type_of(m) == IT_IDENTIFICATION and func_of(m) == ID_REQUEST then n = n + 1 end
		end
		return n
	end

	local function keepalives_in(bytes)
		local n = 0
		for _, m in ipairs(split_messages(bytes or {})) do
			if item_type_of(m) == IT_SYSTEM and func_of(m) == SYS_DEVICE_NOTIFICATION then n = n + 1 end
		end
		return n
	end

	-- (a) Still identifying, not yet approved: a keepalive-cadence tick re-sends the Identification
	-- Request rather than a Device Notification, and spends the bounded resend budget.
	state = STATE_IDENTIFYING
	identifyResendsLeft = MAX_IDENTIFY_RESENDS
	pendingMessages = {}
	local out = controller_timer_trigger()
	check('STATE_IDENTIFYING timer tick re-sends the Identification Request',
		id_requests_in(out and out.midi) == 1)
	check('the resend spends identifyResendsLeft', identifyResendsLeft == MAX_IDENTIFY_RESENDS - 1)

	-- (a2) Bounded: once the budget is spent, further ticks stop resending rather than spamming. The
	-- fallback floor engages instead of going silent - see
	-- docs/config-lua-history.md#identification-approval-and-rejection-are-lost-in-mainstages-init-window-2026-09-10.
	identifyResendsLeft = 0
	identifyFallback = false
	pendingMessages = {}
	out = controller_timer_trigger()
	check('no further resend once identifyResendsLeft is exhausted', id_requests_in(out and out.midi) == 0)
	check('exhausting the resend budget engages identifyFallback', identifyFallback == true)
	check('the fallback sends a keepalive rather than staying silent',
		keepalives_in(out and out.midi) == 1)

	-- (b) An explicit 7F 01 APPROVED reply moves out of STATE_IDENTIFYING (to STATE_LISTED) and stops
	-- the resend - the branch that resends only fires while state == STATE_IDENTIFYING.
	state = STATE_IDENTIFYING
	identifyResendsLeft = MAX_IDENTIFY_RESENDS
	pendingMessages = {}
	controller_midi_in(approved_frame(), 'LINK')
	check('7F 01 APPROVED leaves STATE_IDENTIFYING', state == STATE_LISTED)
	pendingMessages = {}
	out = controller_timer_trigger()
	check('no identify-resend fires once APPROVED (state == STATE_LISTED)',
		id_requests_in(out and out.midi) == 0)
	-- Once approved, the ordinary ID_QUERY self-heal (still legitimate from STATE_LISTED - see test
	-- 32) is what actually promotes to STATE_ACTIVE, matching the real hardware sequence.
	pendingMessages = {}
	controller_midi_in(qreply(), 'LINK')
	check('an ID_QUERY reply after APPROVED promotes STATE_LISTED to STATE_ACTIVE', state == STATE_ACTIVE)

	-- (c) An ID_QUERY reply ALONE - no APPROVED ever seen, and the resend budget not yet exhausted -
	-- must NOT promote an unapproved STATE_IDENTIFYING session to STATE_ACTIVE. This is the exact bug:
	-- the query reply is not proof of approval. identifyFallback must be false here or this would
	-- pass for the wrong reason (the fallback floor, tested separately below).
	state = STATE_IDENTIFYING
	identifyFallback = false
	pendingMessages = {}
	controller_midi_in(qreply(), 'LINK')
	check('an ID_QUERY reply alone does not promote an unapproved session before the fallback engages',
		state == STATE_IDENTIFYING)

	-- (c2) Once the fallback floor has engaged (resend budget exhausted, still no APPROVED), an
	-- ID_QUERY reply DOES promote - reverting to the pre-fix self-heal so the session cannot go
	-- permanently silent. See
	-- docs/config-lua-history.md#identification-approval-and-rejection-are-lost-in-mainstages-init-window-2026-09-10.
	state = STATE_IDENTIFYING
	identifyFallback = true
	pendingMessages = {}
	controller_midi_in(qreply(), 'LINK')
	check('an ID_QUERY reply promotes STATE_IDENTIFYING to STATE_ACTIVE once identifyFallback is set',
		state == STATE_ACTIVE)

	-- (d) A 7F 02 REJECTED reply still enters STATE_REIDENTIFY_WAIT and retries the SAME instanceID -
	-- never bumping on a first rejection (see handle_identification_rejected's comment).
	state = STATE_IDENTIFYING
	local sameInstance = instanceID
	reidentifyRetriesLeft = MAX_SAME_ID_RETRIES
	pendingMessages = {}
	timerPending = false
	armed = nil
	controller_midi_in(rejected_frame(0x00), 'LINK')
	check('7F 02 REJECTED enters STATE_REIDENTIFY_WAIT', state == STATE_REIDENTIFY_WAIT)
	check('a first rejection retries the SAME instanceID, no bump', instanceID == sameInstance)
	check('a first rejection decrements reidentifyRetriesLeft',
		reidentifyRetriesLeft == MAX_SAME_ID_RETRIES - 1)
	check('rearm_timer armed the REIDENTIFY_WAIT_MS one-shot', armed == REIDENTIFY_WAIT_MS)

	-- The wait elapsing fires controller_timer_trigger, which must retry - still the SAME id, not a
	-- bumped one.
	pendingMessages = {}
	out = controller_timer_trigger()
	check('the reidentify-wait retry re-sends as the SAME instanceID', instanceID == sameInstance)
	check('the reidentify-wait retry queues an Identification Request',
		id_requests_in(out and out.midi) == 1)

	state, pendingMessages, instanceID, identifyResendsLeft, identifyFallback, reidentifyRetriesLeft,
		armed, timerPending =
		savedState, savedPending, savedInstanceID, savedIdentifyResendsLeft, savedIdentifyFallback,
		savedReidentifyRetriesLeft, savedArmed, savedTimerPending
end

-- MARK: - 37. flush_pending ALWAYS appends the trailing query when includeQuery is true, Master
-- Volume included - the omission experiment (docs/config-lua-history.md
-- #master-volume-writes-go-out-unpaired-2026-09-10) is REVERTED: it wasn't what made Master Volume
-- work (a paired READ was), and dropping the query starved the session clock during an A-encoder
-- sweep, since most flushes in a sweep are Master Volume messages.
do
	local savedPending, savedFlushReady = pendingMessages, displayFlushReady
	local query = msg_identification_query()

	-- (a) A Master Volume write goes out PAIRED with the query, like any other message.
	pendingMessages = {}
	slFlushReady = true
	queue_message(msg_master_volume_write(77), 'mvol')
	local out = flush_pending(true)
	check('a Master Volume flush returns output', out ~= nil and out.midi ~= nil)
	if out then
		local msgs = split_messages(out.midi)
		check('a Master Volume flush carries two messages (write + query)', #msgs == 2)
		check('...the write first', #msgs == 2 and item_type_of(msgs[1]) == IT_MASTER_VOLUME)
		check('...ending with the Identification Query', #msgs == 2 and hex(msgs[#msgs]) == hex(query))
	end

	-- (b) A display message still carries the query too - the existing invariant (section 2),
	-- confirming the revert didn't touch this path either.
	pendingMessages = {}
	displayFlushReady = true
	slFlushReady = true
	queue_message(msg_draw_rect(0, 0, 10, 10, 0, 0, 0), 'test:mvol-query-regression')
	out = flush_pending(true)
	check('a display flush still returns output', out ~= nil and out.midi ~= nil)
	if out then
		local msgs = split_messages(out.midi)
		check('a display flush still carries two messages (display + query)', #msgs == 2)
		check('...ending with the Identification Query',
			#msgs == 2 and hex(msgs[#msgs]) == hex(query))
	end

	pendingMessages, displayFlushReady = savedPending, savedFlushReady
end

-- MARK: - 38. flush_pending no longer special-cases Master Volume for the clock - the paired query
-- above IS the re-arm mechanism now, so the request_quick_rearm() call this section used to check
-- (added alongside the unpairing experiment, section 37's note) is gone; a Master Volume flush must
-- leave an outstanding one-shot untouched, exactly like any other paired flush.
do
	local savedState, savedPending, savedTimerPending, savedTimerArmedInterval, savedArmed =
		state, pendingMessages, timerPending, timerArmedInterval, armed

	state = STATE_ACTIVE
	pendingMessages = {}
	queue_message(msg_master_volume_write(50), 'mvol')

	-- Simulate the common case: an outstanding one-shot already armed at the long KEEPALIVE_MS
	-- interval, same as a quiet session would have before this write was queued.
	timerPending = true
	timerArmedInterval = KEEPALIVE_MS
	armed = nil

	flush_pending(true)

	check(
		'a Master Volume flush does NOT shorten an outstanding KEEPALIVE_MS one-shot (no special-case rearm)',
		armed == nil
	)
	check('...and timerArmedInterval is left untouched', timerArmedInterval == KEEPALIVE_MS)

	state, pendingMessages, timerPending, timerArmedInterval, armed =
		savedState, savedPending, savedTimerPending, savedTimerArmedInterval, savedArmed
end

-- MARK: - 39. A fast A-encoder sweep cannot starve the clock or pile up Master Volume writes
--
-- Each tick is itself an inbound SL frame, and controller_midi_in calls rearm_timer()
-- unconditionally on every one (rule 6) independent of whether that tick's own flush carried a
-- query; the 'mvol' regionId coalesces every tick to a single queued write (section 27), so that
-- queue never grows with tick count - bounded regardless of how many ticks land, which is the
-- property this section checks. No per-tick READ is queued any more (see
-- docs/config-lua-history.md#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13),
-- so the backlog is exactly <= 1, not just bounded. show_master_volume_popup is stubbed out - its
-- own display traffic is a separate concern (section 27/28) that would otherwise obscure this
-- section's own assertions.
do
	local savedState, savedPending, savedTimerPending, savedTimerArmedInterval, savedArmed,
		savedMasterVolume, savedMvolFlushReady =
		state, pendingMessages, timerPending, timerArmedInterval, armed, masterVolume, mvolFlushReady

	local originalShowMVPopup = show_master_volume_popup
	show_master_volume_popup = function() end

	local function encoder_frame(tickByte)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, EID_A, tickByte, 0xF7)
	end

	state = STATE_ACTIVE
	masterVolume = 50
	pendingMessages = {}
	timerPending = false
	-- Left true throughout: this section checks the backlog stays bounded and the clock stays armed
	-- REGARDLESS of the write-pacing gate's state, not the gate's own behaviour - see section 54 for
	-- that.
	mvolFlushReady = true
	slFlushReady = true

	for _ = 1, 20 do
		controller_midi_in(encoder_frame(0x41), 'LINK') -- delta +1 each tick
	end

	check(
		'20 rapid A-encoder ticks settle at a bounded backlog (never more than one leftover message)',
		#pendingMessages <= 1
	)
	check('masterVolume reflects all 20 ticks (50 + 20)', masterVolume == 70)
	check('the clock is armed by the time the sweep ends (rearm_timer ran every tick)', timerPending == true)

	show_master_volume_popup = originalShowMVPopup
	state, pendingMessages, timerPending, timerArmedInterval, armed, masterVolume, mvolFlushReady =
		savedState, savedPending, savedTimerPending, savedTimerArmedInterval, savedArmed, savedMasterVolume,
		savedMvolFlushReady
end

-- MARK: - 40. Per-instance log tag
--
-- MainStage runs one script instance per matched USB-MIDI interface, all sharing one stdout - see
-- the instanceTag/compute_instance_tag comment in config.lua. Checks the [sllink tag/id] prefix
-- format on this single loaded instance, then exercises compute_instance_tag directly with distinct
-- simulated per-state inputs. An earlier version of this test instead spawned two `lua` processes
-- and compared their real tags, which failed intermittently: separate fresh Lua states frequently
-- allocate at the same address, so that comparison depended on allocator luck rather than the code.
do
	check('instanceTag is a 6-character lowercase hex string',
		instanceTag ~= nil and instanceTag:match('^%x%x%x%x%x%x$') ~= nil)

	local captured = nil
	local originalPrint = print
	print = function(msg) captured = msg end
	slog('probe')
	print = originalPrint

	check('slog output matches the documented [sllink tag/id] prefix format',
		captured == '[sllink ' .. instanceTag .. '/' .. string.format('%02X', instanceID) .. '] probe')

	check('compute_instance_tag output is always a 6-character lowercase hex string',
		compute_instance_tag(0, 0, 0, 0, 0):match('^%x%x%x%x%x%x$') ~= nil)

	check('compute_instance_tag is deterministic for identical inputs',
		compute_instance_tag(0x1000, 0x2000, 0x3000, 0x4000, 12.5) ==
		compute_instance_tag(0x1000, 0x2000, 0x3000, 0x4000, 12.5))

	check('compute_instance_tag mixes each input: two simulated states differing in only one value get different tags',
		compute_instance_tag(0x1000, 0x2000, 0x3000, 0x4000, 12.5) ~=
			compute_instance_tag(0x1001, 0x2000, 0x3000, 0x4000, 12.5)
		and compute_instance_tag(0x1000, 0x2000, 0x3000, 0x4000, 12.5) ~=
			compute_instance_tag(0x1000, 0x2000, 0x3000, 0x4000, 13.5))
end

-- MARK: - 41. Per-instance starting instanceID (derive_instance_start)
--
-- Each instance used to start at the literal SL_INSTANCE_START (0x6D); now it derives its starting
-- instanceID from its own instanceTag instead (see docs/config-lua-history.md, "Per-instance
-- starting id"). Exercises derive_instance_start directly with simulated tag inputs - the same
-- allocator-independent pattern section 40 already uses for compute_instance_tag - rather than
-- comparing two real cross-process instanceTags/instanceIDs.
do
	local sampleTags = { '000000', '000001', '00007e', '00007f', '0000ff', '123456', 'abcdef', 'ffffff', '800000' }
	local allInRange, all7Bit = true, true
	for _, tag in ipairs(sampleTags) do
		local id = derive_instance_start(tag)
		if id < SL_INSTANCE_MIN or id > SL_INSTANCE_MAX then allInRange = false end
		if id >= 0x80 then all7Bit = false end
	end
	check('derive_instance_start stays within [SL_INSTANCE_MIN, SL_INSTANCE_MAX] for a variety of tags',
		allInRange)
	check('derive_instance_start always returns a 7-bit value (< 0x80)', all7Bit)

	check('derive_instance_start is deterministic for the same tag',
		derive_instance_start('123456') == derive_instance_start('123456'))

	check('two different tags can yield different starting bytes',
		derive_instance_start('000001') ~= derive_instance_start('000002'))

	-- Ties the module-level assignment (instanceID = derive_instance_start(instanceTag), evaluated
	-- once at load) to the same range guarantee, not just the function checked in isolation above.
	check('the live instanceID this run actually started at is within the legal range',
		instanceID >= SL_INSTANCE_MIN and instanceID <= SL_INSTANCE_MAX)
end

-- MARK: - 42. Rejection still retries the SAME id before bumping, and the bump wraps in range
--
-- Complements section 36 (which covers the first same-id retry against a live rejected frame): this
-- calls handle_identification_rejected directly to also reach the exhausted-budget bump, confirming
-- it still wraps correctly using the new SL_INSTANCE_MIN/MAX constants. Preserves the existing
-- ordering exactly - see handle_identification_rejected's own comment and
-- docs/config-lua-history.md, "Identification and instance-ID collisions".
do
	local savedState, savedPending, savedInstanceID, savedIdentifyResendsLeft, savedIdentifyFallback,
		savedReidentifyRetriesLeft, savedArmed, savedTimerPending =
		state, pendingMessages, instanceID, identifyResendsLeft, identifyFallback, reidentifyRetriesLeft,
		armed, timerPending

	-- (a) With retries still available, a rejection retries the SAME id - no bump.
	state = STATE_IDENTIFYING
	instanceID = SL_INSTANCE_MIN + 5
	local sameId = instanceID
	reidentifyRetriesLeft = MAX_SAME_ID_RETRIES
	pendingMessages = {}
	handle_identification_rejected(0x00)
	check('a rejection with retries left keeps the SAME instanceID', instanceID == sameId)
	check('...and decrements reidentifyRetriesLeft', reidentifyRetriesLeft == MAX_SAME_ID_RETRIES - 1)

	-- (b) Once the retry budget is exhausted, the NEXT rejection bumps - and wraps SL_INSTANCE_MAX
	-- back to SL_INSTANCE_MIN rather than escaping the legal/7-bit range.
	state = STATE_IDENTIFYING
	instanceID = SL_INSTANCE_MAX
	reidentifyRetriesLeft = 0
	pendingMessages = {}
	handle_identification_rejected(0x00)
	check('exhausting the retry budget bumps instanceID (no longer the same id)', instanceID ~= SL_INSTANCE_MAX)
	check('the bump wraps SL_INSTANCE_MAX back to SL_INSTANCE_MIN', instanceID == SL_INSTANCE_MIN)
	check('the bump resets reidentifyRetriesLeft for the new id', reidentifyRetriesLeft == MAX_SAME_ID_RETRIES)

	state, pendingMessages, instanceID, identifyResendsLeft, identifyFallback, reidentifyRetriesLeft,
		armed, timerPending =
		savedState, savedPending, savedInstanceID, savedIdentifyResendsLeft, savedIdentifyFallback,
		savedReidentifyRetriesLeft, savedArmed, savedTimerPending
end

-- MARK: - 43. A popup shows the value being SENT (masterVolume), not the last READ reply
--
-- Reply timing made the displayed number jumpy on hardware (see
-- docs/config-lua-history.md#master-volume-popup-seed-from-read-track-the-write-value-2026-09-10) - the popup
-- now always shows masterVolume, the locally accumulated to-be-sent value, and never masterVolumeRead
-- directly. masterVolumeRead no longer feeds masterVolume at all, not even at a gesture's start -
-- see docs/config-lua-history.md#master-volume-read-reply-does-not-track-writes-2026-09-12 and
-- section 46.
do
	local savedMasterVolume, savedMasterVolumeRead, savedPopupValue, savedPopupMax, savedPopupActive,
		savedDisplayMode, savedPopupPreviousMode, savedArmed, savedTimerPending, savedTimerArmedInterval =
		masterVolume, masterVolumeRead, popupValue, popupMax, popupActive, displayMode, popupPreviousMode,
		armed, timerPending, timerArmedInterval

	-- Pre-seat the popup as already showing (same 'repeat call' shortcut as section 27) so
	-- show_master_volume_popup() only exercises the value it sets, not the full mode-switch
	-- machinery - a separate, already-covered concern.
	popupActive = true
	popupPreviousMode = 'zoom'
	displayMode = 'popup'

	-- (a) No READ reply ever received: the popup shows masterVolume directly, same as any other
	-- tick - MVOL_SEED_DEFAULT means there is always a real value being sent, never a placeholder.
	-- See docs/config-lua-history.md#seed-master-volume-at-60-instead-of-refusing-to-write-2026-09-12.
	masterVolume = 77
	masterVolumeRead = nil
	show_master_volume_popup()
	check('before any READ reply, the A popup still shows masterVolume (77), not a placeholder',
		popupValue == 77)

	-- (b) A genuine READ reply (func=MVOL_READ) updates masterVolumeRead...
	handle_sl_frame(frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_MASTER_VOLUME, MVOL_READ, 33, 0, 0xF7))
	check('a READ-shaped inbound frame (func=MVOL_READ) sets masterVolumeRead from its VOL byte',
		masterVolumeRead == 33)

	-- ...but the popup keeps showing masterVolume, unperturbed by the reply that just landed.
	show_master_volume_popup()
	check('after a READ reply, the A popup still shows masterVolume (77), not the reply value (33)',
		popupValue == 77)

	-- (c) No live caller passes nil any more (MVOL_SEED_DEFAULT replaced the placeholder), but the
	-- defensive fallback must still render as icon 0 (empty), not a crash or a misleading full ring.
	check('popup_knob_icon(nil) renders as icon 0 (empty ring), not a crash or a full ring',
		popup_knob_icon(nil) == 0)

	-- (d) Same defensive coverage for draw_popup_value: '--', never the string "nil".
	local savedDrawn, savedPending = drawn, pendingMessages
	drawn, pendingMessages = {}, {}
	draw_popup_value(nil)
	check('draw_popup_value(nil) queues exactly one draw', #pendingMessages == 1)
	if #pendingMessages == 1 then
		checkHex(
			'...matching the exact bytes of Write Text "--" at the popup value\'s own position/colours',
			pendingMessages[1],
			hex(msg_write_text('--', POPUP_VALUE_X, POPUP_VALUE_Y, POPUP_VALUE_W, ALIGN_CENTER, SIZE_MEDIUM,
				POPUP_VALUE_FG[1], POPUP_VALUE_FG[2], POPUP_VALUE_FG[3],
				POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3]))
		)
	end
	drawn, pendingMessages = savedDrawn, savedPending

	masterVolume, masterVolumeRead, popupValue, popupMax, popupActive, displayMode, popupPreviousMode,
		armed, timerPending, timerArmedInterval =
		savedMasterVolume, savedMasterVolumeRead, savedPopupValue, savedPopupMax, savedPopupActive,
		savedDisplayMode, savedPopupPreviousMode, savedArmed, savedTimerPending, savedTimerArmedInterval
end

-- MARK: - 44. A Master Volume READ reply landing between EID_A ticks never resurrects a queued read
--
-- See docs/config-lua-history.md#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13.
-- Sections 27/39 cover the plain no-read-ever-queued case.
do
	local savedPending, savedPopupActive, savedDisplayMode, savedMasterVolumeRead =
		pendingMessages, popupActive, displayMode, masterVolumeRead

	popupActive = true
	popupPreviousMode = 'zoom'
	displayMode = 'popup'

	local function encoder_frame(tickByte)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, EID_A, tickByte, 0xF7)
	end
	local function read_reply_frame(vol)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_MASTER_VOLUME, MVOL_READ, vol, 0xF7)
	end
	local function mvol_read_messages()
		local out = {}
		for i = 1, #pendingMessages do
			if pendingMessages[i].regionId == 'mvolRead' then out[#out + 1] = pendingMessages[i] end
		end
		return out
	end

	pendingMessages = {}
	handle_sl_frame(encoder_frame(0x41))
	handle_sl_frame(read_reply_frame(60))
	pendingMessages = {}
	handle_sl_frame(encoder_frame(0x41))
	check('a READ reply landing between ticks does not bring the read poll back',
		#mvol_read_messages() == 0)

	pendingMessages, popupActive, displayMode, masterVolumeRead =
		savedPending, savedPopupActive, savedDisplayMode, savedMasterVolumeRead
end

-- MARK: - 45. A Master Volume READ reply never overwrites masterVolume, only masterVolumeRead
--
-- Superseded design: masterVolume used to be re-trusted from a READ reply once
-- MVOL_GESTURE_WINDOW_FRAMES had passed since the last EID_A tick (see
-- docs/config-lua-history.md#master-volume-drop-detection-read-rate-limiting-and-the-mid-gesture-guard-2026-09-10).
-- Now the popup shows masterVolume directly (section 43), so a READ reply landing at ANY time -
-- mid-gesture or long after - must never perturb it. Section 46 goes further: not even a fresh
-- gesture's start reseeds from it any more - see
-- docs/config-lua-history.md#master-volume-read-reply-does-not-track-writes-2026-09-12.
-- masterVolumeRead keeps updating from every reply regardless.
do
	local savedMasterVolume, savedMasterVolumeRead, savedPopupActive, savedDisplayMode =
		masterVolume, masterVolumeRead, popupActive, displayMode

	popupActive = true
	popupPreviousMode = 'zoom'
	displayMode = 'popup'

	local function encoder_frame(tickByte)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, EID_A, tickByte, 0xF7)
	end
	local function read_reply_frame(vol)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_MASTER_VOLUME, MVOL_READ, vol, 0xF7)
	end

	-- (a) An EID_A tick advances masterVolume locally.
	masterVolume = 50
	handle_sl_frame(encoder_frame(0x41)) -- delta +1 -> 51
	check('EID_A tick sets masterVolume to the local delta (51)', masterVolume == 51)

	-- (b) A READ reply lands immediately after (classic "mid-gesture" timing) - masterVolume is
	-- untouched, masterVolumeRead updates.
	handle_sl_frame(read_reply_frame(40))
	check('a READ reply right after an EID_A tick does NOT overwrite masterVolume', masterVolume == 51)
	check('...but still updates the device-reported masterVolumeRead', masterVolumeRead == 40)

	-- (c) A second READ reply, with no further gesture activity in between, STILL does not overwrite
	-- masterVolume - only masterVolumeRead. Old design re-trusted the reply here; current design never
	-- does, at any time - see section 46.
	handle_sl_frame(read_reply_frame(35))
	check('a second READ reply with no EID_A tick in between still does NOT overwrite masterVolume',
		masterVolume == 51)
	check('...masterVolumeRead updates regardless', masterVolumeRead == 35)

	masterVolume, masterVolumeRead, popupActive, displayMode =
		savedMasterVolume, savedMasterVolumeRead, savedPopupActive, savedDisplayMode
end

-- MARK: - 46. EID_A never reseeds masterVolume from masterVolumeRead - tracked locally only
--
-- Hardware log: a Master Volume READ reply answered a fixed 71 across a whole sweep of writes that
-- took audible effect (65 -> 70 -> 72), so the reply cannot be the device's current output level -
-- see docs/config-lua-history.md#master-volume-read-reply-does-not-track-writes-2026-09-12.
-- masterVolume now changes ONLY by accumulated EID_A deltas, never reseeded from masterVolumeRead at
-- a gesture start or otherwise - this supersedes section 46's old premise (idle-tick gesture
-- boundaries no longer exist: MVOL_GESTURE_IDLE_TICKS and mvolLastActivityIdleTick are both removed).
do
	local savedMasterVolume, savedMasterVolumeRead, savedIdleTicks,
		savedPopupActive, savedDisplayMode =
		masterVolume, masterVolumeRead, idleTicks,
		popupActive, displayMode

	popupActive = true
	popupPreviousMode = 'zoom'
	displayMode = 'popup'

	local function encoder_frame(tickByte)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, EID_A, tickByte, 0xF7)
	end

	-- (a) A tick right after a fresh READ reply landed does not snap to the reply's value (80) - it
	-- only ever adds its own delta to masterVolume (50 + 1 = 51).
	idleTicks = 10
	masterVolume = 50
	masterVolumeRead = 80
	handle_sl_frame(encoder_frame(0x41)) -- delta +1
	check('a tick right after a READ reply does not reseed from it (50 + 1 = 51, not 80 + 1)',
		masterVolume == 51)

	-- (b) Pause (a long idle gap - what used to cross the old gesture boundary) during which a READ
	-- reply lands with yet another value: resuming still just accumulates onto the last local value.
	idleTicks = idleTicks + 50
	masterVolumeRead = 99
	handle_sl_frame(encoder_frame(0x41)) -- delta +1
	check('resuming after a long idle pause does not reseed (51 + 1 = 52, not 99 + 1)',
		masterVolume == 52)

	-- (c) A second pause/resume cycle, accumulating a different delta, confirms this holds across
	-- more than one gap - not just the first.
	idleTicks = idleTicks + 50
	masterVolumeRead = 1
	handle_sl_frame(encoder_frame(0x45)) -- delta +5
	check('a second pause/resume cycle still only accumulates the delta (52 + 5 = 57, not 1 + 5)',
		masterVolume == 57)

	masterVolume, masterVolumeRead, idleTicks,
		popupActive, displayMode =
		savedMasterVolume, savedMasterVolumeRead, savedIdleTicks,
		savedPopupActive, savedDisplayMode
end

-- MARK: - 47. masterVolumeRead == nil is not a special case: EID_A still writes, reads, and shows
-- the real accumulated value
--
-- The superseded "refuse to write while unconfirmed" design left the READ forever unanswered and the
-- encoder permanently dead (see
-- docs/config-lua-history.md#seed-master-volume-at-60-instead-of-refusing-to-write-2026-09-12) and
-- was replaced by seeding-from-read, now itself removed (section 46's anchor). masterVolumeRead ==
-- nil takes no special branch at all any more: a tick behaves exactly the same as with any other
-- masterVolumeRead value.
do
	local savedMasterVolume, savedMasterVolumeRead, savedIdleTicks,
		savedPending, savedPopupActive, savedDisplayMode, savedDrawn =
		masterVolume, masterVolumeRead, idleTicks, pendingMessages,
		popupActive, displayMode, drawn

	local function encoder_frame(tickByte)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, EID_A, tickByte, 0xF7)
	end
	local function mvol_write_messages()
		local out = {}
		for i = 1, #pendingMessages do
			if pendingMessages[i].regionId == 'mvol' then out[#out + 1] = pendingMessages[i] end
		end
		return out
	end
	local function mvol_read_messages()
		local out = {}
		for i = 1, #pendingMessages do
			if pendingMessages[i].regionId == 'mvolRead' then out[#out + 1] = pendingMessages[i] end
		end
		return out
	end
	local function popup_value_text()
		for i = 1, #pendingMessages do
			if pendingMessages[i].regionId == 'popupValue' then
				local chars, msg = {}, pendingMessages[i]
				for j = 24, #msg do
					if msg[j] == 0x00 then break end
					chars[#chars + 1] = string.char(msg[j])
				end
				return table.concat(chars)
			end
		end
		return nil
	end

	drawn = {}
	pendingMessages = {}
	idleTicks = 10
	masterVolume = 60
	masterVolumeRead = nil
	popupActive = false
	displayMode = 'zoom'

	-- (a) No READ reply has ever arrived: the tick still accumulates its delta, DOES write (and
	-- queues no read - that per-tick poll is gone, see section 44's anchor), and the popup shows the
	-- real value, never a placeholder.
	handle_sl_frame(encoder_frame(0x45)) -- delta +5
	check('with masterVolumeRead nil, a tick still accumulates its delta (60 + 5 = 65)',
		masterVolume == 65)
	check('...and DOES send a Master Volume write', #mvol_write_messages() == 1)
	check('...and queues no Master Volume read', #mvol_read_messages() == 0)
	check('...and the popup shows the real accumulated value (65), not a placeholder',
		popup_value_text() == tostring(65))

	-- (b) A further tick still just accumulates, still with no read queued.
	pendingMessages = {}
	handle_sl_frame(encoder_frame(0x41))
	check('masterVolumeRead nil: a further tick still queues no read', #mvol_read_messages() == 0)

	-- (c) A READ reply lands: masterVolumeRead updates (section 45's invariant), but masterVolume is
	-- untouched - it was never waiting on this reply for anything but logging.
	handle_sl_frame(frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_MASTER_VOLUME, MVOL_READ, 70, 0xF7))
	check('a READ reply sets masterVolumeRead', masterVolumeRead == 70)
	check('...but does not touch masterVolume (still 66)', masterVolume == 66)

	masterVolume, masterVolumeRead, idleTicks, pendingMessages,
		popupActive, displayMode, drawn =
		savedMasterVolume, savedMasterVolumeRead, savedIdleTicks, savedPending,
		savedPopupActive, savedDisplayMode, savedDrawn
end

-- MARK: - 48. Popup dismissal threshold: POPUP_DISMISS_IDLE_TICKS
--
-- POPUP_DISMISS_IDLE_TICKS (idle ticks before the popup auto-dismisses) is now the only idle-tick
-- threshold governing popup behaviour - the Master Volume gesture boundary (MVOL_GESTURE_IDLE_TICKS)
-- was removed along with gesture-based reseeding (section 46). See
-- docs/config-lua-history.md#popup-dismiss-doubled-to-2s-2026-09-10 and
-- docs/config-lua-history.md#master-volume-read-reply-does-not-track-writes-2026-09-12.
do
	check('POPUP_DISMISS_IDLE_TICKS is 2 (~2s at POPUP_TICK_MS)', POPUP_DISMISS_IDLE_TICKS == 2)

	local savedPopupActive, savedDisplayMode, savedPopupPreviousMode, savedPopupLastActivityIdleTick,
		savedIdleTicks, savedDrawn, savedPending =
		popupActive, displayMode, popupPreviousMode, popupLastActivityIdleTick, idleTicks, drawn, pendingMessages

	drawn, pendingMessages = {}, {}

	-- (a) One idle tick since the last activity: below the new threshold, must NOT dismiss yet.
	popupActive = true
	popupPreviousMode = 'zoom'
	displayMode = 'popup'
	idleTicks = 10
	popupLastActivityIdleTick = 9
	check_popup_dismiss()
	check('one idle tick after activity: popup stays open (below POPUP_DISMISS_IDLE_TICKS=2)',
		popupActive == true)

	-- (b) Two idle ticks: at the threshold, must dismiss.
	popupActive = true
	displayMode = 'popup'
	idleTicks = 11
	popupLastActivityIdleTick = 9
	check_popup_dismiss()
	check('two idle ticks after activity: popup dismisses (meets POPUP_DISMISS_IDLE_TICKS=2)',
		popupActive == false)

	popupActive, displayMode, popupPreviousMode, popupLastActivityIdleTick, idleTicks, drawn, pendingMessages =
		savedPopupActive, savedDisplayMode, savedPopupPreviousMode, savedPopupLastActivityIdleTick,
		savedIdleTicks, savedDrawn, savedPending
end

-- MARK: - 49. STATE_REIDENTIFY_WAIT's ID_QUERY reply never promotes on a stale identifyFallback
--
-- handle_identification_rejected never clears identifyFallback, so a rejected session can sit in
-- STATE_REIDENTIFY_WAIT with it still true from an earlier STATE_IDENTIFYING fallback engagement.
-- Promotion to STATE_ACTIVE must still require STATE_LISTED or STATE_IDENTIFYING, not the flag alone.
do
	local savedState, savedPending, savedIdentifyFallback, savedArmed, savedTimerPending =
		state, pendingMessages, identifyFallback, armed, timerPending

	state = STATE_REIDENTIFY_WAIT
	identifyFallback = true
	pendingMessages = {}
	controller_midi_in(qreply(), 'LINK')
	check('an ID_QUERY reply during STATE_REIDENTIFY_WAIT does not promote to STATE_ACTIVE even with a stale identifyFallback',
		state == STATE_REIDENTIFY_WAIT)

	state, pendingMessages, identifyFallback, armed, timerPending =
		savedState, savedPending, savedIdentifyFallback, savedArmed, savedTimerPending
end

-- MARK: - 50. derive_instance_start's modulus makes SL_INSTANCE_MAX actually reachable
--
-- The modulus range width is SL_INSTANCE_MAX - SL_INSTANCE_MIN + 1; dropping the +1 silently makes
-- SL_INSTANCE_MAX unreachable while every other derive_instance_start check still passes. Sweeping
-- every residue of the range width confirms the top end is actually produced.
do
	local rangeWidth = SL_INSTANCE_MAX - SL_INSTANCE_MIN + 1
	local maxSeen = SL_INSTANCE_MIN
	for n = 0, rangeWidth - 1 do
		local id = derive_instance_start(string.format('%06x', n))
		if id > maxSeen then maxSeen = id end
	end
	check('derive_instance_start reaches SL_INSTANCE_MAX over a full residue sweep', maxSeen == SL_INSTANCE_MAX)
end

-- MARK: - 51. Bump-wrap boundary: SL_INSTANCE_MAX - 1 bumps to SL_INSTANCE_MAX without wrapping
--
-- Mirrors test 42(b), which covers the wrap FROM SL_INSTANCE_MAX; mutating instanceID > SL_INSTANCE_MAX
-- to >= passes 235/235 without this case, which must land exactly on the max and not wrap early.
do
	local savedState, savedPending, savedInstanceID, savedIdentifyResendsLeft, savedIdentifyFallback,
		savedReidentifyRetriesLeft, savedArmed, savedTimerPending =
		state, pendingMessages, instanceID, identifyResendsLeft, identifyFallback, reidentifyRetriesLeft,
		armed, timerPending

	state = STATE_IDENTIFYING
	instanceID = SL_INSTANCE_MAX - 1
	reidentifyRetriesLeft = 0
	pendingMessages = {}
	handle_identification_rejected(0x00)
	check('bumping from SL_INSTANCE_MAX - 1 lands on exactly SL_INSTANCE_MAX', instanceID == SL_INSTANCE_MAX)
	check('...and does not wrap to SL_INSTANCE_MIN', instanceID ~= SL_INSTANCE_MIN)

	state, pendingMessages, instanceID, identifyResendsLeft, identifyFallback, reidentifyRetriesLeft,
		armed, timerPending =
		savedState, savedPending, savedInstanceID, savedIdentifyResendsLeft, savedIdentifyFallback,
		savedReidentifyRetriesLeft, savedArmed, savedTimerPending
end

-- MARK: - 52. A single A-encoder gesture cannot queue an unbounded/growing burst
--
-- Hardware run: one gesture's first tick queued 11 messages via set_display_mode('popup')'s double
-- Clear Screen, and the queue kept backing up during the sweep, starving the Identification Query
-- until the SL88 dropped the app. enter_popup_mode() (see
-- docs/config-lua-history.md#popup-entry-skips-clear-screen-2026-09-12) dropped the burst to 9, and
-- the full-region erase added since (see
-- docs/config-lua-history.md#popup-entry-always-erases-its-full-region-first-2026-09-12) puts it
-- back up to 10 - a deliberate, deliberately-raised ceiling, not a regression. The per-tick Master
-- Volume READ that used to add an 11th message is gone (2026-09-13, see
-- docs/config-lua-history.md#master-volume-writes-take-effect-without-a-paired-read-probe-four-phase-result-2026-09-13),
-- so the ceiling dropped to 11 (10 display + the write); the A button's mute hint line
-- (2026-09-14, see docs/config-lua-history.md#a-encoder-button-mute-2026-09-14) adds one more display
-- message on the Master Volume popup specifically, bringing it to 12. This section pins both the
-- first-tick ceiling and that a following tick never grows the queue further, so either regression is
-- caught without needing hardware.
do
	local savedPending, savedDrawn, savedMasterVolume, savedMasterVolumeRead, savedPopupActive,
		savedDisplayMode, savedIdleTicks =
		pendingMessages, drawn, masterVolume, masterVolumeRead, popupActive, displayMode, idleTicks

	local function encoder_frame(tickByte)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, EID_A, tickByte, 0xF7)
	end

	drawn = {}
	pendingMessages = {}
	masterVolume = 50
	masterVolumeRead = 50
	popupActive = false
	displayMode = 'zoom'
	idleTicks = 10

	-- (a) First tick shows a fresh popup: erase + bg + 4 border + label + knob + value + sacrificial
	-- = 10, plus the mute hint (Master Volume popup only) = 11, plus the write = 12 at most. A
	-- regression back to set_display_mode's double Clear Screen, a dropped erase-rect invalidation
	-- forcing a repeat resend, or the per-tick READ poll coming back, would push this past 12.
	handle_sl_frame(encoder_frame(0x41)) -- delta +1
	local firstTickCount = #pendingMessages
	check('first tick of a gesture queues at most 12 messages total', firstTickCount <= 12)

	-- (b) A second tick that only moves the value coalesces into the SAME queued entries (write,
	-- knob, value all replace in place) rather than growing the queue - this is what makes a
	-- sustained sweep safe regardless of how many ticks it contains.
	handle_sl_frame(encoder_frame(0x41)) -- delta +1
	check("a subsequent tick does not grow the queue past the first tick's count",
		#pendingMessages <= firstTickCount)

	pendingMessages, drawn, masterVolume, masterVolumeRead, popupActive, displayMode, idleTicks =
		savedPending, savedDrawn, savedMasterVolume, savedMasterVolumeRead, savedPopupActive,
		savedDisplayMode, savedIdleTicks
end

-- MARK: - 53. Popup entry always erases its full region first, and never skips it as unchanged
--
-- Change 2 (see docs/config-lua-history.md#popup-entry-always-erases-its-full-region-first-2026-09-12):
-- enter_popup_mode() queues one filled Draw Rectangle over the WHOLE popup rect (border included) as
-- the very first message, before bg/border/label/knob/value. draw_rect() memoizes by id, so this
-- must not be silently skipped on a later popup opening just because its own tuple - and the tuples
-- of everything it overlaps - happen to be unchanged from a previous session.
do
	local savedPending, savedDrawn, savedDisplayMode, savedPopupActive =
		pendingMessages, drawn, displayMode, popupActive

	-- (a) A fresh popup entry: the erase is the FIRST display message queued, with the exact bytes of
	-- a Draw Rectangle over the whole POPUP_X/Y/W/H rect in POPUP_BG_COLOR.
	drawn = {}
	pendingMessages = {}
	displayMode = 'zoom'
	popupActive = false
	enter_popup_mode()
	check('popup entry queues at least one message', #pendingMessages >= 1)
	if #pendingMessages >= 1 then
		check('...and the FIRST one is the popupErase region', pendingMessages[1].regionId == 'popupErase')
		checkHex('...matching the exact bytes of a Draw Rectangle over the whole popup rect',
			pendingMessages[1],
			hex(msg_draw_rect(POPUP_X, POPUP_Y, POPUP_W, POPUP_H,
				POPUP_BG_COLOR[1], POPUP_BG_COLOR[2], POPUP_BG_COLOR[3])))
	end

	-- (b) A LATER popup entry, with drawn[] still holding the exact same tuples from (a) (as if
	-- dismiss_popup()'s own invalidate_all() had not run) - the erase, and everything it overlaps,
	-- must still resend, not be skipped as "unchanged".
	pendingMessages = {}
	enter_popup_mode()
	check('a later popup entry (memo unchanged from before) still queues the erase first',
		#pendingMessages >= 1 and pendingMessages[1].regionId == 'popupErase')
	local bgCount, borderCount = 0, 0
	for i = 1, #pendingMessages do
		local id = pendingMessages[i].regionId
		if id == 'popupBg' then bgCount = bgCount + 1 end
		if id == 'popupBorderTop' or id == 'popupBorderBottom' or id == 'popupBorderLeft' or id == 'popupBorderRight' then
			borderCount = borderCount + 1
		end
	end
	check('...and popupBg resends too, not suppressed as unchanged', bgCount == 1)
	check('...and all 4 border strips resend too, not suppressed as unchanged', borderCount == 4)

	pendingMessages, drawn, displayMode, popupActive =
		savedPending, savedDrawn, savedDisplayMode, savedPopupActive
end

-- MARK: - 54. Master Volume write pacing: mvolFlushReady limits WRITE to one emission per tick
--
-- See docs/config-lua-history.md#master-volume-write-pacing-one-per-tick-2026-09-13: a fast A-encoder
-- gesture used to leave several Master Volume writes in a single timer tick (each inbound frame's own
-- flush_pending call dequeuing the write the 'mvol' regionId had just coalesced), then nothing until
-- the next tick - bursty spacing that sounds stepped even though the device handles a dense, evenly
-- spaced write stream smoothly. mvolFlushReady (mirroring displayFlushReady) now gates the WRITE to
-- one per tick; the READ and every protocol message stay ungated. Exercises flush_pending directly,
-- matching the granularity of the equivalent displayFlushReady tests (sections 10/11/37).
do
	local savedPending, savedDisplayFlushReady, savedMvolFlushReady, savedMvolFastCredits =
		pendingMessages, displayFlushReady, mvolFlushReady, mvolFastWritesThisTick

	local function mvol_writes_in(bytes)
		local out = {}
		for _, m in ipairs(split_messages(bytes or {})) do
			if item_type_of(m) == IT_MASTER_VOLUME and func_of(m) == MVOL_WRITE then out[#out + 1] = m end
		end
		return out
	end

	-- (a) Several writes queued within one tick (coalescing under 'mvol', like a fast twist) leave
	-- exactly one queued entry - and flushing it emits exactly one WRITE this tick, carrying the
	-- NEWEST value, not a stale intermediate one.
	pendingMessages = {}
	mvolFlushReady = true
	slFlushReady = true
	mvolFastWritesThisTick = 0 -- this section tests mvolFlushReady alone; the fast-turn bypass is section 72's concern
	queue_message(msg_master_volume_write(10), 'mvol')
	queue_message(msg_master_volume_write(20), 'mvol')
	queue_message(msg_master_volume_write(30), 'mvol')
	check('coalescing under \'mvol\' leaves exactly one queued write before any flush', #pendingMessages == 1)

	local out = flush_pending(false)
	local writes = mvol_writes_in(out and out.midi)
	check('a tick with mvolFlushReady=true emits exactly one Master Volume write', #writes == 1)
	check('...carrying the newest coalesced value (30), not a stale one (10 or 20)',
		#writes == 1 and writes[1][10] == 30)
	check('mvolFlushReady is consumed the moment the write is emitted', mvolFlushReady == false)

	-- (b) A further write queued in the SAME tick (mvolFlushReady still false) does not go out - it
	-- stays queued instead of being dropped.
	pendingMessages = {}
	queue_message(msg_master_volume_write(40), 'mvol')
	out = flush_pending(false)
	check('a second write queued before the next tick is NOT emitted (gate still closed)',
		#mvol_writes_in(out and out.midi) == 0)
	check('...it stays queued rather than being dropped', #pendingMessages == 1)

	-- (c) The next tick re-grants the gate (mirrors controller_timer_trigger's unconditional
	-- mvolFlushReady = true) - the write left over from (b) now goes out, still carrying its value.
	mvolFlushReady = true
	slFlushReady = true
	mvolFastWritesThisTick = 0
	out = flush_pending(false)
	writes = mvol_writes_in(out and out.midi)
	check('the next tick emits the write left pending from the previous tick', #writes == 1)
	check('...carrying the value queued for it (40)', #writes == 1 and writes[1][10] == 40)

	-- (d) A protocol message (keepalive) is never paced by mvolFlushReady: queued behind a
	-- currently-blocked Master Volume write, it still flushes in the same tick by jumping the queue -
	-- exactly like flush_pending's existing display/keepalive scan-forward (section 11).
	pendingMessages = {}
	mvolFlushReady = false
	slFlushReady = true -- tick permit fresh; only the mvol grant is spent
	mvolFastWritesThisTick = 0
	queue_message(msg_master_volume_write(55), 'mvol')
	queue_message(msg_system(SYS_DEVICE_NOTIFICATION))
	out = flush_pending(false)
	local keepalives = 0
	for _, m in ipairs(split_messages(out and out.midi or {})) do
		if item_type_of(m) == IT_SYSTEM and func_of(m) == SYS_DEVICE_NOTIFICATION then keepalives = keepalives + 1 end
	end
	check('a keepalive queued behind a paced-and-blocked Master Volume write still flushes this tick',
		keepalives == 1)
	check('...and the blocked write itself does not', #mvol_writes_in(out and out.midi) == 0)
	check('...the write stays queued, jumped rather than dropped', #pendingMessages == 1)

	-- (e) The Master Volume READ is a different func byte (MVOL_READ, not MVOL_WRITE) on the SAME
	-- itemType - confirms the gate keys off func, not just itemType, so a READ is never paced either.
	pendingMessages = {}
	mvolFlushReady = false
	slFlushReady = true -- tick permit fresh; only the mvol grant is spent
	mvolFastWritesThisTick = 0
	queue_message(msg_master_volume_read())
	out = flush_pending(false)
	local reads = 0
	for _, m in ipairs(split_messages(out and out.midi or {})) do
		if item_type_of(m) == IT_MASTER_VOLUME and func_of(m) == MVOL_READ then reads = reads + 1 end
	end
	check('a Master Volume READ is never paced by mvolFlushReady (gate keys off func, not itemType alone)',
		reads == 1)

	pendingMessages, displayFlushReady, mvolFlushReady, mvolFastWritesThisTick =
		savedPending, savedDisplayFlushReady, savedMvolFlushReady, savedMvolFastCredits
end

-- MARK: - 55. Recovery watchdog: recovers a STATE_ACTIVE session the SL88 silently dropped
--
-- Hardware evidence: the SL88 can stop replying to Identification Queries entirely while
-- STATE_ACTIVE - no logout, no standby - while still sending other traffic (encoder frames). A
-- similar detector was tried and removed after a suspected freeze from unbounded re-identify
-- retries - see docs/config-lua-history.md#recovering-a-silently-dropped-active-session-bounded-2026-09-13.
-- This section proves the threshold and the reset-on-reply in isolation; tests 56-58 prove the
-- cooldown, the attempt cap, and the not-ACTIVE guard.
do
	local savedState, savedPending, savedTimerPending, savedFramesSinceTick, savedArmed, savedPopupActive,
		savedSinceReply, savedCooldown, savedAttempts, savedGivenUp, savedArmedInterval, savedResends,
		savedFallback =
		state, pendingMessages, timerPending, framesSinceTick, armed, popupActive,
		activeMsSinceQueryReply, recoveryCooldownMs, recoveryAttempts, recoveryGivenUp, timerArmedInterval,
		identifyResendsLeft, identifyFallback

	-- start_identification()'s Identification Request is queued, but controller_timer_trigger's own
	-- `return flush_pending(true)` immediately dequeues one message per call - so a fired attempt
	-- shows up in the FLUSHED bytes this call returns, not in pendingMessages afterward. Checks both,
	-- so a fix that left it merely queued (never flushed) would still be caught.
	local function has_id_request(out)
		for i = 1, #pendingMessages do
			local m = pendingMessages[i]
			if item_type_of(m) == IT_IDENTIFICATION and func_of(m) == ID_REQUEST then return true end
		end
		for _, m in ipairs(split_messages(out and out.midi or {})) do
			if item_type_of(m) == IT_IDENTIFICATION and func_of(m) == ID_REQUEST then return true end
		end
		return false
	end

	-- (a) Below ACTIVE_QUERY_DROP_MS: must not fire, though the elapsed time still accumulates.
	state = STATE_ACTIVE
	pendingMessages = {}
	activeMsSinceQueryReply = 0
	recoveryCooldownMs = 0
	recoveryAttempts = 0
	recoveryGivenUp = false
	timerArmedInterval = ACTIVE_QUERY_DROP_MS - 1
	local out = controller_timer_trigger()
	check('recovery watchdog: below ACTIVE_QUERY_DROP_MS does not fire',
		state == STATE_ACTIVE and recoveryAttempts == 0 and not has_id_request(out))
	check('recovery watchdog: elapsed time still accumulates below the threshold',
		activeMsSinceQueryReply == ACTIVE_QUERY_DROP_MS - 1)

	-- (b) Reaching the threshold fires exactly once: falls to STATE_IDLE, whose existing branch
	-- (just below the watchdog in controller_timer_trigger) takes it the rest of the way to
	-- STATE_IDENTIFYING with an Identification Request queued; arms the cooldown; counts one attempt.
	pendingMessages = {}
	timerArmedInterval = 1 -- the last 1ms needed to reach ACTIVE_QUERY_DROP_MS exactly
	out = controller_timer_trigger()
	check('recovery watchdog: fires at the threshold and re-identifies',
		state == STATE_IDENTIFYING and has_id_request(out))
	check('recovery watchdog: counts the attempt', recoveryAttempts == 1)
	check('recovery watchdog: arms the cooldown', recoveryCooldownMs == RECOVERY_COOLDOWN_MS)
	check('recovery watchdog: resets its own elapsed counter on firing', activeMsSinceQueryReply == 0)

	-- (c) A query reply resets the elapsed-time counter - the ordinary healthy case where the
	-- keyboard does answer, exercised independently of the fire in (b).
	state = STATE_ACTIVE
	activeMsSinceQueryReply = 5000
	controller_midi_in(qreply(), 'LINK')
	check('recovery watchdog: an Identification Query reply resets the elapsed-time counter',
		activeMsSinceQueryReply == 0)

	state, pendingMessages, timerPending, framesSinceTick, armed, popupActive,
		activeMsSinceQueryReply, recoveryCooldownMs, recoveryAttempts, recoveryGivenUp, timerArmedInterval,
		identifyResendsLeft, identifyFallback =
		savedState, savedPending, savedTimerPending, savedFramesSinceTick, savedArmed, savedPopupActive,
		savedSinceReply, savedCooldown, savedAttempts, savedGivenUp, savedArmedInterval, savedResends,
		savedFallback
end

-- MARK: - 56. Recovery watchdog: cooldown prevents an attempt too soon after the last one
--
-- Isolates RECOVERY_COOLDOWN_MS from the attempt cap (test 57) and the threshold (test 55): starts
-- from a state that just fired (cooldown armed, one attempt counted) and proves a session that
-- re-hits the threshold immediately is NOT allowed to fire again until the cooldown itself elapses.
do
	local savedState, savedPending, savedSinceReply, savedCooldown, savedAttempts, savedGivenUp,
		savedArmedInterval, savedResends, savedFallback =
		state, pendingMessages, activeMsSinceQueryReply, recoveryCooldownMs, recoveryAttempts,
		recoveryGivenUp, timerArmedInterval, identifyResendsLeft, identifyFallback

	local function has_id_request(out)
		for i = 1, #pendingMessages do
			local m = pendingMessages[i]
			if item_type_of(m) == IT_IDENTIFICATION and func_of(m) == ID_REQUEST then return true end
		end
		for _, m in ipairs(split_messages(out and out.midi or {})) do
			if item_type_of(m) == IT_IDENTIFICATION and func_of(m) == ID_REQUEST then return true end
		end
		return false
	end

	state = STATE_ACTIVE
	pendingMessages = {}
	activeMsSinceQueryReply = 0
	recoveryAttempts = 1
	recoveryGivenUp = false
	recoveryCooldownMs = RECOVERY_COOLDOWN_MS -- as if a recovery attempt just fired

	-- One full tick at the threshold interval reaches ACTIVE_QUERY_DROP_MS immediately, but the
	-- cooldown (still mostly outstanding) must block it.
	timerArmedInterval = ACTIVE_QUERY_DROP_MS
	local out = controller_timer_trigger()
	check('recovery watchdog: cooldown blocks a second attempt reached too soon',
		state == STATE_ACTIVE and recoveryAttempts == 1 and not has_id_request(out))
	check('recovery watchdog: cooldown still counts down while blocking',
		recoveryCooldownMs == RECOVERY_COOLDOWN_MS - ACTIVE_QUERY_DROP_MS)

	-- Once the cooldown actually reaches zero, the same still-over-threshold condition is free to
	-- fire.
	timerArmedInterval = recoveryCooldownMs
	out = controller_timer_trigger()
	check('recovery watchdog: fires again once the cooldown has fully elapsed',
		state == STATE_IDENTIFYING and has_id_request(out) and recoveryAttempts == 2)

	state, pendingMessages, activeMsSinceQueryReply, recoveryCooldownMs, recoveryAttempts,
		recoveryGivenUp, timerArmedInterval, identifyResendsLeft, identifyFallback =
		savedState, savedPending, savedSinceReply, savedCooldown, savedAttempts, savedGivenUp,
		savedArmedInterval, savedResends, savedFallback
end

-- MARK: - 57. Recovery watchdog: caps consecutive attempts and gives up rather than retrying forever
--
-- Isolated from the cooldown (test 56): resets recoveryCooldownMs to 0 before each trigger, so only
-- MAX_RECOVERY_ATTEMPTS itself is under test. After the cap, the (MAX_RECOVERY_ATTEMPTS + 1)-th
-- would-be attempt must not re-identify, and must log clearly that recovery has given up.
do
	local savedState, savedPending, savedSinceReply, savedCooldown, savedAttempts, savedGivenUp,
		savedArmedInterval, savedResends, savedFallback =
		state, pendingMessages, activeMsSinceQueryReply, recoveryCooldownMs, recoveryAttempts,
		recoveryGivenUp, timerArmedInterval, identifyResendsLeft, identifyFallback

	local function has_id_request(out)
		for i = 1, #pendingMessages do
			local m = pendingMessages[i]
			if item_type_of(m) == IT_IDENTIFICATION and func_of(m) == ID_REQUEST then return true end
		end
		for _, m in ipairs(split_messages(out and out.midi or {})) do
			if item_type_of(m) == IT_IDENTIFICATION and func_of(m) == ID_REQUEST then return true end
		end
		return false
	end

	local function fire_once()
		state = STATE_ACTIVE
		pendingMessages = {}
		recoveryCooldownMs = 0
		activeMsSinceQueryReply = 0
		timerArmedInterval = ACTIVE_QUERY_DROP_MS
		return controller_timer_trigger()
	end

	recoveryAttempts = 0
	recoveryGivenUp = false

	for i = 1, MAX_RECOVERY_ATTEMPTS do
		local out = fire_once()
		check('recovery watchdog: attempt ' .. i .. '/' .. MAX_RECOVERY_ATTEMPTS .. ' re-identifies',
			state == STATE_IDENTIFYING and has_id_request(out))
	end
	check('recovery watchdog: has not given up within the attempt cap', not recoveryGivenUp)

	-- One more trigger beyond the cap: no re-identify, and a clear give-up log line.
	local capturedLines = {}
	local originalPrint = print
	print = function(msg) capturedLines[#capturedLines + 1] = msg end
	local givenUpOut = fire_once()
	print = originalPrint

	local function log_contains(substr)
		for _, line in ipairs(capturedLines) do
			if line:find(substr, 1, true) then return true end
		end
		return false
	end

	check('recovery watchdog: stops attempting once the cap is exceeded',
		state == STATE_ACTIVE and not has_id_request(givenUpOut))
	check('recovery watchdog: latches given-up', recoveryGivenUp == true)
	check('recovery watchdog: logs that it is giving up', log_contains('giving up'))

	state, pendingMessages, activeMsSinceQueryReply, recoveryCooldownMs, recoveryAttempts,
		recoveryGivenUp, timerArmedInterval, identifyResendsLeft, identifyFallback =
		savedState, savedPending, savedSinceReply, savedCooldown, savedAttempts, savedGivenUp,
		savedArmedInterval, savedResends, savedFallback
end

-- MARK: - 58. Recovery watchdog: never fires outside STATE_ACTIVE
--
-- Even with activeMsSinceQueryReply pre-loaded past the threshold (as if state had just left ACTIVE
-- without the accumulator being reset), no non-ACTIVE state may trigger a recovery attempt - the
-- watchdog exists to recover STATE_ACTIVE specifically, not to second-guess the ordinary
-- identify/reject/wait machinery already governing every other state.
do
	local savedState, savedPending, savedSinceReply, savedCooldown, savedAttempts, savedGivenUp,
		savedArmedInterval, savedResends, savedFallback, savedRetries, savedLogoutTicks =
		state, pendingMessages, activeMsSinceQueryReply, recoveryCooldownMs, recoveryAttempts,
		recoveryGivenUp, timerArmedInterval, identifyResendsLeft, identifyFallback,
		reidentifyRetriesLeft, logoutTicksLeft

	for _, s in ipairs({ STATE_IDLE, STATE_IDENTIFYING, STATE_LISTED, STATE_STANDBY, STATE_LOGGED_OUT }) do
		state = s
		pendingMessages = {}
		activeMsSinceQueryReply = ACTIVE_QUERY_DROP_MS + 1000
		recoveryCooldownMs = 0
		recoveryAttempts = 0
		recoveryGivenUp = false
		timerArmedInterval = 1
		controller_timer_trigger()
		check('recovery watchdog: does not fire from state=' .. s,
			recoveryAttempts == 0 and not recoveryGivenUp)
	end

	state, pendingMessages, activeMsSinceQueryReply, recoveryCooldownMs, recoveryAttempts,
		recoveryGivenUp, timerArmedInterval, identifyResendsLeft, identifyFallback,
		reidentifyRetriesLeft, logoutTicksLeft =
		savedState, savedPending, savedSinceReply, savedCooldown, savedAttempts, savedGivenUp,
		savedArmedInterval, savedResends, savedFallback, savedRetries, savedLogoutTicks
end

-- MARK: - 59. Popup value box lies entirely within the knob's MEASURED hole
--
-- The value is drawn INSIDE the ring (see docs/config-lua-history.md#value-moved-inside-the-
-- ring-2026-09-14), so its Write Text box must fit the hole measured on hardware - Write Text's
-- background box fills the whole maxWidth, and a box wider than the hole paints an opaque bar
-- through the ring itself. A hand-guessed 38 did exactly that until the hole was measured at 36:
-- docs/config-lua-history.md#write-text-box-heights-measured-2026-09-20.
check('popup value box left edge is inside the knob rect', POPUP_VALUE_X >= POPUP_KNOB_X)
check('popup value box right edge is inside the knob rect',
	POPUP_VALUE_X + POPUP_VALUE_W <= POPUP_KNOB_X + BMP_ICON_W)
check('popup value box is no wider than the measured hole', POPUP_VALUE_W <= KNOB_HOLE_W)
check('popup value box top edge is at or below the measured hole top',
	POPUP_VALUE_Y >= POPUP_KNOB_Y + KNOB_HOLE_DY)
check('popup value box bottom edge is inside the knob rect',
	POPUP_VALUE_Y + TEXT_H_MEDIUM <= POPUP_KNOB_Y + BMP_ICON_H)
check('the mute hint row reserves at least a SIZE_SMALL glyph box',
	POPUP_MUTE_HINT_H >= TEXT_H_SMALL)

-- MARK: - 60. Drawing the knob invalidates a memoized popupValue when the icon changes
--
-- THE TRAP (docs/config-lua-history.md#value-moved-inside-the-ring-2026-09-14): the Knob bitmap fully
-- replaces the pixels beneath it, and only redraws roughly every ~10 units of value while the value
-- text changes on every tick - a knob redraw is not always paired with a value change. If
-- draw_popup_value's memo were left untouched, a knob repaint at an unchanged value text would wipe
-- the number until the value itself next changed. draw_popup_knob() must clear drawn['popupValue']
-- whenever the icon it is about to draw differs from the one last drawn.
do
	local savedDrawn, savedPending, savedMax = drawn, pendingMessages, popupMax
	popupMax = 127

	-- (a) First draw at icon 0 (value 0): the value's memo starts populated. y/legacyOverlap match
	-- legacy mode - see draw_popup_knob's own comment for why the escape hatch is legacy-only.
	drawn, pendingMessages = {}, {}
	draw_popup_knob(0, POPUP_KNOB_Y, true)
	draw_popup_value(64) -- text unrelated to the knob's value on purpose, isolating the memo check
	check('popupValue memo is populated after the first draw', drawn['popupValue'] ~= nil)

	-- (b) Redrawing the knob at a value that selects the SAME icon (still icon 0) must NOT touch the
	-- value's memo - this is the ordinary per-id memoization path, unrelated to the trap.
	draw_popup_knob(1, POPUP_KNOB_Y, true)
	check('popupValue memo survives a knob redraw that keeps the same icon',
		drawn['popupValue'] ~= nil)

	-- (c) Redrawing the knob at a value that selects a DIFFERENT icon (value 127 -> icon 12) MUST
	-- clear the value's memo, even though draw_popup_value has not been called again yet - this is
	-- the actual regression guard: prove the invalidation happens inside draw_popup_knob() itself.
	draw_popup_knob(127, POPUP_KNOB_Y, true)
	check('popupValue memo is cleared when the knob icon actually changes',
		drawn['popupValue'] == nil)

	-- (d) The practical consequence: calling draw_popup_value again after that must queue a message
	-- rather than being skipped as unchanged.
	pendingMessages = {}
	draw_popup_value(64)
	check('popupValue resends after a knob redraw changed the icon', #pendingMessages == 1)

	-- (e) A DECREASING icon transition must also invalidate the memo. Every case above only ever
	-- raises the icon, so mutating the guard's `~=` to `<` (fire only when the icon increases) would
	-- slip through undetected - this drives the icon down from full to a nonzero mid-level instead.
	pendingMessages = {}
	draw_popup_value(64)
	check('popupValue memo is populated before the decreasing-icon case', drawn['popupValue'] ~= nil)
	local midValue = math.floor(popupMax / 2)
	local midIcon = popup_knob_icon(midValue)
	draw_popup_knob(midValue, POPUP_KNOB_Y, true)
	check('a decreasing icon (full -> mid-level) still clears the popupValue memo, not just an increase',
		drawn['popupValue'] == nil and midIcon < BMP_KNOB_LEVELS - 1 and midIcon > 0)
	pendingMessages = {}
	draw_popup_value(64)
	check('popupValue resends after a decreasing knob icon change', #pendingMessages == 1)

	-- (f) Returning to icon 0 from a nonzero icon must also invalidate the memo. Comparing the
	-- bitmap tuple's GROUP field (always BMP_GROUP_KNOB, constant) instead of its ICON field would
	-- collapse the guard to "current icon ~= 0", which happens to match every case above (none of
	-- them lands back on icon 0) but fails here.
	pendingMessages = {}
	draw_popup_value(64)
	check('popupValue memo is populated before the return-to-zero case', drawn['popupValue'] ~= nil)
	draw_popup_knob(0, POPUP_KNOB_Y, true)
	check('returning to icon 0 from a nonzero icon still clears the popupValue memo',
		drawn['popupValue'] == nil)
	pendingMessages = {}
	draw_popup_value(64)
	check('popupValue resends after the knob icon returns to 0', #pendingMessages == 1)

	drawn, pendingMessages, popupMax = savedDrawn, savedPending, savedMax
end

-- MARK: - 61. Sacrificial redraw under a popup matches what the popup covers, not 'popup' itself
--
-- BUG (docs/config-lua-history.md#sacrificial-redraw-painted-the-list-line-under-a-popup-2026-09-
-- 14): queue_sacrificial_redraw() used to branch on displayMode directly, so while a popup was
-- showing (displayMode == 'popup') it always took the else branch and queued the LIST screen's ctx
-- bar - even when the popup was covering the zoom screen. Confirmed on hardware: the patch list's
-- top line appeared over the zoom screen whenever a popup was up. The fix branches on
-- popupPreviousMode (what the popup covers) whenever displayMode == 'popup'.
do
	local savedDisplayMode, savedPopupPreviousMode, savedListRows, savedCursorIndex, savedConcert =
		displayMode, popupPreviousMode, listRows, cursorIndex, currentConcert
	listRows = {
		{ label = 'Test Set', isPatch = false },
		{ label = 'Test Patch', isPatch = true, setIndex = 0, patchIndex = 0 },
	}
	cursorIndex = 1
	currentConcert = 'Test Concert'
	displayMode = 'popup'

	-- (a) Popup covering the zoom screen: the duplicate must be the zoom concert line, byte-for-byte.
	popupPreviousMode = 'zoom'
	pendingMessages = {}
	queue_sacrificial_redraw()
	check('popup-over-zoom queues exactly one duplicate', #pendingMessages == 1)
	if #pendingMessages == 1 then
		checkHex(
			'popup-over-zoom sacrificial redraw matches the zoom duplicate, not the list one',
			pendingMessages[1],
			hex(msg_write_text(currentConcert, 8, 12, 304, ALIGN_CENTER, SIZE_SMALL, 120, 120, 120, 0, 0, 0))
		)
	end

	-- (b) Popup covering the LIST screen: the duplicate must be the ctx bar, byte-for-byte.
	popupPreviousMode = 'list'
	pendingMessages = {}
	queue_sacrificial_redraw()
	check('popup-over-list queues exactly one duplicate', #pendingMessages == 1)
	if #pendingMessages == 1 then
		checkHex(
			'popup-over-list sacrificial redraw matches the LIST duplicate, not the zoom one',
			pendingMessages[1],
			hex(msg_write_text(ctx_text(), ROW_X, 2, ROW_MAXW, ALIGN_LEFT, SIZE_SMALL, 120, 120, 120, 0, 0, 0))
		)
	end

	-- (c) Defensive fallback: if popupPreviousMode is somehow unset, default to the zoom duplicate
	-- (matching displayMode's own declared default), not a crash and not the list duplicate.
	popupPreviousMode = nil
	pendingMessages = {}
	queue_sacrificial_redraw()
	check('popup with unset popupPreviousMode queues exactly one duplicate', #pendingMessages == 1)
	if #pendingMessages == 1 then
		checkHex(
			'popup with unset popupPreviousMode falls back to the zoom duplicate',
			pendingMessages[1],
			hex(msg_write_text(currentConcert, 8, 12, 304, ALIGN_CENTER, SIZE_SMALL, 120, 120, 120, 0, 0, 0))
		)
	end

	displayMode, popupPreviousMode, listRows, cursorIndex, currentConcert =
		savedDisplayMode, savedPopupPreviousMode, savedListRows, savedCursorIndex, savedConcert
end

-- MARK: - 62. rearm_timer() watchdog diagnostic: rate-limited, not per-frame
--
-- A real hardware capture had the watchdog decline to fire with nothing logged, so a silent decline
-- and a correct one were indistinguishable - see
-- docs/config-lua-history.md#dead-clock-instrumentation-and-two-recovery-backstops-2026-09-14. This
-- proves the diagnostic fires once TIMER_WATCHDOG_FRAMES is crossed while has_pending() is what's
-- declining (empty queue), and is rate-limited to first-crossing plus once every
-- TIMER_WATCHDOG_DIAG_EVERY_FRAMES after - not once per inbound frame, which would flood the log
-- during ordinary play (rearm_timer runs on every inbound MIDI event, not just SL frames).
do
	local savedState, savedTimerPending, savedFramesSinceTick, savedWatchdogDiag, savedArmed,
		savedPending, savedPopupActive, savedFramesSinceQueryReply =
		state, timerPending, framesSinceTick, watchdogDiagLastFrames, armed, pendingMessages,
		popupActive, framesSinceQueryReply

	state = STATE_ACTIVE
	popupActive = false
	pendingMessages = {} -- has_pending() false: the silent-decline case the diagnostic exists for
	framesSinceQueryReply = 0
	timerPending = true
	framesSinceTick = 0
	watchdogDiagLastFrames = 0
	armed = nil

	local capturedLines = {}
	local originalPrint = print
	print = function(msg) capturedLines[#capturedLines + 1] = msg end
	local function diag_count()
		local n = 0
		for _, line in ipairs(capturedLines) do
			if line:find('timer watchdog diag', 1, true) then n = n + 1 end
		end
		return n
	end

	-- Below TIMER_WATCHDOG_FRAMES: nothing logged yet.
	for i = 1, TIMER_WATCHDOG_FRAMES - 1 do
		controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	end
	check('watchdog diag: silent below TIMER_WATCHDOG_FRAMES', diag_count() == 0)

	-- Crossing the threshold: exactly one diagnostic line, and the watchdog itself must NOT have
	-- re-armed (has_pending() is false and framesSinceTick is nowhere near TIMER_WATCHDOG_FORCE_FRAMES).
	controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	check('watchdog diag: logs once at first crossing', diag_count() == 1)
	check('watchdog diag: does not itself re-arm the timer', armed == nil)
	check('watchdog diag: timerPending still latched', timerPending == true)

	-- Between crossings: no further line until TIMER_WATCHDOG_DIAG_EVERY_FRAMES have elapsed since
	-- the last one - proves this is rate-limited, not emitted on every one of these inbound frames.
	for i = 1, TIMER_WATCHDOG_DIAG_EVERY_FRAMES - 1 do
		controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	end
	check('watchdog diag: still just one line short of the rate limit', diag_count() == 1)

	-- One more frame reaches the rate limit: a second line.
	controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	check('watchdog diag: logs again once the rate limit elapses', diag_count() == 2)

	print = originalPrint
	state, timerPending, framesSinceTick, watchdogDiagLastFrames, armed, pendingMessages,
		popupActive, framesSinceQueryReply =
		savedState, savedTimerPending, savedFramesSinceTick, savedWatchdogDiag, savedArmed,
		savedPending, savedPopupActive, savedFramesSinceQueryReply
end

-- MARK: - 63. rearm_timer() watchdog: high-frame backstop re-arms even with an empty queue
--
-- TIMER_WATCHDOG_FRAMES's has_pending() guard is deliberate (rule 6 protection - see test 34), but it
-- means a clock that dies while nothing is queued for display was never recovered before this
-- backstop existed - see
-- docs/config-lua-history.md#dead-clock-instrumentation-and-two-recovery-backstops-2026-09-14.
-- TIMER_WATCHDOG_FORCE_FRAMES forces a re-arm regardless of has_pending() once frames reach a much
-- higher bar; the original has_pending()-backed path (test 34) must be unaffected.
do
	local savedState, savedTimerPending, savedFramesSinceTick, savedWatchdogDiag, savedArmed,
		savedPending, savedPopupActive, savedFramesSinceQueryReply =
		state, timerPending, framesSinceTick, watchdogDiagLastFrames, armed, pendingMessages,
		popupActive, framesSinceQueryReply

	state = STATE_ACTIVE
	popupActive = false
	pendingMessages = {} -- has_pending() false throughout: only TIMER_WATCHDOG_FORCE_FRAMES may fire
	framesSinceQueryReply = 0
	timerPending = true

	-- (a) One frame short of the backstop: must still not re-arm.
	framesSinceTick = TIMER_WATCHDOG_FORCE_FRAMES - 1
	armed = nil
	rearm_timer()
	check('force backstop: does not fire one frame short', armed == nil)
	check('force backstop: timerPending stays latched one frame short', timerPending == true)

	-- (b) Reaching TIMER_WATCHDOG_FORCE_FRAMES: forces a re-arm despite the empty queue, and logs
	-- that it was the forced (not the queue-backed) path.
	local capturedLines = {}
	local originalPrint = print
	print = function(msg) capturedLines[#capturedLines + 1] = msg end
	local function log_contains(substr)
		for _, line in ipairs(capturedLines) do
			if line:find(substr, 1, true) then return true end
		end
		return false
	end
	framesSinceTick = TIMER_WATCHDOG_FORCE_FRAMES
	rearm_timer()
	print = originalPrint

	check('force backstop: re-arms at TIMER_WATCHDOG_FORCE_FRAMES with an empty queue',
		armed == KEEPALIVE_MS)
	check('force backstop: resets framesSinceTick', framesSinceTick == 0)
	check('force backstop: log marks it as the forced path', log_contains('forced - queue was empty'))

	-- (c) The original has_pending()-backed path (test 34) is unchanged by adding the backstop: it
	-- still fires at the much lower TIMER_WATCHDOG_FRAMES once something is queued, and its log does
	-- NOT carry the forced marker - the two backstops stay distinguishable in a hardware capture.
	pendingMessages = {}
	queue_message(msg_draw_rect(0, 0, 1, 1, 0, 0, 0), 'test:force-backstop')
	timerPending = true
	framesSinceTick = TIMER_WATCHDOG_FRAMES
	armed = nil
	capturedLines = {}
	print = function(msg) capturedLines[#capturedLines + 1] = msg end
	rearm_timer()
	print = originalPrint
	check('force backstop: has_pending()-backed path at TIMER_WATCHDOG_FRAMES still fires unchanged',
		armed == FLUSH_SOON_MS)
	check('force backstop: has_pending()-backed path log carries no forced marker',
		log_contains('one-shot lost') and not log_contains('forced'))

	state, timerPending, framesSinceTick, watchdogDiagLastFrames, armed, pendingMessages,
		popupActive, framesSinceQueryReply =
		savedState, savedTimerPending, savedFramesSinceTick, savedWatchdogDiag, savedArmed,
		savedPending, savedPopupActive, savedFramesSinceQueryReply
end

-- MARK: - 64. Recovery watchdog reachable from the inbound path when the session clock is dead
--
-- The ms-based watchdog in controller_timer_trigger structurally cannot fire once ticks have
-- stopped - its elapsed-ms accumulator only advances inside a tick - which is why it has never fired
-- across three hardware sessions despite genuine drops. See
-- docs/config-lua-history.md#dead-clock-instrumentation-and-two-recovery-backstops-2026-09-14.
-- check_inbound_recovery(), called from controller_midi_in, uses framesSinceQueryReply instead, so it
-- can trigger with zero ticks in between - controller_timer_trigger() is never called anywhere in
-- this test, simulating exactly that.
do
	local savedState, savedPending, savedFramesSinceQueryReply, savedCooldown, savedAttempts,
		savedGivenUp, savedTimerPending, savedFramesSinceTick =
		state, pendingMessages, framesSinceQueryReply, recoveryCooldownMs, recoveryAttempts,
		recoveryGivenUp, timerPending, framesSinceTick

	state = STATE_ACTIVE
	pendingMessages = {}
	framesSinceQueryReply = 0
	recoveryCooldownMs = 0
	recoveryAttempts = 0
	recoveryGivenUp = false

	-- (a) Below the threshold: state stays ACTIVE, no attempt counted.
	for i = 1, ACTIVE_QUERY_DROP_FRAMES - 1 do
		controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	end
	check('inbound recovery: below ACTIVE_QUERY_DROP_FRAMES does not fire',
		state == STATE_ACTIVE and recoveryAttempts == 0)

	-- (b) One more inbound frame, with no tick having fired anywhere in between, reaches the
	-- threshold and drops to STATE_IDLE - controller_timer_trigger's own STATE_IDLE branch takes it
	-- the rest of the way to re-identifying once a tick eventually does fire (not exercised here).
	controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	check('inbound recovery: fires at ACTIVE_QUERY_DROP_FRAMES with the clock dead', state == STATE_IDLE)
	check('inbound recovery: counts the attempt', recoveryAttempts == 1)
	check('inbound recovery: arms the cooldown', recoveryCooldownMs == RECOVERY_COOLDOWN_MS)
	check('inbound recovery: resets its own frame counter on firing', framesSinceQueryReply == 0)

	-- (c) Cooldown blocks an immediate second attempt, even though frames keep arriving with the
	-- clock still dead.
	state = STATE_ACTIVE -- as if the earlier drop had already resumed an active session
	for i = 1, ACTIVE_QUERY_DROP_FRAMES do
		controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	end
	check('inbound recovery: cooldown blocks a second attempt reached too soon',
		state == STATE_ACTIVE and recoveryAttempts == 1)

	-- (d) Once the cooldown clears (as ticks resuming would do over time), the same frame-based path
	-- fires again.
	recoveryCooldownMs = 0
	framesSinceQueryReply = 0
	for i = 1, ACTIVE_QUERY_DROP_FRAMES do
		controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	end
	check('inbound recovery: fires again once the cooldown clears',
		state == STATE_IDLE and recoveryAttempts == 2)

	-- (e) Attempt cap: one more successful cycle reaches MAX_RECOVERY_ATTEMPTS; the cycle after that
	-- must give up rather than retry forever - the same cap trigger_recovery() enforces for the
	-- ms-based path (test 57), reached here via frames instead of elapsed ms.
	recoveryCooldownMs = 0
	framesSinceQueryReply = 0
	state = STATE_ACTIVE
	for i = 1, ACTIVE_QUERY_DROP_FRAMES do
		controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	end
	check('inbound recovery: reaches the attempt cap',
		recoveryAttempts == MAX_RECOVERY_ATTEMPTS and not recoveryGivenUp)

	recoveryCooldownMs = 0
	framesSinceQueryReply = 0
	state = STATE_ACTIVE
	for i = 1, ACTIVE_QUERY_DROP_FRAMES do
		controller_midi_in(frame(0x90, 0x40, 0x64), 'LINK')
	end
	check('inbound recovery: gives up beyond the cap instead of retrying forever',
		recoveryGivenUp == true and state == STATE_ACTIVE)

	state, pendingMessages, framesSinceQueryReply, recoveryCooldownMs, recoveryAttempts,
		recoveryGivenUp, timerPending, framesSinceTick =
		savedState, savedPending, savedFramesSinceQueryReply, savedCooldown, savedAttempts,
		savedGivenUp, savedTimerPending, savedFramesSinceTick
end

-- MARK: - 65. Popup value throttle: at most every POPUP_VALUE_THROTTLE_TICKS ticks, never stale,
-- and the knob's own invalidation still wins
--
-- Flicker measurement (399 popupValue repaints vs the ring's 76, hardware capture): an opaque Write
-- Text redraw on essentially every tick reads as a visible blink on a device with no compositing.
-- queue_popup_value()/flush_popup_value_if_due() throttle popupValue's redraw to at most once every
-- POPUP_VALUE_THROTTLE_TICKS ticks - see docs/config-lua-history.md#popup-value-repaint-throttled-
-- 2026-09-14. These tests drive the two functions directly against a synthetic timerTicks sequence,
-- the same way section 60 drives draw_popup_knob() directly.
do
	local savedDrawn, savedPending, savedActive, savedValue, savedMax, savedTicks,
		savedLastPaint, savedDirty =
		drawn, pendingMessages, popupActive, popupValue, popupMax, timerTicks,
		popupValueLastPaintTick, popupValueDirty

	popupActive = true
	popupMax = 127

	-- (a) At most once every POPUP_VALUE_THROTTLE_TICKS ticks during continuous motion: the value
	-- changes on EVERY tick (as a fast encoder sweep does), but only 1 draw in 3 must reach the wire.
	drawn, pendingMessages = {}, {}
	timerTicks = 1000
	popupValue = 10
	queue_popup_value() -- first call always paints (drawn['popupValue'] starts nil)
	check('popup value throttle: the first paint is never throttled', #pendingMessages == 1)

	local drawsInWindow = 0
	for i = 1, 9 do
		pendingMessages = {}
		timerTicks = 1000 + i
		popupValue = 10 + i -- genuinely new text every tick, so a suppressed draw is a real suppression
		queue_popup_value()
		drawsInWindow = drawsInWindow + #pendingMessages
	end
	check('popup value throttle: exactly 1 draw per 3 ticks over 9 ticks of continuous motion (3, not 9)',
		drawsInWindow == 3)

	-- (b) The final value is painted once motion stops, not left stale: a throttled change must
	-- still reach the wire once POPUP_VALUE_THROTTLE_TICKS have elapsed with no further motion.
	drawn, pendingMessages = {}, {}
	timerTicks = 2000
	popupValue = 42
	queue_popup_value()
	pendingMessages = {}

	timerTicks = 2001
	popupValue = 43 -- the settled value - no further changes after this
	queue_popup_value()
	check('popup value throttle: a change 1 tick after the last paint is withheld, not sent',
		#pendingMessages == 0 and popupValueDirty == true)

	-- Ticks keep arriving (as controller_timer_trigger's keepalive does) with no more encoder input.
	timerTicks = 2002
	flush_popup_value_if_due()
	check('popup value throttle: still withheld 2 ticks after the last paint', #pendingMessages == 0)

	timerTicks = 2003
	flush_popup_value_if_due()
	check('popup value throttle: settled value (43) is painted once 3 ticks have elapsed, not left stale',
		#pendingMessages == 1 and write_text_body(pendingMessages[1]) == '43')
	check('popup value throttle: dirty flag clears once the settled value is painted', popupValueDirty == false)

	-- (c) A knob redraw that changes the icon must force popupValue through immediately, even though
	-- the throttle window has not elapsed - otherwise the number disappears until the throttle next
	-- allows a repaint (the ring wipes its own centre on every icon redraw).
	drawn, pendingMessages = {}, {}
	timerTicks = 3000
	popupValue = 64
	draw_popup_knob(0, POPUP_KNOB_Y, true) -- icon 0 - queues its own bitmap message, isolated from the value below
	pendingMessages = {}
	queue_popup_value()
	check('popup value throttle setup: first value paint after the initial knob draw', #pendingMessages == 1)

	pendingMessages = {}
	timerTicks = 3001 -- only 1 tick later - the throttle alone would withhold this
	draw_popup_knob(127, POPUP_KNOB_Y, true) -- icon 12: a genuine icon change, clears drawn['popupValue']
	pendingMessages = {} -- isolate the knob's own bitmap message from the value's below
	queue_popup_value()
	check('popup value throttle: a knob icon change forces the value through despite only 1 elapsed tick',
		#pendingMessages == 1)
	check('popup value throttle: the forced paint does not leave the throttle dirty', popupValueDirty == false)

	drawn, pendingMessages, popupActive, popupValue, popupMax, timerTicks,
		popupValueLastPaintTick, popupValueDirty =
		savedDrawn, savedPending, savedActive, savedValue, savedMax, savedTicks,
		savedLastPaint, savedDirty
end

-- MARK: - 66. flush_popup_value_if_due() is actually wired into controller_timer_trigger()
--
-- Section 65 drives flush_popup_value_if_due() directly, which proves the function's own logic but
-- nothing about its caller - deleting the call site in controller_timer_trigger() still passes
-- section 65 outright, since that section never goes through the real timer callback. This drives the
-- drain through controller_timer_trigger() itself instead, so removing the call site fails here.
--
-- popupLastActivityIdleTick is re-pinned to idleTicks after every tick below, deliberately isolating
-- this test from POPUP_DISMISS_IDLE_TICKS (section 48; ==2), which is shorter than
-- POPUP_VALUE_THROTTLE_TICKS (3) - left to drift naturally, check_popup_dismiss() (which runs before
-- flush_popup_value_if_due() inside controller_timer_trigger) would dismiss the popup on the very tick
-- the drain is due, for reasons unrelated to the wiring under test here.
do
	local savedState, savedPending, savedDrawn, savedPopupActive, savedPopupValue, savedPopupMax,
		savedTimerTicks, savedLastPaint, savedDirty, savedIdleTicks, savedLastActivity,
		savedDisplayFlushReady, savedMvolFlushReady, savedSettleTicks, savedTimerPending,
		savedFramesSinceTick, savedWatchdogFrames, savedCooldown, savedAttempts, savedGivenUp,
		savedSinceReply, savedArmedInterval, savedArmed =
		state, pendingMessages, drawn, popupActive, popupValue, popupMax,
		timerTicks, popupValueLastPaintTick, popupValueDirty, idleTicks, popupLastActivityIdleTick,
		displayFlushReady, mvolFlushReady, displaySettleTicks, timerPending,
		framesSinceTick, watchdogDiagLastFrames, recoveryCooldownMs, recoveryAttempts, recoveryGivenUp,
		activeMsSinceQueryReply, timerArmedInterval, armed

	local function write_text_in(bytes)
		for _, m in ipairs(split_messages(bytes or {})) do
			if item_type_of(m) == IT_DISPLAY and func_of(m) == DISP_WRITE_TEXT then return m end
		end
		return nil
	end

	drawn, pendingMessages = {}, {}
	state = STATE_ACTIVE
	popupActive = true
	popupMax = 127
	displayFlushReady = true
	mvolFlushReady = true
	slFlushReady = true
	displaySettleTicks = 0
	timerPending = false
	framesSinceTick = 0
	watchdogDiagLastFrames = 0
	recoveryCooldownMs = 0
	recoveryAttempts = 0
	recoveryGivenUp = false
	activeMsSinceQueryReply = 0
	timerArmedInterval = POPUP_TICK_MS -- 1000ms/tick, so 3 ticks stays far below ACTIVE_QUERY_DROP_MS
	idleTicks = 100
	popupLastActivityIdleTick = 100

	-- Seed the "settled value" state exactly like section 65(b): a first paint, then one more change
	-- that the throttle withholds, with no further motion after that.
	timerTicks = 500
	popupValue = 77
	queue_popup_value() -- forced first paint; sets popupValueLastPaintTick = 500
	pendingMessages = {}
	popupValue = 78 -- the settled value - no further changes after this
	queue_popup_value()
	check('wiring setup: the settled value is withheld by the throttle, not sent immediately',
		#pendingMessages == 0 and popupValueDirty == true)
	pendingMessages = {}

	-- Ticks 1 and 2: fewer than POPUP_VALUE_THROTTLE_TICKS (3) have elapsed since the last real paint
	-- (tick 500) - must not emit yet. Only controller_timer_trigger() is called from here on, never
	-- the drain function directly.
	for i = 1, 2 do
		local out = controller_timer_trigger()
		check('wiring: tick ' .. i .. ' after the last paint does not yet emit the withheld value',
			write_text_in(out and out.midi) == nil)
		check('wiring: tick ' .. i .. ' leaves the value still marked dirty', popupValueDirty == true)
		popupLastActivityIdleTick = idleTicks -- isolate from POPUP_DISMISS_IDLE_TICKS - see comment above
	end

	-- Tick 3: POPUP_VALUE_THROTTLE_TICKS have now elapsed (500 -> 503) - controller_timer_trigger()
	-- itself must drain the withheld value onto the wire.
	local out = controller_timer_trigger()
	local written = write_text_in(out and out.midi)
	check('wiring: controller_timer_trigger() emits the settled value once the throttle elapses',
		written ~= nil and write_text_body(written) == '78')
	check('wiring: the dirty flag is cleared once controller_timer_trigger() drains it',
		popupValueDirty == false)
	check('wiring sanity: the popup was never dismissed mid-test (would falsely explain a missing write)',
		popupActive == true)

	state, pendingMessages, drawn, popupActive, popupValue, popupMax,
		timerTicks, popupValueLastPaintTick, popupValueDirty, idleTicks, popupLastActivityIdleTick,
		displayFlushReady, mvolFlushReady, displaySettleTicks, timerPending,
		framesSinceTick, watchdogDiagLastFrames, recoveryCooldownMs, recoveryAttempts, recoveryGivenUp,
		activeMsSinceQueryReply, timerArmedInterval, armed =
		savedState, savedPending, savedDrawn, savedPopupActive, savedPopupValue, savedPopupMax,
		savedTimerTicks, savedLastPaint, savedDirty, savedIdleTicks, savedLastActivity,
		savedDisplayFlushReady, savedMvolFlushReady, savedSettleTicks, savedTimerPending,
		savedFramesSinceTick, savedWatchdogFrames, savedCooldown, savedAttempts, savedGivenUp,
		savedSinceReply, savedArmedInterval, savedArmed
end

-- MARK: - 67. The popup value throttle does not change the knob's own repaint rate
--
-- draw_popup_knob() is unmodified by the throttle above - it must still memoize purely by icon
-- (drawn[]'s existing per-id rule), with no new tick-based gating layered on top. Sweeps every value
-- 0..127 and checks a message queues exactly when the icon actually changes, never otherwise - the
-- same coverage as MARK 18's icon-mapping check, but counting messages instead of icon indices.
do
	local savedDrawn, savedPending, savedMax = drawn, pendingMessages, popupMax
	drawn, pendingMessages = {}, {}
	popupMax = 127 -- pin explicitly - popup_knob_icon scales by the global popupMax (section 28)

	local lastIcon = nil
	local changedIcons, allCorrect = 0, true
	for v = 0, 127 do
		pendingMessages = {}
		draw_popup_knob(v, POPUP_KNOB_Y, true)
		local icon = popup_knob_icon(v)
		local expected = (icon ~= lastIcon) and 1 or 0
		if expected == 1 then changedIcons = changedIcons + 1 end
		if #pendingMessages ~= expected then allCorrect = false end
		lastIcon = icon
	end
	check('popup knob repaint rate is unchanged: a message queues exactly on an icon change, never otherwise',
		allCorrect)
	check('popup knob repaint rate is unchanged: still BMP_KNOB_LEVELS distinct icon transitions over 0..127',
		changedIcons == BMP_KNOB_LEVELS)

	drawn, pendingMessages, popupMax = savedDrawn, savedPending, savedMax
end

-- MARK: - 68. A encoder button (BID_A_ENC): SHORT toggles mute, LONG resets and unmutes
--
-- SHORT writes VOL=MVOL_IGNORE_VOL (>0x64, so the firmware ignores it) with the flipped MUTE byte -
-- msg_master_volume_write() itself is untouched and still never carries MUTE (section 27's five
-- assertions pin that absence; this uses the separate msg_master_volume_mute_write() builder). LONG
-- writes a PLAIN MVOL_SEED_DEFAULT write (no MUTE byte) and separately unmutes. Both the mute write
-- and the LED are each repeated MUTE_LED_REPEATS times, with no shared regionId (so per-region
-- coalescing cannot collapse the repeats into one queued entry) - see MUTE_LED_REPEATS' declaration
-- and docs/config-lua-history.md#mute-and-led-writes-are-dropped-from-mainstage-2026-09-14.
do
	local function button_frame(bid, pressKind)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_BUTTON, bid, pressKind, 0xF7)
	end

	local function messages_with_region(regionId)
		local out = {}
		for i = 1, #pendingMessages do
			if pendingMessages[i].regionId == regionId then out[#out + 1] = pendingMessages[i] end
		end
		return out
	end

	-- Mute writes and LED writes never carry a regionId any more (queue_repeated's whole point), so
	-- they're found by content instead: mute writes are the IT_MASTER_VOLUME/MVOL_WRITE messages
	-- carrying a MUTE byte (#m == 12, vs 11 for the plain reset write), LED writes are the sole
	-- IT_LED message shape in this script.
	local function mute_writes()
		local out = {}
		for i = 1, #pendingMessages do
			local m = pendingMessages[i]
			if item_type_of(m) == IT_MASTER_VOLUME and func_of(m) == MVOL_WRITE and #m == 12 then
				out[#out + 1] = m
			end
		end
		return out
	end

	local function led_writes()
		local out = {}
		for i = 1, #pendingMessages do
			local m = pendingMessages[i]
			if item_type_of(m) == IT_LED then out[#out + 1] = m end
		end
		return out
	end

	local savedMasterVolume, savedMasterMuted, savedPending, savedPopupActive, savedDisplayMode,
		savedPopupPreviousMode, savedTimerPending =
		masterVolume, masterMuted, pendingMessages, popupActive, displayMode,
		popupPreviousMode, timerPending

	-- Pre-seat the popup as already showing (same trick as section 25's Master Volume write test)
	-- so show_master_volume_popup()'s call at the end of handle_a_encoder_button takes the lightweight
	-- 'already active' branch instead of the full mode-switch machinery - irrelevant to what these
	-- checks are about.
	popupActive = true
	displayMode = 'popup'
	popupPreviousMode = 'zoom'
	timerPending = false

	-- (a) SHORT while unmuted: toggles to muted, volume untouched, LED goes off. Repeated
	-- MUTE_LED_REPEATS times each - the count itself is the anti-coalescing proof: a regression that
	-- reintroduced a shared regionId across the repeats would collapse this back to 1.
	pendingMessages = {}
	masterVolume = 77
	masterMuted = false
	handle_sl_frame(button_frame(BID_A_ENC, PRESS_SHORT))
	check('A button SHORT does not change masterVolume', masterVolume == 77)
	check('A button SHORT flips masterMuted to true', masterMuted == true)
	local muteWrites = mute_writes()
	check('A button SHORT queues exactly one mute write', #muteWrites == 1)
	checkHex(
		'...carrying VOL=MVOL_IGNORE_VOL (0x7F, ignored since > 0x64) and MUTE=1',
		muteWrites[1],
		'F0 00 20 1A 16 03 ' .. id2() .. ' 07 01 7F 01 F7'
	)
	local ledWrites = led_writes()
	check('A button SHORT queues exactly one LED write', #ledWrites == 1)
	checkHex(
		'...carrying WLID_A_ENC and state=0 (off, muted)',
		ledWrites[1],
		'F0 00 20 1A 16 03 ' .. id2() .. ' 02 0A 00 F7'
	)

	-- (b) SHORT again while muted: toggles back to unmuted, LED goes on.
	pendingMessages = {}
	handle_sl_frame(button_frame(BID_A_ENC, PRESS_SHORT))
	check('A second SHORT flips masterMuted back to false', masterMuted == false)
	muteWrites = mute_writes()
	check('...and still queues exactly one mute write', #muteWrites == 1)
	checkHex(
		'...and the mute write now carries MUTE=0',
		muteWrites[1],
		'F0 00 20 1A 16 03 ' .. id2() .. ' 07 01 7F 00 F7'
	)
	ledWrites = led_writes()
	checkHex(
		'...and the LED write now carries state=1 (on, unmuted)',
		ledWrites[1],
		'F0 00 20 1A 16 03 ' .. id2() .. ' 02 0A 01 F7'
	)

	-- (c) LONG: resets volume via a PLAIN write (no MUTE byte) and separately unmutes via
	-- MUTE_LED_REPEATS repeated mute writes - satisfies the project's LONG-must-never-be-a-no-op rule
	-- (see config.lua's handle_home_button comment) unconditionally.
	pendingMessages = {}
	masterVolume = 20
	masterMuted = true
	handle_sl_frame(button_frame(BID_A_ENC, PRESS_LONG))
	check('A button LONG resets masterVolume to MVOL_SEED_DEFAULT', masterVolume == MVOL_SEED_DEFAULT)
	check('A button LONG unmutes', masterMuted == false)
	local resetWrites = messages_with_region('mvol')
	check('A button LONG queues exactly one plain reset write', #resetWrites == 1)
	checkHex(
		'...carrying VOL=MVOL_SEED_DEFAULT (0x3C), no MUTE byte',
		resetWrites[1],
		'F0 00 20 1A 16 03 ' .. id2() .. ' 07 01 3C F7'
	)
	local unmuteWrites = mute_writes()
	check('A button LONG also queues exactly one unmute write', #unmuteWrites == 1)
	checkHex(
		'...carrying VOL=MVOL_IGNORE_VOL and MUTE=0',
		unmuteWrites[1],
		'F0 00 20 1A 16 03 ' .. id2() .. ' 07 01 7F 00 F7'
	)
	ledWrites = led_writes()
	check('A button LONG (from muted) also queues exactly one LED write', #ledWrites == 1)
	checkHex(
		'...carrying state=1 (on, unmuted)',
		ledWrites[1],
		'F0 00 20 1A 16 03 ' .. id2() .. ' 02 0A 01 F7'
	)

	-- (d) LONG while already unmuted: the reset write still goes out, and the LED is still resent
	-- (LONG's set_master_mute(false) call is unconditional, not gated on a prior comparison) - proves
	-- the LED does not silently vanish just because mute did not actually change.
	pendingMessages = {}
	masterVolume = 99
	masterMuted = false
	handle_sl_frame(button_frame(BID_A_ENC, PRESS_LONG))
	ledWrites = led_writes()
	check('A button LONG resends one LED write even when mute was already false',
		#ledWrites == 1)

	masterVolume, masterMuted, pendingMessages, popupActive, displayMode, popupPreviousMode, timerPending =
		savedMasterVolume, savedMasterMuted, savedPending, savedPopupActive, savedDisplayMode,
		savedPopupPreviousMode, savedTimerPending
end

-- MARK: - 69. A READ reply's MUTE byte seeds masterMuted; an absent one leaves it unchanged
--
-- Mirrors section 27's tolerance test for the trailing MUTE byte being optional
-- (docs/implementing-sl-link.md §7), but for the READ func specifically, where this project actually
-- consumes MUTE (a WRITE echo still ignores it - section 27 continues to pin that).
do
	local function mvol_read_frame(vol, mute)
		if mute == nil then
			return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_MASTER_VOLUME, MVOL_READ, vol, 0xF7)
		end
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_MASTER_VOLUME, MVOL_READ, vol, mute, 0xF7)
	end

	-- LED writes carry no regionId any more (queue_repeated's whole point - see section 68's own
	-- comment), so they're found by itemType instead.
	local function led_writes()
		local out = {}
		for i = 1, #pendingMessages do
			if item_type_of(pendingMessages[i]) == IT_LED then out[#out + 1] = pendingMessages[i] end
		end
		return out
	end

	local savedMasterMuted, savedMasterVolumeRead, savedPending =
		masterMuted, masterVolumeRead, pendingMessages

	-- (a) READ reply WITH MUTE=1 seeds masterMuted true from a false starting point, and sends
	-- MUTE_LED_REPEATS LED writes.
	pendingMessages = {}
	masterMuted = false
	handle_sl_frame(mvol_read_frame(50, 1))
	check('READ reply with MUTE=1 seeds masterMuted true', masterMuted == true)
	check('...and queues exactly one LED write reflecting it', #led_writes() == 1)

	-- (b) READ reply WITH MUTE=0 seeds masterMuted false from a true starting point.
	pendingMessages = {}
	masterMuted = true
	handle_sl_frame(mvol_read_frame(50, 0))
	check('READ reply with MUTE=0 seeds masterMuted false', masterMuted == false)
	check('...and queues exactly one LED write reflecting it', #led_writes() == 1)

	-- (c) READ reply WITHOUT a MUTE byte leaves masterMuted at whatever it already was (the assumed
	-- default, per docs/implementing-sl-link.md §7's optional-trailing-byte rule) - and queues no LED
	-- write, since nothing changed.
	pendingMessages = {}
	masterMuted = false
	handle_sl_frame(mvol_read_frame(50, nil))
	check('READ reply without a MUTE byte leaves masterMuted at its default (false)', masterMuted == false)
	check('...and queues no LED write, since nothing changed', #led_writes() == 0)

	-- (d) Same, but starting muted - confirms the fallback is 'leave as-is', not 'force unmuted'.
	pendingMessages = {}
	masterMuted = true
	handle_sl_frame(mvol_read_frame(50, nil))
	check('READ reply without a MUTE byte leaves a pre-existing true value untouched', masterMuted == true)

	masterMuted, masterVolumeRead, pendingMessages = savedMasterMuted, savedMasterVolumeRead, savedPending
end

-- MARK: - 70. Master Volume settle: re-send the final value once a gesture goes idle, verified by a
-- rate-limited, diagnostic-only READ
--
-- See docs/config-lua-history.md#settle-resend-of-the-final-master-volume-write-2026-09-16. A dropped
-- MID-gesture write self-corrects on the next tick; a dropped FINAL write does not, so
-- check_mvol_settle() re-sends the settled value MUTE_LED_REPEATS times (same reasoning as the
-- mute/LED repeat workaround) once EID_A has been quiet for MVOL_SETTLE_IDLE_TICKS idle ticks, then
-- issues a rate-limited diagnostic READ. Every threshold below is read from the constant itself, not
-- hardcoded, so a mutation to a constant's VALUE cannot make these pass for the wrong reason - only
-- the >=/once-per-gesture/rate-limit BEHAVIOUR is being pinned.
do
	local function encoder_frame(eid, tickByte)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, eid, tickByte, 0xF7)
	end

	local function mvol_read_frame(vol)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_MASTER_VOLUME, MVOL_READ, vol, 0xF7)
	end

	-- Settle re-sends carry no regionId (queue_repeated's whole point), so they're told apart from an
	-- ordinary per-tick 'mvol'-regionId write by that absence.
	local function settle_writes()
		local out = {}
		for i = 1, #pendingMessages do
			local m = pendingMessages[i]
			if item_type_of(m) == IT_MASTER_VOLUME and func_of(m) == MVOL_WRITE and m.regionId == nil then
				out[#out + 1] = m
			end
		end
		return out
	end

	local function read_messages()
		local out = {}
		for i = 1, #pendingMessages do
			if item_type_of(pendingMessages[i]) == IT_MASTER_VOLUME and func_of(pendingMessages[i]) == MVOL_READ then
				out[#out + 1] = pendingMessages[i]
			end
		end
		return out
	end

	local function captured_log(action)
		local lines = {}
		local savedPrint = print
		print = function(s) lines[#lines + 1] = s end
		local ok, err = pcall(action)
		print = savedPrint
		if not ok then error(err) end
		return lines
	end

	local function contains(lines, needle)
		for _, l in ipairs(lines) do
			if tostring(l):find(needle, 1, true) then return true end
		end
		return false
	end

	local savedPending, savedVolume, savedIdle, savedTimerTicks, savedLastActivity, savedPending2,
		savedLastReadTick, savedAwaiting =
		pendingMessages, masterVolume, idleTicks, timerTicks, mvolLastActivityIdleTick, mvolSettlePending,
		mvolLastSettleReadTick, awaitingSettleRead

	-- (a) Below MVOL_SETTLE_IDLE_TICKS of quiet since the last activity: no re-send yet, still owed.
	pendingMessages = {}
	masterVolume = 60
	timerTicks = 500
	idleTicks = 100 + MVOL_SETTLE_IDLE_TICKS - 1
	mvolLastActivityIdleTick = 100
	mvolSettlePending = true
	mvolLastSettleReadTick = nil
	awaitingSettleRead = false
	check_mvol_settle()
	check('(a) below MVOL_SETTLE_IDLE_TICKS of quiet: no settle re-send yet', #settle_writes() == 0)
	check('(a) ...and no diagnostic READ either', #read_messages() == 0)
	check('(a) ...and mvolSettlePending stays true (still owed)', mvolSettlePending == true)

	-- (b) At the threshold: fires, re-sending MUTE_LED_REPEATS copies of the settled value plus
	-- exactly one diagnostic READ, and clears the pending flag.
	idleTicks = 100 + MVOL_SETTLE_IDLE_TICKS
	check_mvol_settle()
	local writesB = settle_writes()
	check('(b) at MVOL_SETTLE_IDLE_TICKS of quiet: settle re-sends the value once',
		#writesB == 1)
	for i = 1, #writesB do
		checkHex('(b) settle re-send #' .. i .. ' carries the settled value (60=0x3C), no MUTE byte',
			writesB[i], 'F0 00 20 1A 16 03 ' .. id2() .. ' 07 01 3C F7')
	end
	check('(b) settle issues exactly one diagnostic READ', #read_messages() == 1)
	check('(b) mvolSettlePending is cleared once the settle fires', mvolSettlePending == false)

	-- (c) Fires ONCE per gesture: further idle ticks with mvolSettlePending already false must not
	-- re-queue anything, however many times check_mvol_settle() runs.
	pendingMessages = {}
	idleTicks = idleTicks + 1
	check_mvol_settle()
	idleTicks = idleTicks + 5
	check_mvol_settle()
	check('(c) further idle ticks with no new activity re-send nothing', #settle_writes() == 0)
	check('(c) ...and queue no further READ', #read_messages() == 0)

	-- (d) Resuming motion and settling again re-sends: driven through the real handle_sl_frame EID_A
	-- path (not by poking flags directly), so removing that hook would fail here.
	pendingMessages = {}
	masterVolume = 50
	mvolSettlePending = false
	local idleAtGesture = idleTicks
	handle_sl_frame(encoder_frame(EID_A, 0x41)) -- delta +1, masterVolume -> 51
	check('(d) an EID_A tick marks a new gesture as pending', mvolSettlePending == true)
	check('(d) ...and pins mvolLastActivityIdleTick to idleTicks at the moment of the tick',
		mvolLastActivityIdleTick == idleAtGesture)

	pendingMessages = {}
	timerTicks = timerTicks + MVOL_SETTLE_READ_MIN_TICKS -- clear (b)'s rate-limit window
	idleTicks = idleAtGesture + MVOL_SETTLE_IDLE_TICKS
	check_mvol_settle()
	local writesD = settle_writes()
	check('(d) settling again after resumed motion re-sends the NEW value once',
		#writesD == 1)
	checkHex('(d) ...carrying VOL=51 (0x33)', writesD[1], 'F0 00 20 1A 16 03 ' .. id2() .. ' 07 01 33 F7')

	-- (e) The diagnostic READ is rate-limited over MVOL_SETTLE_READ_MIN_TICKS of timerTicks: a second
	-- settle landing inside that window still re-sends the write but must not queue another READ;
	-- once the window has elapsed, a further settle reads again. Every field is reset explicitly so
	-- this sub-test doesn't depend on state left over from (a)-(d).
	pendingMessages = {}
	masterVolume = 70
	timerTicks = 1000
	mvolLastSettleReadTick = nil
	idleTicks = 200
	mvolLastActivityIdleTick = 200 - MVOL_SETTLE_IDLE_TICKS
	mvolSettlePending = true
	check_mvol_settle()
	check('(e) first settle queues its diagnostic READ', #read_messages() == 1)

	pendingMessages = {}
	timerTicks = 1000 + MVOL_SETTLE_READ_MIN_TICKS - 1 -- still inside the rate-limit window
	idleTicks = idleTicks + MVOL_SETTLE_IDLE_TICKS
	mvolLastActivityIdleTick = idleTicks - MVOL_SETTLE_IDLE_TICKS
	mvolSettlePending = true
	check_mvol_settle()
	check('(e) a settle inside the READ rate-limit window still re-sends the write',
		#settle_writes() == 1)
	check('(e) ...but queues no further READ', #read_messages() == 0)

	pendingMessages = {}
	timerTicks = 1000 + MVOL_SETTLE_READ_MIN_TICKS -- rate-limit window has now elapsed
	idleTicks = idleTicks + MVOL_SETTLE_IDLE_TICKS
	mvolLastActivityIdleTick = idleTicks - MVOL_SETTLE_IDLE_TICKS
	mvolSettlePending = true
	check_mvol_settle()
	check('(e) a settle once the rate-limit window elapses queues a READ again', #read_messages() == 1)

	-- (f) The READ reply logs a distinct line for a match vs a mismatch, never corrects masterVolume
	-- (deliberately no correction loop), and stays silent when no settle is outstanding.
	pendingMessages = {}
	masterVolume = 60
	awaitingSettleRead = true
	local matchLines = captured_log(function() handle_sl_frame(mvol_read_frame(60)) end)
	check('(f) a matching READ reply logs a distinct confirmation line',
		contains(matchLines, 'settled volume confirmed vol=60'))
	check('(f) ...and does not touch masterVolume (diagnostic only)', masterVolume == 60)
	check('(f) ...and clears awaitingSettleRead', awaitingSettleRead == false)

	pendingMessages = {}
	masterVolume = 60
	awaitingSettleRead = true
	local mismatchLines = captured_log(function() handle_sl_frame(mvol_read_frame(55)) end)
	check('(f) a mismatching READ reply logs a distinct MISMATCH line',
		contains(mismatchLines, 'settled volume MISMATCH: sent 60, device reports 55'))
	check('(f) ...and does NOT correct masterVolume from the read (no correction loop)',
		masterVolume == 60)

	pendingMessages = {}
	masterVolume = 60
	awaitingSettleRead = false
	local unrelatedLines = captured_log(function() handle_sl_frame(mvol_read_frame(60)) end)
	check('(f) a READ reply with no settle outstanding logs neither settle line',
		not contains(unrelatedLines, 'settled volume confirmed')
			and not contains(unrelatedLines, 'settled volume MISMATCH'))

	pendingMessages, masterVolume, idleTicks, timerTicks, mvolLastActivityIdleTick, mvolSettlePending,
		mvolLastSettleReadTick, awaitingSettleRead =
		savedPending, savedVolume, savedIdle, savedTimerTicks, savedLastActivity, savedPending2,
		savedLastReadTick, savedAwaiting
end

-- MARK: - 71. The A encoder LED is (re)sent on a genuine login confirmation, not just from
-- enter_active_session()'s self-heal path
--
-- Hardware bug: enter_active_session() alone sends the LED, but the ID_QUERY self-heal path can
-- reach STATE_ACTIVE before the user has actually selected the app on the keyboard - the SL88
-- discards messages from an app that isn't selected, so that LED is silently dropped (same class of
-- bug section 35 fixed for the Master Volume read). Fix mirrors section 35 exactly: handle_login()
-- now also calls set_master_mute() whenever enter_active_session() reports it did NOT just do the
-- transition itself (i.e. every genuine LOGIN CONFIRMATION), so the LED still reaches the keyboard
-- once it can actually act on it - without double-sending on a plain reaffirmation.
do
	local savedState, savedMasterMuted, savedPending =
		state, masterMuted, pendingMessages

	local function led_writes()
		local out = {}
		for i = 1, #pendingMessages do
			if item_type_of(pendingMessages[i]) == IT_LED then out[#out + 1] = pendingMessages[i] end
		end
		return out
	end

	-- (a) Self-heal already made the session ACTIVE (enter_active_session() is a no-op here); a
	-- genuine login confirmation arriving afterward must still (re)send the LED, unmuted state.
	state = STATE_ACTIVE
	masterMuted = false
	pendingMessages = {}
	handle_login()
	local writes = led_writes()
	check('a login confirmation while already ACTIVE (self-heal) resends the LED once',
		#writes == 1)
	if #writes > 0 then
		checkHex(
			'...carrying WLID_A_ENC and state=1 (on, unmuted)',
			writes[1],
			'F0 00 20 1A 16 03 ' .. id2() .. ' 02 0A 01 F7'
		)
	end

	-- (b) Same scenario, but muted - the resent LED must carry the correct (off) byte, not a
	-- hardcoded on.
	state = STATE_ACTIVE
	masterMuted = true
	pendingMessages = {}
	handle_login()
	writes = led_writes()
	check('...and once again when the current state is muted', #writes == 1)
	if #writes > 0 then
		checkHex(
			'...this time carrying state=0 (off, muted)',
			writes[1],
			'F0 00 20 1A 16 03 ' .. id2() .. ' 02 0A 00 F7'
		)
	end

	-- (c) A plain reaffirmation (enter_active_session() called directly, not through a login
	-- confirmation) must NOT resend the LED - only handle_login()'s own genuine-confirmation branch
	-- does, or every keepalive-driven self-heal round-trip would resend it needlessly.
	state = STATE_ACTIVE
	pendingMessages = {}
	enter_active_session()
	check('a bare self-heal reaffirmation (no login confirmation) sends no LED', #led_writes() == 0)

	-- (d) A FRESH transition into ACTIVE (enter_active_session() itself performs the transition and
	-- already sends the LED once) must not have handle_login() add a second round of sends on top -
	-- still exactly MUTE_LED_REPEATS, not double.
	state = STATE_LISTED
	masterMuted = false
	pendingMessages = {}
	handle_login()
	writes = led_writes()
	check('a login confirmation that itself triggers the ACTIVE transition sends the LED exactly once (not doubled)',
		#writes == 1)

	state, masterMuted, pendingMessages = savedState, savedMasterMuted, savedPending
end

-- MARK: - 72. Fast-turn Master Volume write budget: a fast delta lets its write bypass the
-- one-per-tick pace, up to a bounded cap; a slow turn still emits at most one write per tick
--
-- Jeroen's decision (2026-09-16 hardware run): a fast A-encoder sweep trails the knob under the
-- existing one-write-per-tick pace (mvolFlushReady, section 54) - measured 120 frames in, only 105
-- writes flushed. The fix must not remove that pacing (it cures audibly uneven stepping on a SLOW
-- turn): a write is tagged .fast only when ITS OWN delta is at/above MVOL_FAST_DELTA_THRESHOLD
-- (handle_sl_frame), and flush_pending() lets a tagged write through once mvolFlushReady's single
-- per-tick grant is already spent - counted in mvolFastWritesThisTick, capped at
-- MVOL_FAST_WRITES_PER_TICK - 1 extra writes, reset only by the next real controller_timer_trigger
-- tick (not by exhausting it). See docs/config-lua-history.md#fast-turn-master-volume-write-budget-2026-09-16.
--
-- Drives real controller_midi_in round-trips (not handle_sl_frame directly) so the pacing gate,
-- rearm_timer() and the Identification Query all run exactly as they do on hardware - same approach
-- as section 39's rapid-tick sweep. show_master_volume_popup() is stubbed out, as in section 39, so
-- its own display traffic never mixes into the 'mvol'-only counts this section checks.
do
	local savedState, savedPending, savedTimerPending, savedArmed, savedMvolFlushReady,
		savedMvolFastWritesThisTick, savedMasterVolume, savedPopupActive, savedDisplayMode =
		state, pendingMessages, timerPending, armed, mvolFlushReady,
		mvolFastWritesThisTick, masterVolume, popupActive, displayMode

	local originalShowMVPopup = show_master_volume_popup
	show_master_volume_popup = function() end

	local function encoder_frame(tickByte)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, EID_A, tickByte, 0xF7)
	end

	local function mvol_writes_in(bytes)
		local out = {}
		for _, m in ipairs(split_messages(bytes or {})) do
			if item_type_of(m) == IT_MASTER_VOLUME and func_of(m) == MVOL_WRITE then out[#out + 1] = m end
		end
		return out
	end

	local function mvol_backlog()
		local out = {}
		for i = 1, #pendingMessages do
			if pendingMessages[i].regionId == 'mvol' then out[#out + 1] = pendingMessages[i] end
		end
		return out
	end

	state = STATE_ACTIVE

	-- (a) A SLOW turn (delta magnitude below MVOL_FAST_DELTA_THRESHOLD) is never tagged .fast: exactly
	-- the pre-existing one-write-per-tick behaviour, unaffected by this change.
	pendingMessages = {}
	timerPending = false
	mvolFlushReady = true
	slFlushReady = true
	mvolFastWritesThisTick = 0
	masterVolume = 50
	local out = controller_midi_in(encoder_frame(0x41), 'LINK') -- delta +1
	check('a slow delta (+1) emits its write immediately when the tick grant is available',
		#mvol_writes_in(out and out.midi) == 1)
	check('...spending the base grant, not the fast-turn budget', mvolFastWritesThisTick == 0)

	out = controller_midi_in(encoder_frame(0x41), 'LINK') -- delta +1, tick grant already spent
	check('a second slow delta in the same tick window (grant spent, never tagged fast) does not flush',
		#mvol_writes_in(out and out.midi) == 0)
	check('...it stays queued rather than being dropped', #mvol_backlog() == 1)

	-- (b) A FAST turn (delta magnitude at/above the threshold) bypasses the exhausted base grant -
	-- proving the extra throughput comes from the fast-turn tag, not the ordinary tick grant, which
	-- stays spent (mvolFlushReady is never re-granted here - only controller_timer_trigger does that).
	pendingMessages = {}
	mvolFlushReady = false
	slFlushReady = true -- tick permit fresh; only the mvol grant is spent
	mvolFastWritesThisTick = 0
	masterVolume = 50
	out = controller_midi_in(encoder_frame(0x48), 'LINK') -- delta +8, fast
	local writes = mvol_writes_in(out and out.midi)
	check('a fast delta (+8) flushes its write even though the ordinary tick grant is already spent',
		#writes == 1)
	check('...carrying the fresh value (58), not a stale one', #writes == 1 and writes[1][10] == 58)
	check('...counted against the fast-turn budget', mvolFastWritesThisTick == 1)

	-- (c) The fast-turn budget is bounded at MVOL_FAST_WRITES_PER_TICK - 1 extra writes per tick
	-- window, not unbounded: a sustained fast sweep eventually stops flushing every tick and instead
	-- leaves a single coalesced backlog entry (still carrying the newest value, never dropped) until
	-- the budget resets - protecting the keepalive/Identification Query from an unbounded write burst.
	pendingMessages = {}
	mvolFlushReady = false
	slFlushReady = true -- tick permit fresh; only the mvol grant is spent
	mvolFastWritesThisTick = 0
	masterVolume = 50
	local flushedCount = 0
	local sweepTicks = MVOL_FAST_WRITES_PER_TICK + 5
	for _ = 1, sweepTicks do
		out = controller_midi_in(encoder_frame(0x48), 'LINK') -- delta +8, fast, every call
		flushedCount = flushedCount + #mvol_writes_in(out and out.midi)
	end
	check('a sustained fast sweep flushes exactly MVOL_FAST_WRITES_PER_TICK - 1 writes, then stops',
		flushedCount == MVOL_FAST_WRITES_PER_TICK - 1)
	check('...the budget is pinned at its cap, not left growing unbounded',
		mvolFastWritesThisTick == MVOL_FAST_WRITES_PER_TICK - 1)
	check('...and the remaining ticks left exactly one coalesced backlog entry, not a pile-up',
		#mvol_backlog() == 1)

	-- (d) The keepalive/Identification Query is never starved by fast-turn traffic: rearm_timer() ran
	-- on every one of the round-trips above (flush_pending's own reserved query-budget behaviour,
	-- section 54, is unrelated to and unaffected by this change) - confirmed by the session clock
	-- still being armed after the sweep.
	check('the session clock kept re-arming throughout the fast sweep (no keepalive starvation)',
		timerPending == true)

	-- (e) The budget is a PER-TICK-WINDOW allowance, not a permanent lockout: the next real timer tick
	-- resets it, and the backlog left over from (c) then drains via the ordinary base grant.
	mvolFlushReady = true -- mirrors controller_timer_trigger's own unconditional grant
	slFlushReady = true
	mvolFastWritesThisTick = 0 -- mirrors controller_timer_trigger's own reset
	out = controller_midi_in(encoder_frame(0x41), 'LINK') -- delta +1, arrives after the reset
	writes = mvol_writes_in(out and out.midi)
	check('once the next tick resets the budget, the coalesced backlog drains via the base grant',
		#writes == 1)

	show_master_volume_popup = originalShowMVPopup
	state, pendingMessages, timerPending, armed, mvolFlushReady, mvolFastWritesThisTick, masterVolume,
		popupActive, displayMode =
		savedState, savedPending, savedTimerPending, savedArmed, savedMvolFlushReady,
		savedMvolFastWritesThisTick, savedMasterVolume, savedPopupActive, savedDisplayMode
end

-- MARK: - 73. One queued SL message per tick, whatever its itemType (slFlushReady), and nothing is
-- ever dequeued without being emitted. flush_pending runs once per tick PLUS once per inbound SL
-- frame; before slFlushReady only IT_DISPLAY and MVOL_WRITE were bounded, so LED, MVOL_READ and
-- protocol messages could leave milliseconds apart within one tick and get dropped by the SL88 -
-- the bug the 3x repeat workaround was hiding. See
-- docs/config-lua-history.md#one-sl-message-per-tick-2026-09-17.
do
	local savedPending, savedDisplay, savedMvol, savedFast, savedSl =
		pendingMessages, displayFlushReady, mvolFlushReady, mvolFastWritesThisTick, slFlushReady

	local function queued_message_count(out)
		-- Everything the flush emitted EXCEPT the trailing Identification Query, which is appended
		-- rather than dequeued and is deliberately exempt from the permit.
		local n = 0
		for _, m in ipairs(split_messages(out and out.midi or {})) do
			if not (item_type_of(m) == IT_IDENTIFICATION and func_of(m) == ID_QUERY) then
				n = n + 1
			end
		end
		return n
	end

	-- (a) A mixed queue, one tick's permit: exactly one queued message leaves, and repeated flushes
	-- within the same tick emit nothing more.
	pendingMessages = {}
	displayFlushReady, mvolFlushReady, mvolFastWritesThisTick, slFlushReady = true, true, 0, true
	queue_message(msg_draw_rect(0, 0, 10, 10, 0, 0, 0), 'test:oneper-display')
	queue_message(msg_white_led(WLID_A_ENC, true))
	queue_message(msg_master_volume_mute_write(MVOL_IGNORE_VOL, true))
	queue_message(msg_master_volume_read())
	queue_message(msg_system(SYS_DEVICE_NOTIFICATION))
	local depthBefore = #pendingMessages

	local first = flush_pending(true)
	check('one-per-tick: the first flush of a tick emits exactly one queued message',
		queued_message_count(first) == 1)
	check('one-per-tick: ...and removes exactly one from the queue', #pendingMessages == depthBefore - 1)

	-- The inbound-frame flushes that follow in the same tick are where the dropped one-shots used to
	-- escape - they must now carry the query alone.
	local emittedRest = 0
	for _ = 1, 4 do
		emittedRest = emittedRest + queued_message_count(flush_pending(true))
	end
	check('one-per-tick: later flushes in the SAME tick emit no further queued messages',
		emittedRest == 0)
	check('one-per-tick: ...and leave the queue untouched', #pendingMessages == depthBefore - 1)

	-- (b) Each fresh tick releases exactly one more, until the queue is empty.
	local drained, ticks = 1, 0
	while #pendingMessages > 0 and ticks < 50 do
		displayFlushReady, mvolFlushReady, mvolFastWritesThisTick, slFlushReady = true, true, 0, true
		local n = queued_message_count(flush_pending(true))
		check('one-per-tick: tick ' .. (ticks + 1) .. ' of the drain emits exactly one message', n == 1)
		drained = drained + n
		ticks = ticks + 1
	end
	check('one-per-tick: the whole mixed queue drains, one message per tick', drained == depthBefore)

	-- (c) Nothing is dequeued without reaching the wire. Sections 3 and 8 drain the queue but discard
	-- flush_pending's return value, so they prove the queue empties without proving anything was
	-- emitted - this is the assertion that tells those two apart.
	pendingMessages = {}
	displayFlushReady, mvolFlushReady, mvolFastWritesThisTick, slFlushReady = true, true, 0, true
	queue_message(msg_white_led(WLID_A_ENC, false))
	queue_message(msg_master_volume_read())
	queue_message(msg_draw_rect(0, 0, 8, 8, 0, 0, 0), 'test:oneper-ledger')
	local ledgerDepth = #pendingMessages
	local emittedBytes, removed = {}, 0
	for _ = 1, ledgerDepth do
		displayFlushReady, mvolFlushReady, mvolFastWritesThisTick, slFlushReady = true, true, 0, true
		local before = #pendingMessages
		local out = flush_pending(true)
		removed = removed + (before - #pendingMessages)
		for _, m in ipairs(split_messages(out and out.midi or {})) do
			if not (item_type_of(m) == IT_IDENTIFICATION and func_of(m) == ID_QUERY) then
				emittedBytes[#emittedBytes + 1] = hex(m)
			end
		end
	end
	check('no silent drops: every message removed from the queue appears in a flush',
		removed == ledgerDepth and #emittedBytes == ledgerDepth)
	-- Membership, not position: which index a message lands on depends on queue order, so an
	-- index-coupled check can fail with a label naming the wrong message.
	local function was_emitted(msg)
		for _, h in ipairs(emittedBytes) do
			if h == hex(msg) then return true end
		end
		return false
	end
	check('no silent drops: the LED write reached the wire',
		was_emitted(msg_white_led(WLID_A_ENC, false)))
	check('no silent drops: the Master Volume READ reached the wire',
		was_emitted(msg_master_volume_read()))

	-- (d) MVOL_READ is paced by the shared permit even though mvolFlushReady never gates it. This is
	-- the settle read-back that produced zero replies on hardware.
	pendingMessages = {}
	slFlushReady = false
	mvolFlushReady = true
	queue_message(msg_master_volume_read())
	check('one-per-tick: an MVOL_READ is blocked once the tick permit is spent',
		queued_message_count(flush_pending(true)) == 0 and #pendingMessages == 1)

	-- (e) An LED write is paced too - it was never gated by anything before.
	pendingMessages = {}
	slFlushReady = false
	queue_message(msg_white_led(WLID_A_ENC, true))
	check('one-per-tick: an LED write is blocked once the tick permit is spent',
		queued_message_count(flush_pending(true)) == 0 and #pendingMessages == 1)

	-- (f) The fast-turn bypass is the documented exception: it still gets through with the permit
	-- spent, so a fast sweep keeps its feel.
	pendingMessages = {}
	slFlushReady = false
	mvolFlushReady = false
	mvolFastWritesThisTick = 0
	local fast = msg_master_volume_write(42)
	fast.fast = true
	queue_message(fast)
	check('one-per-tick: a .fast Master Volume write still bypasses the spent permit',
		queued_message_count(flush_pending(true)) == 1)

	pendingMessages, displayFlushReady, mvolFlushReady, mvolFastWritesThisTick, slFlushReady =
		savedPending, savedDisplay, savedMvol, savedFast, savedSl
end

-- MARK: - 74. The popup value never coalesces ahead of the knob redraw it belongs behind
--
-- BUG (docs/config-lua-history.md#popup-value-wiped-by-its-own-ring-redraw-2026-09-17):
-- queue_message coalesces a same-regionId update at its OLD queue position (see that function's own
-- comment). A value-only paint can queue popupValue first; before it drains, a later paint that
-- changes the knob's icon appends popupKnob at the TAIL, and the paired queue_popup_value() call
-- then coalesces the value back into its stale, earlier position - ahead of its own knob. A
-- hardware capture caught the worst case: 'FLUSH #116 ... regionId=popupValue' then
-- 'FLUSH #119 ... regionId=popupKnob' with nothing after it - the knob's redraw wiped the value and
-- nothing repainted it. Fixed by draw_popup_knob dropping any pending popupValue entry (see
-- drop_queued_region) whenever its own bitmap redraw actually queues, forcing the paired
-- queue_popup_value() call to append fresh rather than coalesce stale.
do
	local savedDrawn, savedPending, savedTicks, savedLastPaint, savedDirty, savedValue, savedMax,
		savedDisplay, savedSl =
		drawn, pendingMessages, timerTicks, popupValueLastPaintTick, popupValueDirty,
		popupValue, popupMax, displayFlushReady, slFlushReady

	popupMax = 127

	local function non_query_messages(out)
		local msgs = {}
		for _, m in ipairs(split_messages(out and out.midi or {})) do
			if not (item_type_of(m) == IT_IDENTIFICATION and func_of(m) == ID_QUERY) then
				msgs[#msgs + 1] = m
			end
		end
		return msgs
	end

	-- Baseline: an ordinary paint at icon 6 (floor(64*12/127)), simulated as already flushed to
	-- hardware - drawn[] retains both ids' tuples, the queue is empty.
	drawn, pendingMessages = {}, {}
	timerTicks = 5000
	popupValue = 64
	draw_popup_knob(popupValue, POPUP_KNOB_Y, true)
	queue_popup_value()
	pendingMessages = {}

	-- Decoys AHEAD of popupValue, mirroring paint_popup_screen's real layout - it queues the panel
	-- and border strips before ever reaching the knob, so popupValue is never the first entry on
	-- hardware. Without these the removal has only one candidate and a 'drop whatever is at the
	-- head' bug would pass this section unnoticed.
	draw_rect('popupBg', 1, 1, 10, 10, 0, 0, 0)
	draw_rect('popupBorderTop', 1, 1, 10, 2, 1, 1, 1)
	draw_rect('popupBorderBottom', 1, 20, 10, 2, 1, 1, 1)

	-- (a) THE REGRESSION SETUP: a value-only paint (still icon 6 - floor(70*12/127)) queues
	-- popupValue ALONE, past the throttle so it actually reaches the queue - behind the decoys.
	timerTicks = 5003
	popupValue = 70
	queue_popup_value()
	check('setup: the value-only change queues popupValue alone, behind the decoys',
		#pendingMessages == 4 and pendingMessages[4].regionId == 'popupValue')

	-- Before that drains, a paint changes the icon (120 -> icon 11) and queues popupKnob, paired
	-- with the same queue_popup_value() call paint_popup_screen always makes right after.
	popupValue = 120
	draw_popup_knob(popupValue, POPUP_KNOB_Y, true)
	queue_popup_value()
	check('THE REGRESSION: the icon-changing paint still leaves 5 messages queued',
		#pendingMessages == 5)
	if #pendingMessages == 5 then
		check('THE REGRESSION: popupKnob is queued before popupValue, not coalesced ahead of it',
			pendingMessages[4].regionId == 'popupKnob' and pendingMessages[5].regionId == 'popupValue')
		-- Proves the removal was TARGETED, not 'drop the head of the queue': every region ahead of
		-- popupValue must survive, in order.
		check('THE REGRESSION: dropping popupValue left the regions ahead of it untouched',
			pendingMessages[1].regionId == 'popupBg'
				and pendingMessages[2].regionId == 'popupBorderTop'
				and pendingMessages[3].regionId == 'popupBorderBottom')
	end

	-- Drop the decoys so the drain assertions below see only the knob/value pair.
	local pairOnly = {}
	for _, m in ipairs(pendingMessages) do
		if m.regionId == 'popupKnob' or m.regionId == 'popupValue' then pairOnly[#pairOnly + 1] = m end
	end
	pendingMessages = pairOnly

	-- (b) Draining with real flush ticks emits the knob on one tick and the value on a LATER tick -
	-- never reversed, never the knob alone with the value stranded behind it.
	displayFlushReady, slFlushReady = true, true
	local tick1 = non_query_messages(flush_pending(true))
	check('drain: tick 1 emits exactly one display message', #tick1 == 1)
	check('drain: tick 1 emits the knob (Plot Bitmap), not the value',
		#tick1 == 1 and func_of(tick1[1]) == DISP_PLOT_BITMAP)
	check('drain: tick 1 leaves only the value still queued',
		#pendingMessages == 1 and pendingMessages[1].regionId == 'popupValue')

	-- Fresh tick: displayFlushReady/slFlushReady reset, as controller_timer_trigger does every tick.
	displayFlushReady, slFlushReady = true, true
	local tick2 = non_query_messages(flush_pending(true))
	check('drain: tick 2 emits exactly one display message', #tick2 == 1)
	check('drain: tick 2 emits the value (Write Text) - the pair completes with no gap',
		#tick2 == 1 and func_of(tick2[1]) == DISP_WRITE_TEXT and write_text_body(tick2[1]) == '120')
	check('drain: both messages delivered - the queue is now empty', #pendingMessages == 0)

	-- (c) A value-only change (icon unchanged) must still be throttled as before - the fix must not
	-- defeat POPUP_VALUE_THROTTLE_TICKS for ordinary scrubbing within the same icon bucket.
	drawn, pendingMessages = {}, {}
	timerTicks = 6000
	popupValue = 1
	draw_popup_knob(1, POPUP_KNOB_Y, true) -- icon 0, first draw
	queue_popup_value() -- forced first paint; pins the paint tick at 6000
	pendingMessages = {}

	timerTicks = 6001 -- only 1 tick later - throttle window is 3
	popupValue = 2 -- icon 0 still - value-only change
	queue_popup_value()
	check('throttle: an ordinary value-only change within the window is withheld, not sent immediately',
		#pendingMessages == 0 and popupValueDirty == true)

	drawn, pendingMessages, timerTicks, popupValueLastPaintTick, popupValueDirty,
		popupValue, popupMax, displayFlushReady, slFlushReady =
		savedDrawn, savedPending, savedTicks, savedLastPaint, savedDirty,
		savedValue, savedMax, savedDisplay, savedSl
end

-- MARK: - 75. drop_queued_region() removes only the named region's entry, position preserved
do
	local savedPending = pendingMessages
	pendingMessages = {}

	queue_message({ 0xF0, 0x00 }, 'regionA')
	queue_message({ 0xF0, 0x01 }, 'regionB')
	queue_message({ 0xF0, 0x02 }, 'regionC')
	check('drop_queued_region setup: three regions queued', #pendingMessages == 3)

	drop_queued_region('regionB')
	check('drop_queued_region: exactly one entry removed', #pendingMessages == 2)
	check('drop_queued_region: the remaining two are regionA then regionC, order preserved',
		pendingMessages[1].regionId == 'regionA' and pendingMessages[2].regionId == 'regionC')

	drop_queued_region('regionZ') -- not queued - must be a harmless no-op
	check('drop_queued_region: dropping an absent regionId changes nothing',
		#pendingMessages == 2 and pendingMessages[1].regionId == 'regionA'
		and pendingMessages[2].regionId == 'regionC')

	pendingMessages = savedPending
end

-- MARK: - 76. A stale Identification Request cannot survive approval, or restart the retry cycle
-- Hardware 2026-09-17: at one message per tick a deep startup queue still held retry Identification
-- Requests when approval landed. Each went out afterwards, drew a REJECTED (reason 00), and
-- re-triggered re-identification - the app dropped out of the APP list mid-session.
do
	local savedPending, savedState, savedRetries = pendingMessages, state, reidentifyRetriesLeft

	-- (a) Approval purges queued Identification Requests, and leaves everything else alone.
	pendingMessages = {}
	state = STATE_IDENTIFYING
	queue_message(msg_identification_request())
	queue_message({ 0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_DISPLAY, 0x01, 0xF7 })
	queue_message(msg_identification_request())
	check('stale request setup: two requests and one display message queued', #pendingMessages == 3)

	handle_identification_approved()
	check('THE REGRESSION: approval drops every queued Identification Request',
		#pendingMessages == 1)
	check('approval leaves non-identification traffic queued untouched',
		#pendingMessages == 1 and pendingMessages[1][8] == IT_DISPLAY)

	-- (b) A rejection arriving after approval is a stale echo and must NOT restart identification.
	state = STATE_ACTIVE
	reidentifyRetriesLeft = 2
	handle_identification_rejected(0x00)
	check('THE REGRESSION: a rejection while active is ignored, not acted on',
		state == STATE_ACTIVE)
	check('a rejection while active does not spend a retry',
		reidentifyRetriesLeft == 2)
	check('a rejection while active queues no new Identification Request',
		#pendingMessages == 1 and pendingMessages[1][8] == IT_DISPLAY)

	-- (c) But a rejection while still identifying is a REAL collision and must still be acted on.
	state = STATE_IDENTIFYING
	reidentifyRetriesLeft = 2
	handle_identification_rejected(0x00)
	check('a rejection while identifying still triggers the retry path',
		state == STATE_REIDENTIFY_WAIT and reidentifyRetriesLeft == 1)

	pendingMessages, state, reidentifyRetriesLeft = savedPending, savedState, savedRetries
end

-- MARK: - 77. controller_finalize releases a live registration, but never one it does not hold
-- Two earlier unconditional attempts were reverted for logging the app out during MainStage's
-- startup teardown churn. Hardware 2026-09-17 showed the two cases are separable: the churn
-- teardown fires at tick 0 in STATE_IDENTIFYING, a real quit from a registered state many ticks in.
do
	local savedPending, savedState, savedTicks = pendingMessages, state, timerTicks

	-- (a) The startup churn teardown: identifying, tick 0 - must send nothing.
	pendingMessages, state, timerTicks = {}, STATE_IDENTIFYING, 0
	check('THE REGRESSION: a teardown while still identifying sends no logout',
		controller_finalize() == nil)

	-- (b) Registered but still inside the churn window - must send nothing.
	pendingMessages, state, timerTicks = {}, STATE_ACTIVE, LOGOUT_ON_QUIT_MIN_TICKS - 1
	check('THE REGRESSION: a teardown before LOGOUT_ON_QUIT_MIN_TICKS sends no logout',
		controller_finalize() == nil)

	-- (c) A real quit: registered, well past the window - sends one Logout Request on SL_PORT.
	pendingMessages, state, timerTicks = {}, STATE_ACTIVE, 537
	local out = controller_finalize()
	check('a real quit returns a logout', out ~= nil and out.midi ~= nil)
	checkHex('a real quit returns exactly a System Logout Request',
		out and out.midi,
		hex(msg_system(SYS_LOGOUT_REQUEST)))
	check('a real quit sends it on SL_PORT', out ~= nil and out.outport == SL_PORT)

	-- (d) Every registered state releases, not just active.
	for _, st in ipairs({ STATE_LISTED, STATE_STANDBY }) do
		pendingMessages, state, timerTicks = {}, st, 537
		check('a quit from ' .. st .. ' also releases the registration',
			controller_finalize() ~= nil)
	end

	-- (e) Whatever it does or does not send, it always tears the queue and state down.
	pendingMessages, state, timerTicks = { { 0xF0 } }, STATE_ACTIVE, 537
	controller_finalize()
	check('finalize always clears the queue and drops to idle',
		#pendingMessages == 0 and state == STATE_IDLE)

	pendingMessages, state, timerTicks = savedPending, savedState, savedTicks
end

-- MARK: - 78. controller_midi_out: our CC only, nil on every path, reverse-lookup storage
--
-- See docs/config-lua-history.md#controller_midi_out-reports-real-parameter-values-with-a-screen-
-- control-2026-09-17. controller_midi_out must return nil unconditionally (our own outbound SysEx
-- passes through this same callback - a non-nil return would alter or swallow it), and must only
-- ever store feedback for a CC on CC_STATUS (our channel).
do
	local savedFeedback = midiOutFeedback
	midiOutFeedback = {}

	check('controller_midi_out returns nil for a nil midiEvent', controller_midi_out(nil, 'x', 'y', nil) == nil)

	-- Our own outbound SysEx passes through this callback with metadata nil - must return nil, must
	-- not touch midiOutFeedback.
	local sysex = frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_DISPLAY, DISP_WRITE_TEXT)
	check('controller_midi_out returns nil for our own outbound SysEx (F0)', controller_midi_out(sysex, nil, nil, nil) == nil)

	local cc = CC_MAP['ENC1_TURN']
	check('controller_midi_out returns nil for a reported CC on our channel',
		controller_midi_out(frame(CC_STATUS, cc, 90), 'Volume', '+0,0 dB', { r = 1, g = 0.9, b = 0.31 }) == nil)
	check('...and stores the reported name/valueString/absolute value (midiEvent[2])',
		midiOutFeedback[cc] ~= nil and midiOutFeedback[cc].name == 'Volume'
			and midiOutFeedback[cc].valueString == '+0,0 dB' and midiOutFeedback[cc].value == 90)

	-- THE REGRESSION this guards: an unhandled status byte (any channel but ours) must be ignored
	-- entirely, not overwrite an existing entry for the same CC number.
	check('controller_midi_out returns nil for an unhandled status byte',
		controller_midi_out(frame(CC_STATUS - 1, cc, 64), 'Whatever', '64', nil) == nil)
	check('...and leaves the existing feedback for that CC untouched',
		midiOutFeedback[cc] ~= nil and midiOutFeedback[cc].value == 90)

	-- A CC not in CC_MAP (64 is deliberately skipped - see CC_MAP's own comment) has no reverse-lookup
	-- entry and must be ignored, not stored under a bogus key.
	check('controller_midi_out returns nil for a CC outside CC_MAP',
		controller_midi_out(frame(CC_STATUS, 64, 10), 'Sustain', '10', nil) == nil)
	check('...and stores nothing for it', midiOutFeedback[64] == nil)

	-- nil name and the literal 'Unmapped' string both mean 'no feedback' - MainStage sends 'Unmapped'
	-- for a control with no screen control assigned (see Native Instruments/KOMPLETE KONTROL
	-- S61.device/config.lua:173 in the 4.3.1 bundle). Either must clear an existing entry.
	midiOutFeedback[cc] = { name = 'Volume', valueString = '+0,0 dB', value = 90 }
	controller_midi_out(frame(CC_STATUS, cc, 90), nil, nil, nil)
	check('a nil name clears any existing feedback for that CC', midiOutFeedback[cc] == nil)

	midiOutFeedback[cc] = { name = 'Volume', valueString = '+0,0 dB', value = 90 }
	controller_midi_out(frame(CC_STATUS, cc, 90), 'Unmapped', '', nil)
	check("the literal name 'Unmapped' clears any existing feedback for that CC", midiOutFeedback[cc] == nil)

	-- Cache: an unchanged tuple (name/valueString/value all identical) must skip the store - proven by
	-- reference identity, not just equal fields, so a mutation that always reassigns cannot pass this.
	local cc2 = CC_MAP['ENC2_TURN']
	midiOutFeedback[cc2] = nil
	controller_midi_out(frame(CC_STATUS, cc2, 50), 'Pan', '0', nil)
	local firstRef = midiOutFeedback[cc2]
	controller_midi_out(frame(CC_STATUS, cc2, 50), 'Pan', '0', nil) -- identical tuple, thousands of these observed on hardware
	check('an unchanged tuple skips the store (same table reference, not reassigned)',
		midiOutFeedback[cc2] == firstRef)
	controller_midi_out(frame(CC_STATUS, cc2, 51), 'Pan', '0', nil) -- value actually changed
	check('a changed value DOES reassign the store',
		midiOutFeedback[cc2] ~= firstRef and midiOutFeedback[cc2].value == 51)

	midiOutFeedback = savedFeedback
end

-- MARK: - 79. sanitize_value_string: known units substituted, other non-ASCII dropped not spaced
--
-- valueString is locale-formatted and can contain non-ASCII - a hardware capture showed '+0,0 ㏈',
-- where ㏈ (U+33C8, 3 UTF-8 bytes E3 8F 88) would render as three blanks under append_text's own
-- per-byte clamp. sanitize_value_string substitutes known units and drops anything else outside
-- 0x20-0x80, rather than letting append_text turn it into a run of spaces.
do
	check("sanitize_value_string substitutes U+33C8 (dB) with 'dB'",
		sanitize_value_string('+0,0 \xE3\x8F\x88') == '+0,0 dB')
	check('sanitize_value_string DROPS a stray non-ASCII byte rather than replacing it with a space',
		sanitize_value_string('A\xC3\xA9B') == 'AB') -- Ã© (2 UTF-8 bytes, no substitution rule) - dropped, not spaced
	check('sanitize_value_string is nil-safe', sanitize_value_string(nil) == nil)
	check('sanitize_value_string leaves plain ASCII untouched',
		sanitize_value_string('Hello, World! 123') == 'Hello, World! 123')
end

-- MARK: - 80. Popup two-mode geometry: feedback content/layout vs legacy, and a mode switch re-erases
--
-- See the layout table in docs/config-lua-history.md#controller_midi_out-reports-real-parameter-
-- values-with-a-screen-control-2026-09-17. FEEDBACK mode paints popupTitle/popupKnob/popupValue at
-- the FB y-coordinates with MainStage's own name/valueString; LEGACY mode is untouched (sections
-- 19/20/59/60/74 already cover its byte shapes). A mode switch mid-session must re-erase, since the
-- two modes place popupValue at different y positions and memoization never clears a vacated one.
do
	local savedDrawn, savedPending, savedEid, savedFeedbackActive, savedFeedbackName, savedValueString,
		savedValue, savedControlName, savedCcNumber, savedModeIsFeedback, savedActive, savedFeedback =
		drawn, pendingMessages, popupEid, popupFeedbackActive, popupFeedbackName, popupValueString,
		popupValue, popupControlName, popupCcNumber, popupModeIsFeedback, popupActive, midiOutFeedback

	midiOutFeedback = {}

	-- (a) FEEDBACK mode content: title carries MainStage's reported name, value carries its
	-- valueString (not the raw number) at the FB position, not the legacy in-ring position.
	drawn, pendingMessages = {}, {}
	popupEid = EID_ZONE1
	popupFeedbackActive = true
	popupFeedbackName = 'Volume'
	popupValueString = '+0,0 dB'
	popupValue = 90
	paint_popup_screen()
	check('feedback mode (no mute mapping) queues bg + 4 border strips + title + knob + value = 8 messages',
		#pendingMessages == 8)
	local byRegion = {}
	for i = 1, #pendingMessages do byRegion[pendingMessages[i].regionId] = pendingMessages[i] end
	check('...popupTitle carries the reported name, not the physical encoder label',
		byRegion['popupTitle'] ~= nil and write_text_body(byRegion['popupTitle']) == 'Volume')
	check('...popupValue carries the reported valueString, not the raw number',
		byRegion['popupValue'] ~= nil and write_text_body(byRegion['popupValue']) == '+0,0 dB')

	-- (b) LEGACY mode is unchanged: popupLabel names the physical encoder + CC, popupValue is the raw
	-- number - same 8-message shape sections 19/20 already pin, reached here via the SAME dispatcher
	-- (paint_popup_screen) rather than calling paint_popup_legacy() directly, so this also proves the
	-- popupFeedbackActive branch itself, not just paint_popup_legacy() in isolation.
	drawn, pendingMessages = {}, {}
	popupFeedbackActive = false
	popupControlName = ENCODER_NAME[EID_ZONE1]
	popupCcNumber = CC_MAP[ENCODER_CC[EID_ZONE1]]
	popupValue = 90
	paint_popup_screen()
	check('legacy mode (dispatched via paint_popup_screen) queues the same 8-message shape',
		#pendingMessages == 8)
	byRegion = {}
	for i = 1, #pendingMessages do byRegion[pendingMessages[i].regionId] = pendingMessages[i] end
	check('...popupLabel names the physical encoder and CC, not a MainStage parameter name',
		byRegion['popupLabel'] ~= nil and write_text_body(byRegion['popupLabel']):find('ENC 1', 1, true) ~= nil)
	check('...popupValue is the raw number, not a formatted string',
		byRegion['popupValue'] ~= nil and write_text_body(byRegion['popupValue']) == '90')

	-- (c) A mode switch mid-session (show_popup called again while popupActive, for a DIFFERENT
	-- control whose feedback status differs) must re-erase the whole panel first - proven by the
	-- erase being the first message queued, exactly like a fresh popup entry (section 53).
	local ccWithFeedback = CC_MAP['ENC1_TURN']
	midiOutFeedback[ccWithFeedback] = { name = 'Volume', valueString = '+0,0 dB', value = 90 }
	drawn, pendingMessages = {}, {}
	popupActive = true
	popupModeIsFeedback = false -- as if a legacy popup was showing just before this call
	show_popup(EID_ZONE1) -- now has feedback - mode switches false -> true
	check('a mode switch re-erases: the erase is the FIRST message queued',
		#pendingMessages >= 1 and pendingMessages[1].regionId == 'popupErase')
	check('...and popupModeIsFeedback now tracks the new mode', popupModeIsFeedback == true)

	-- (d) The converse switch (feedback -> legacy) also re-erases.
	midiOutFeedback[ccWithFeedback] = nil
	drawn, pendingMessages = {}, {}
	popupActive = true
	popupModeIsFeedback = true -- as if a feedback popup was showing just before this call
	show_popup(EID_ZONE1) -- no feedback now - mode switches true -> false
	check('the converse switch (feedback -> legacy) also re-erases',
		#pendingMessages >= 1 and pendingMessages[1].regionId == 'popupErase')
	check('...and popupModeIsFeedback tracks the switch back', popupModeIsFeedback == false)

	-- (e) Two calls that DON'T change mode must NOT re-erase (this is what section 53's ordinary
	-- repeat-call path already relies on) - proven here specifically for the mode-switch check itself,
	-- not just the general per-region memoization it sits alongside.
	drawn, pendingMessages = {}, {}
	popupActive = true
	popupModeIsFeedback = false
	show_popup(EID_ZONE1) -- still no feedback - mode unchanged
	check('no mode change means no re-erase',
		#pendingMessages == 0 or pendingMessages[1].regionId ~= 'popupErase')

	drawn, pendingMessages, popupEid, popupFeedbackActive, popupFeedbackName, popupValueString,
		popupValue, popupControlName, popupCcNumber, popupModeIsFeedback, popupActive, midiOutFeedback =
		savedDrawn, savedPending, savedEid, savedFeedbackActive, savedFeedbackName, savedValueString,
		savedValue, savedControlName, savedCcNumber, savedModeIsFeedback, savedActive, savedFeedback
end

-- MARK: - 81. Mute indicator: hint/LED only when the paired push button's name contains 'Mute',
-- lit = unmuted
--
-- Only A and B encoders have a ring LED (WLID_A_ENC/WLID_B_ENC); Zone 1-4 and the joystick show the
-- hint text only. The paired button is each encoder's OWN push (BID_ZONE*_ENC/BID_B_ENC/
-- BID_JOY_MAIN, not the SEL buttons) - see ENCODER_MUTE_BUTTON.
do
	local savedDrawn, savedPending, savedEid, savedFeedbackActive, savedFeedbackName, savedValueString,
		savedValue, savedFeedback, savedLedSent =
		drawn, pendingMessages, popupEid, popupFeedbackActive, popupFeedbackName, popupValueString,
		popupValue, midiOutFeedback, encoderMuteLedSent

	midiOutFeedback = {}
	encoderMuteLedSent = {}

	local function set_up_feedback_popup(eid)
		drawn, pendingMessages = {}, {}
		popupEid = eid
		popupFeedbackActive = true
		popupFeedbackName = 'Volume'
		popupValueString = '+0,0 dB'
		popupValue = 90
	end

	-- (a) A paired button with an UNRELATED name: no hint, no LED.
	local zone1Cc = CC_MAP['ENC1_PRESS_SHORT']
	midiOutFeedback[zone1Cc] = { name = 'Bypass', valueString = 'Off', value = 0 }
	set_up_feedback_popup(EID_ZONE1)
	paint_popup_screen()
	check('an unrelated paired-button name shows no mute hint', drawn['popupMuteHint'] == nil)

	-- (b) The paired button's name contains 'Mute' (case-insensitive): hint shown. Zone 1 has no ring
	-- LED, so no White LED message either.
	midiOutFeedback[zone1Cc] = { name = 'Zone 1 MUTE', valueString = 'Off', value = 0 }
	set_up_feedback_popup(EID_ZONE1)
	paint_popup_screen()
	local hintMsg
	for _, m in ipairs(pendingMessages) do if m.regionId == 'popupMuteHint' then hintMsg = m end end
	check("a paired-button name containing 'Mute' (any case) shows the hint, carrying the PUSH TO MUTE/UNMUTE text",
		hintMsg ~= nil and write_text_body(hintMsg):find('MUTE', 1, true) ~= nil)
	local savedStateS81 = state
	state = STATE_ACTIVE -- flush_mute_leds is ACTIVE-only; see its own guard
	flush_mute_leds()
	-- Zone 1 has no ring LED at all, so no White LED message may target one. B's ring is separately
	-- dark-asserted every session, so the check is 'nothing addressed to a Zone ring', not 'no LED'.
	local zoneLed = false
	check('ENCODER_MUTE_WLID has no entry for Zone 1', ENCODER_MUTE_WLID[EID_ZONE1] == nil)
	for _, m in ipairs(pendingMessages) do
		if item_type_of(m) == IT_LED and m[9] ~= WLID_B_ENC then zoneLed = true end
	end
	check('Zone 1 has no ring LED - no White LED message targets one', zoneLed == false)

	-- (c) B DOES have a ring LED (WLID_B_ENC): paired button unmuted (value 0) -> hint shown AND the
	-- LED is lit (state=1), matching the A ring's existing 'lit = unmuted' convention.
	local bCc = CC_MAP['ENCB_PRESS_SHORT']
	midiOutFeedback[bCc] = { name = 'Master Mute', valueString = 'Off', value = 0 }
	set_up_feedback_popup(EID_B)
	flush_mute_leds() -- the LED is driven by the tick drain, NOT by the popup paint
	local bLed
	for _, m in ipairs(pendingMessages) do if item_type_of(m) == IT_LED then bLed = m end end
	check('B ring LED is queued when a mute mapping exists', bLed ~= nil and bLed[9] == WLID_B_ENC)
	check('unmuted (paired value 0) lights the LED (state=1)', bLed ~= nil and bLed[10] == 1)

	-- (d) The paired button reports MUTED (nonzero value): hint stays shown, LED goes OFF (state=0).
	encoderMuteLedSent = {} -- clear the cache so the state change is actually re-sent
	midiOutFeedback[bCc] = { name = 'Master Mute', valueString = 'On', value = 127 }
	set_up_feedback_popup(EID_B)
	flush_mute_leds()
	bLed = nil
	for _, m in ipairs(pendingMessages) do if item_type_of(m) == IT_LED then bLed = m end end
	check('muted (paired value nonzero) turns the LED off (state=0)', bLed ~= nil and bLed[10] == 0)

	-- (e) The LED write is only queued on an actual state change, not on every tick -
	-- encoderMuteLedSent caches the last state sent per WLID.
	pendingMessages = {}
	flush_mute_leds() -- same muted state as (d), nothing changed
	bLed = nil
	for _, m in ipairs(pendingMessages) do if item_type_of(m) == IT_LED then bLed = m end end
	check('an unchanged mute state does not re-queue the White LED message', bLed == nil)

	-- (f) THE REGRESSION: the mute is pressed on the paired push button, which neither opens nor
	-- repaints the popup - and the popup dismisses after ~2s regardless. So the LED must follow the
	-- feedback with NO popup involvement at all.
	encoderMuteLedSent, pendingMessages = {}, {}
	popupActive, popupEid, popupFeedbackActive = false, nil, false
	midiOutFeedback[bCc] = { name = 'Master Mute', valueString = 'Off', value = 0 }
	flush_mute_leds()
	bLed = nil
	for _, m in ipairs(pendingMessages) do if item_type_of(m) == IT_LED then bLed = m end end
	check('THE REGRESSION: the mute LED tracks feedback with no popup open and nothing painted',
		bLed ~= nil and bLed[9] == WLID_B_ENC and bLed[10] == 1)
	check('THE REGRESSION: it queues the LED and nothing else', #pendingMessages == 1)

	-- (g) And prove the TICK is what drives it - (f) calls flush_mute_leds() directly, which would
	-- still pass if controller_timer_trigger stopped calling it at all.
	local savedTimerPending, savedFrames = timerPending, framesSinceTick
	encoderMuteLedSent, pendingMessages = {}, {}
	midiOutFeedback[bCc] = { name = 'Master Mute', valueString = 'On', value = 127 }
	state, timerPending = STATE_ACTIVE, true
	local tickOut = controller_timer_trigger()
	-- The tick flushes as it returns, so the LED may be in the returned midi OR still queued behind
	-- the one-message-per-tick permit - either proves the drain ran.
	bLed = nil
	for _, m in ipairs(pendingMessages) do
		if item_type_of(m) == IT_LED and m[9] == WLID_B_ENC then bLed = m end
	end
	if bLed == nil and tickOut ~= nil and tickOut.midi ~= nil then
		for _, m in ipairs(split_messages(tickOut.midi)) do
			if item_type_of(m) == IT_LED and m[9] == WLID_B_ENC then bLed = m end
		end
	end
	check('THE REGRESSION: controller_timer_trigger itself drains the mute LEDs',
		bLed ~= nil and bLed[9] == WLID_B_ENC and bLed[10] == 0)
	-- (h) No mute mapping at all: the ring must be driven DARK, not skipped. Skipping left a lamp
	-- lit from a previous concert or session.
	encoderMuteLedSent, pendingMessages = {}, {}
	midiOutFeedback[bCc] = nil -- no mute feedback for B any more
	flush_mute_leds()
	bLed = nil
	for _, m in ipairs(pendingMessages) do if item_type_of(m) == IT_LED then bLed = m end end
	check('THE REGRESSION: with no mute mapping the ring is driven dark, not left alone',
		bLed ~= nil and bLed[9] == WLID_B_ENC and bLed[10] == 0)

    -- (i1) THE REGRESSION: a ring set BEFORE login confirmation is discarded by the SL88, so login
    -- must forget what was sent and re-assert. enter_active_session's own clear does not run on the
    -- already-ACTIVE path, which is the normal one.
    state = STATE_ACTIVE
    encoderMuteLedSent = { [WLID_B_ENC] = false }
    handle_login()
    check('THE REGRESSION: login clears the mute LED memo so the rings re-assert',
        next(encoderMuteLedSent) == nil)

	-- (i2) THE REGRESSION: a concert change must drop stored feedback. MainStage never announces that
	-- a control it used to report is gone, so a mute mapping from the old concert kept its ring lit.
	midiOutFeedback[bCc] = { name = 'Master Mute', valueString = 'Off', value = 0 }
	currentConcert, patchName, setName = 'Old Concert', 'p', 's'
	controller_select_patch(0, 'p2', 's2', 'New Concert', { { IsPatch = true, Label = 'p2',
		SetIndex = 0, PatchIndex = 0 } }, 0, 0)
	check('THE REGRESSION: a concert change drops stored parameter feedback',
		midiOutFeedback[bCc] == nil)

	-- Same patch list, same concert: feedback must SURVIVE, or every patch change would blank the
	-- popup until MainStage happened to re-report.
	midiOutFeedback[bCc] = { name = 'Master Mute', valueString = 'Off', value = 0 }
	controller_select_patch(0, 'p3', 's2', 'New Concert', { { IsPatch = true, Label = 'p3',
		SetIndex = 0, PatchIndex = 1 } }, 0, 1)
	check('a patch change within the same concert keeps stored feedback',
		midiOutFeedback[bCc] ~= nil)

	-- (i) A fresh session must forget what was last sent, so the rings are re-established rather
	-- than trusting a memo from before the SL88 confirmed us.
	encoderMuteLedSent = { [WLID_B_ENC] = true }
	state = STATE_LISTED
	enter_active_session()
	check('entering an active session clears the mute LED memo',
		next(encoderMuteLedSent) == nil)

	timerPending, framesSinceTick, state = savedTimerPending, savedFrames, savedStateS81

	drawn, pendingMessages, popupEid, popupFeedbackActive, popupFeedbackName, popupValueString,
		popupValue, midiOutFeedback, encoderMuteLedSent =
		savedDrawn, savedPending, savedEid, savedFeedbackActive, savedFeedbackName, savedValueString,
		savedValue, savedFeedback, savedLedSent
end

-- MARK: - 82. The HOME lamp mirrors the display mode
do
	local savedState, savedPending, savedMode, savedPopup, savedPrev, savedSent =
		state, pendingMessages, displayMode, popupActive, popupPreviousMode, homeLedSent

	local function homeLed()
		for _, m in ipairs(pendingMessages) do
			if item_type_of(m) == IT_LED and m[9] == WLID_HOME then return m end
		end
		return nil
	end

	state, popupActive = STATE_ACTIVE, false

	pendingMessages, homeLedSent, displayMode = {}, nil, 'list'
	flush_mode_led()
	local led = homeLed()
	check('list mode lights the HOME lamp', led ~= nil and led[10] == 1)

	pendingMessages, displayMode = {}, 'zoom'
	flush_mode_led()
	led = homeLed()
	check('zoom mode darkens the HOME lamp', led ~= nil and led[10] == 0)

	pendingMessages = {}
	flush_mode_led() -- unchanged
	check('an unchanged mode does not re-queue the HOME lamp', homeLed() == nil)

	-- A popup covers a mode rather than replacing it, so the lamp must follow what is underneath.
	pendingMessages, homeLedSent = {}, nil
	popupActive, popupPreviousMode, displayMode = true, 'list', 'popup'
	flush_mode_led()
	led = homeLed()
	check('a popup over the list keeps the HOME lamp lit', led ~= nil and led[10] == 1)

	-- ACTIVE-only, for the same reason as the mute rings: an LED queued during identification
	-- competes with the retry for the per-tick permit.
	pendingMessages, homeLedSent = {}, nil
	popupActive, displayMode, state = false, 'list', STATE_IDENTIFYING
	flush_mode_led()
	check('the HOME lamp is not written outside an active session', homeLed() == nil)

	-- And a ring set before login is discarded, so login must forget what was sent.
	state, homeLedSent = STATE_ACTIVE, true
	handle_login()
	check('login clears the HOME lamp memo so it re-asserts', homeLedSent == nil)

	state, pendingMessages, displayMode, popupActive, popupPreviousMode, homeLedSent =
		savedState, savedPending, savedMode, savedPopup, savedPrev, savedSent
end

-- MARK: - 83. Zoom-screen rows do not overlap at the MEASURED glyph heights
--
-- Per-region memoization requires non-overlapping regions (config.lua's SIX RULES, rule 4): if two
-- region ids can paint the same pixels, redrawing one leaves a stale layer from the other. The zoom
-- screen's five y coordinates were hand-calibrated by eye against glyph heights nobody had measured;
-- now that TEXT_H_* are real (docs/config-lua-history.md#write-text-box-heights-measured-2026-09-20)
-- the rule can actually be checked. y and size are decoded from the message's own bytes, like
-- align/maxWidth in test 21: y msb/lsb at 12/13, size at 17.
do
	local savedMode, savedDrawn, savedPending = displayMode, drawn, pendingMessages
	local savedPatch, savedSet, savedConcert = patchName, setName, currentConcert

	displayMode = 'zoom'
	patchName, setName, currentConcert =
		'A Reasonably Long Patch Name', 'A Reasonably Long Set Name', 'Test Concert'
	drawn = {}
	pendingMessages = {}

	paint_zoom_screen()

	local heightForSize = { [SIZE_SMALL] = TEXT_H_SMALL, [SIZE_MEDIUM] = TEXT_H_MEDIUM, [SIZE_BIG] = TEXT_H_BIG }
	local rows = {}
	for i = 1, #pendingMessages do
		local m = pendingMessages[i]
		rows[#rows + 1] = {
			id = m.regionId,
			y = m[12] * 128 + m[13],
			h = heightForSize[m[17]],
		}
	end
	table.sort(rows, function(a, b) return a.y < b.y end)

	local overlap, offScreen = nil, nil
	for i = 1, #rows do
		if rows[i].h == nil then overlap = rows[i].id .. ' (unknown size byte)' end
		if rows[i].y + (rows[i].h or 0) > SCREEN_HEIGHT then offScreen = rows[i].id end
		if i > 1 and rows[i - 1].y + (rows[i - 1].h or 0) > rows[i].y then
			overlap = rows[i - 1].id .. ' overlaps ' .. rows[i].id
		end
	end

	check('zoom screen rows: 5 decoded', #rows == 5)
	check('zoom screen rows do not overlap at the measured glyph heights (' .. tostring(overlap) .. ')',
		overlap == nil)
	check('zoom screen rows all fit above SCREEN_HEIGHT (' .. tostring(offScreen) .. ')', offScreen == nil)

	displayMode, drawn, pendingMessages = savedMode, savedDrawn, savedPending
	patchName, setName, currentConcert = savedPatch, savedSet, savedConcert
end

-- MARK: - 84. Config screen: row table coverage, scroll, the unmappable GLOBAL button, geometry
--
-- The config screen is the script's own UI, not a mappable control surface: GLOBAL toggles it and
-- the joystick ring scrolls it, and neither may reach MainStage as MIDI while it shows. See
-- docs/config-lua-history.md#the-config-screen-2026-09-20.
do
	local savedMode, savedScroll, savedPrev, savedPending, savedDrawn =
		displayMode, configScroll, configPreviousMode, pendingMessages, drawn
	local savedCC, savedDelta, savedOrder = pendingCC, pendingDelta, pendingCCOrder
	local savedState, savedPopup, savedLed = state, popupActive, globalLedSent

	-- CONFIG_ROWS is written out by hand, so the guard that makes that safe is coverage: every CC_MAP
	-- key exactly once, and nothing that is not a CC_MAP key.
	local seen, duplicate, unknown = {}, nil, nil
	for _, row in ipairs(CONFIG_ROWS) do
		for _, key in ipairs(row) do
			if CC_MAP[key] == nil then unknown = key end
			if seen[key] then duplicate = key end
			seen[key] = true
		end
	end
	local missing = nil
	for key in pairs(CC_MAP) do
		if not seen[key] then missing = key end
	end
	check('CONFIG_ROWS names only CC_MAP keys (' .. tostring(unknown) .. ')', unknown == nil)
	check('CONFIG_ROWS names no key twice (' .. tostring(duplicate) .. ')', duplicate == nil)
	check('CONFIG_ROWS covers every CC_MAP key (' .. tostring(missing) .. ')', missing == nil)

	-- 'Unmappable for MIDI' is exactly this: no BUTTON_CC entry, so no CC and no controller_info item.
	check('GLOBAL is absent from BUTTON_CC', BUTTON_CC[BID_GLOBAL] == nil)
	check('HOME is absent from BUTTON_CC', BUTTON_CC[BID_HOME] == nil)

	-- Scroll clamps at both ends; the last page is a full window, never a short one.
	displayMode = 'config'
	configScroll = 0
	check('scrolling back from the top does not move', scroll_config(-1) == false and configScroll == 0)
	scroll_config(1000)
	check('scrolling past the end stops at the last full page',
		configScroll == #CONFIG_ROWS - CONFIG_ROW_COUNT)
	check('scrolling on past the end does not move', scroll_config(3) == false)

	-- The ring scrolls and emits NOTHING while config shows.
	local function ring(delta)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, EID_JOYSTICK,
			0x40 + delta, 0xF7)
	end
	configScroll = 0
	pendingCC, pendingDelta, pendingCCOrder, pendingMessages = {}, {}, {}, {}
	handle_sl_frame(ring(2))
	check('the ring scrolls the config screen', configScroll == 2)
	check('the ring queues no CC while the config screen shows', #pendingCCOrder == 0)
	check('a config scroll repaints (the rows moved)', #pendingMessages > 0)

	-- ...and behaves exactly as before in every other mode.
	displayMode, configScroll = 'list', 0
	pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
	handle_sl_frame(ring(2))
	check('the ring emits no CC in list mode either - it selects patches instead',
		next(pendingDelta) == nil and next(pendingCC) == nil)
	check('the ring does not scroll the config screen from list mode', configScroll == 0)

	-- GLOBAL round-trips back to whichever mode it covered.
	local function settings(pressKind)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_BUTTON, BID_GLOBAL,
			pressKind, 0xF7)
	end
	-- popupActive is set explicitly, not inherited: handle_global_button reads popupPreviousMode
	-- instead of displayMode while a popup is up, so a leak from an earlier block would quietly change
	-- what this asserts rather than failing.
	for _, from in ipairs({ 'list', 'zoom' }) do
		displayMode, configPreviousMode, popupActive = from, nil, false
		pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
		handle_sl_frame(settings(PRESS_SHORT))
		check('GLOBAL from ' .. from .. ' enters config', displayMode == 'config')
		check('GLOBAL from ' .. from .. ' queues no CC', #pendingCCOrder == 0)
		handle_sl_frame(settings(PRESS_SHORT))
		check('GLOBAL returns to ' .. from, displayMode == from)
	end

	-- LONG is not dropped: same action as SHORT (see handle_global_button's comment).
	displayMode = 'list'
	handle_sl_frame(settings(PRESS_LONG))
	check('a LONG GLOBAL press also enters config', displayMode == 'config')

	-- HOME must not toggle out of config - it would lose configPreviousMode and land on 'zoom'.
	displayMode, configPreviousMode = 'config', 'list'
	handle_sl_frame(frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_BUTTON, BID_HOME,
		PRESS_SHORT, 0xF7))
	check('a HOME SHORT press is ignored while the config screen shows', displayMode == 'config')

	-- The GLOBAL lamp is the 'you are in config' indicator, same memo discipline as the HOME lamp.
	local function globalLed()
		for _, m in ipairs(pendingMessages) do
			if item_type_of(m) == IT_LED and m[9] == WLID_GLOBAL then return m end
		end
		return nil
	end
	state, popupActive, displayMode = STATE_ACTIVE, false, 'config'
	pendingMessages, globalLedSent = {}, nil
	flush_mode_led()
	local led = globalLed()
	check('config mode lights the GLOBAL lamp', led ~= nil and led[10] == 1)
	pendingMessages, displayMode = {}, 'list'
	flush_mode_led()
	led = globalLed()
	check('leaving config darkens the GLOBAL lamp', led ~= nil and led[10] == 0)
	pendingMessages = {}
	flush_mode_led()
	check('an unchanged mode does not re-queue the GLOBAL lamp', globalLed() == nil)
	pendingMessages, globalLedSent, state, displayMode = {}, nil, STATE_IDENTIFYING, 'config'
	flush_mode_led()
	check('the GLOBAL lamp is not written outside an active session', globalLed() == nil)
	state, globalLedSent = STATE_ACTIVE, true
	handle_login()
	check('login clears the GLOBAL lamp memo so it re-asserts', globalLedSent == nil)

	-- The HOME lamp must NOT move when the config screen opens over a mode - it tracks list-vs-zoom
	-- only, and config is an overlay on one of those (Jeroen, after the first hardware run).
	local function homeLedMsg()
		for _, m in ipairs(pendingMessages) do
			if item_type_of(m) == IT_LED and m[9] == WLID_HOME then return m end
		end
		return nil
	end
	state, popupActive = STATE_ACTIVE, false
	pendingMessages, homeLedSent, globalLedSent, displayMode = {}, nil, nil, 'list'
	flush_mode_led()
	check('the HOME lamp is lit in list mode', (homeLedMsg() or {})[10] == 1)
	pendingMessages, displayMode, configPreviousMode = {}, 'config', 'list'
	flush_mode_led()
	check('opening config over the list leaves the HOME lamp alone', homeLedMsg() == nil)
	pendingMessages, homeLedSent, displayMode, configPreviousMode = {}, nil, 'config', 'zoom'
	flush_mode_led()
	check('config over zoom keeps the HOME lamp dark', (homeLedMsg() or {})[10] == 0)

	-- No popup over the config screen: it would hide the page being read, and restoring it costs a
	-- full Clear-Screen repaint. The CC still goes out - only the panel is skipped.
	displayMode, popupActive = 'config', false
	pendingCC, pendingDelta, pendingCCOrder, pendingMessages = {}, {}, {}, {}
	handle_sl_frame(frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, EID_ZONE1,
		0x40 + 1, 0xF7))
	check('an encoder turn queues no popup while the config screen shows', popupActive == false)
	check('an encoder turn still emits its CC while the config screen shows',
		pendingDelta['ENC1_TURN'] == 1)
	show_master_volume_popup()
	check('the Master Volume popup is suppressed while the config screen shows', popupActive == false)

	-- Geometry: rows cannot overlap each other, the header above them, or the footer below - the
	-- per-region memoization rule, checked against the MEASURED glyph height.
	check('config rows clear the header rule', CONFIG_ROW_Y0 > CONFIG_RULE_Y)
	check('config row pitch clears a SIZE_SMALL box', CONFIG_ROW_PITCH >= TEXT_H_SMALL)
	-- The title is SIZE_MEDIUM (Jeroen's requirement), so it is the MEDIUM box that must clear the
	-- header - checking it against TEXT_H_SMALL would pass while the two actually overlapped.
	check('config title clears the header row', CONFIG_TITLE_Y + TEXT_H_MEDIUM <= CONFIG_HEADER_Y)
	check('config header clears the rule', CONFIG_HEADER_Y + TEXT_H_SMALL <= CONFIG_RULE_Y)
	check('the last config row clears the footer',
		CONFIG_ROW_Y0 + CONFIG_ROW_PITCH * (CONFIG_ROW_COUNT - 1) + TEXT_H_SMALL <= CONFIG_FOOTER_Y)
	check('the config footer fits on screen',
		CONFIG_FOOTER_Y + math.max(TEXT_H_SMALL, BMP_NAV_ICON_H) <= SCREEN_HEIGHT)
	check('the config name and CC columns do not overlap',
		CONFIG_NAME_X + CONFIG_NAME_W <= CONFIG_CC_X)
	check('the config footer icon and counter do not overlap',
		CONFIG_ICON_X + BMP_NAV_ICON_W <= CONFIG_COUNT_X)

	-- Every message the screen queues must fit the flush ceiling, or the whole array is dropped.
	drawn, pendingMessages, displayMode, configScroll = {}, {}, 'config', 0
	paint_config_screen()
	local oversize = nil
	for i = 1, #pendingMessages do
		if #pendingMessages[i] > FLUSH_BUDGET then oversize = i end
	end
	check('every message paint_config_screen queues fits within FLUSH_BUDGET', oversize == nil)
	-- title + version + 2 header cells + rule + icon + counter = 7, plus two draws per row.
	check('paint_config_screen draws the title, header, rule, rows, icon and counter',
		#pendingMessages == 7 + 2 * CONFIG_ROW_COUNT)

	-- A turn-only control keeps its number in the SHORT column rather than drifting right.
	check('a paired row shows both CCs', config_cc_text({ 'JOY_UP_SHORT', 'JOY_UP_LONG' }) == '40  41')
	check('a turn-only row pads the LONG column', config_cc_text({ 'ENC1_TURN' }) == '59   -')

	displayMode, configScroll, configPreviousMode, pendingMessages, drawn =
		savedMode, savedScroll, savedPrev, savedPending, savedDrawn
	pendingCC, pendingDelta, pendingCCOrder = savedCC, savedDelta, savedOrder
	state, popupActive, globalLedSent = savedState, savedPopup, savedLed
end

-- MARK: - 85. RGB encoder rings: wire shape, colour scaling, and what DARK means
--
-- The four zone encoder rings show the colour MainStage reports for whatever each knob is mapped to.
-- Two data sources that already existed: midiOutFeedback[cc].color (r/g/b FLOATS 0.0-1.0, confirmed on
-- hardware) and encoder_mute_state(eid), which reads the encoder's PUSH CC. DARK means muted OR nothing
-- mapped - the agreed trade-off. See docs/config-lua-history.md#rgb-encoder-rings-2026-09-20.
do
	local savedState, savedPending, savedFeedback, savedRings =
		state, pendingMessages, midiOutFeedback, encoderRingSent

	-- Golden vector: F0 00 20 1A 16 <host> <inst> 05 <LID> <R> <G> <B> <BR> F7, field order per the
	-- spec's RGB LED message. Byte-exact, so a reordered or dropped field fails here rather than on
	-- hardware.
	check('msg_rgb_led wire shape',
		hex(msg_rgb_led(0x02, 0x7F, 0x40, 0x00, 0x7F)) ==
			'F0 00 20 1A 16 03 ' .. id2() .. ' 05 02 7F 40 00 7F F7')

	-- MainStage's floats scale to 7-bit; they are NOT halved like the spec's 0-255 examples.
	check('rgb7 scales 1.0 to full', rgb7(1.0) == 127)
	check('rgb7 scales 0.0 to zero', rgb7(0.0) == 0)
	check('rgb7 scales a midpoint', rgb7(0.5) == 64)
	-- Out of range must clamp: a byte over 0x7F has its MSB set, which is illegal in MIDI data and
	-- drops the whole message.
	check('rgb7 clamps above 1.0', rgb7(1.9) == 127)
	check('rgb7 clamps below 0.0', rgb7(-0.5) == 0)
	check('rgb7 treats a missing channel as zero', rgb7(nil) == 0)

	local function ringFor(lid)
		for _, m in ipairs(pendingMessages) do
			if item_type_of(m) == IT_RGB_LED and m[9] == lid then return m end
		end
		return nil
	end
	local zone1Cc = CC_MAP[ENCODER_CC[EID_ZONE1]]
	local zone1Push = CC_MAP[BUTTON_CC[ENCODER_MUTE_BUTTON[EID_ZONE1]].short]
	local lid = ENCODER_RGB_LID[EID_ZONE1]

	-- A mapped, unmuted knob lights its ring in MainStage's colour.
	state, pendingMessages, encoderRingSent, midiOutFeedback = STATE_ACTIVE, {}, {}, {}
	midiOutFeedback[zone1Cc] = { name = 'Volume', color = { r = 1.0, g = 0.5, b = 0.0 } }
	flush_encoder_rings()
	local m = ringFor(lid)
	check('a mapped encoder lights its ring in MainStage colour',
		m ~= nil and m[10] == 127 and m[11] == 64 and m[12] == 0 and m[13] == RGB_BRIGHT)

	-- Unchanged state queues nothing.
	pendingMessages = {}
	flush_encoder_rings()
	check('an unchanged ring is not re-queued', ringFor(lid) == nil)

	-- Muted goes fully dark, colour included.
	pendingMessages = {}
	midiOutFeedback[zone1Push] = { name = 'Mute', value = 127 }
	flush_encoder_rings()
	m = ringFor(lid)
	check('a muted channel takes its ring dark',
		m ~= nil and m[10] == 0 and m[11] == 0 and m[12] == 0 and m[13] == 0)

	-- Unmuting restores the colour.
	pendingMessages = {}
	midiOutFeedback[zone1Push] = { name = 'Mute', value = 0 }
	flush_encoder_rings()
	m = ringFor(lid)
	check('unmuting restores the ring colour', m ~= nil and m[10] == 127 and m[13] == RGB_BRIGHT)

	-- No feedback at all must go DARK, not be left showing a previous concert's colour.
	pendingMessages, midiOutFeedback = {}, {}
	flush_encoder_rings()
	m = ringFor(lid)
	check('an encoder with no MainStage feedback goes dark',
		m ~= nil and m[10] == 0 and m[13] == 0)

	-- All four rings are addressed, each with its own LID.
	state, pendingMessages, encoderRingSent, midiOutFeedback = STATE_ACTIVE, {}, {}, {}
	flush_encoder_rings()
	local seen = {}
	for _, msg in ipairs(pendingMessages) do
		if item_type_of(msg) == IT_RGB_LED then seen[msg[9]] = true end
	end
	check('all four zone rings are addressed, one LID each',
		seen[0x00] and seen[0x01] and seen[0x02] and seen[0x03])

	-- ACTIVE-only, for the same reason as the mute rings.
	state, pendingMessages, encoderRingSent = STATE_IDENTIFYING, {}, {}
	flush_encoder_rings()
	check('rings are not written outside an active session', #pendingMessages == 0)

	-- And a ring set before login confirmation is discarded, so login must forget what was sent.
	state, encoderRingSent = STATE_ACTIVE, { [0x00] = { 1, 2, 3, 4 } }
	handle_login()
	check('login clears the ring memo so the rings re-assert', next(encoderRingSent) == nil)

	-- A COLOUR-ONLY change must still update the stored feedback. controller_midi_out returns early on an
	-- unchanged tuple, and a patch change can report the same parameter name and value in a different
	-- colour - leaving colour out of that comparison left the ring on the previous patch's colour with
	-- nothing in any log.
	state, pendingMessages, midiOutFeedback, encoderRingSent = STATE_ACTIVE, {}, {}, {}
	local function feedback(cc, name, value, color)
		local e = { [0] = CC_STATUS, [1] = cc, [2] = value }
		controller_midi_out(e, name, '0,0', color)
	end
	feedback(zone1Cc, 'Volume', 100, { r = 1.0, g = 0.0, b = 0.0 })
	flush_encoder_rings()
	pendingMessages = {}
	feedback(zone1Cc, 'Volume', 100, { r = 0.0, g = 0.0, b = 1.0 })
	flush_encoder_rings()
	m = ringFor(lid)
	check('a colour-only change still repaints the ring',
		m ~= nil and m[10] == 0 and m[12] == 127)

	-- ...and an identical report still costs nothing.
	pendingMessages = {}
	feedback(zone1Cc, 'Volume', 100, { r = 0.0, g = 0.0, b = 1.0 })
	flush_encoder_rings()
	check('an identical colour report does not re-queue the ring', ringFor(lid) == nil)

	-- A knob mapped to a VOLUME tracks its level in the ring's brightness; the fader coming down dims the
	-- ring and bottoms out dark. Anything else stays at full brightness.
	local white = { r = 1.0, g = 1.0, b = 1.0 }
	local function brightnessFor(name, value)
		state, pendingMessages, midiOutFeedback, encoderRingSent = STATE_ACTIVE, {}, {}, {}
		feedback(zone1Cc, name, value, white)
		flush_encoder_rings()
		local msg = ringFor(lid)
		return msg ~= nil and msg[13] or nil
	end
	check('a value at full lights the ring at full brightness', brightnessFor('Volume', 127) == 127)
	check('a value at half lights the ring at half brightness', brightnessFor('Volume', 64) == 64)
	check('a value at zero leaves the ring dark', brightnessFor('Volume', 0) == 0)
	-- Every ring tracks its value, whatever the mapping is called: the rule used to match names
	-- containing 'volume', which silently stopped dimming when a mapping was relabelled.
	check('a relabelled mapping still tracks its level', brightnessFor('Bari', 40) == 40)
	check('a mapping with no name at all still tracks its level', brightnessFor('Pan', 10) == 10)

	-- COALESCING: a fader sweep reports many values. Each ring carries its own regionId, so successive
	-- updates supersede in place instead of appending one LED message per value change ahead of display
	-- traffic and the keepalive.
	state, pendingMessages, midiOutFeedback, encoderRingSent = STATE_ACTIVE, {}, {}, {}
	feedback(zone1Cc, 'Volume', 30, white)
	flush_encoder_rings()
	feedback(zone1Cc, 'Volume', 60, white)
	flush_encoder_rings()
	feedback(zone1Cc, 'Volume', 90, white)
	flush_encoder_rings()
	local ringMsgs = 0
	for _, msg in ipairs(pendingMessages) do
		if item_type_of(msg) == IT_RGB_LED and msg[9] == lid then ringMsgs = ringMsgs + 1 end
	end
	check('a fader sweep leaves ONE queued update per ring, not one per value', ringMsgs == 1)
	check('...and the queued update carries the LATEST brightness', (ringFor(lid) or {})[13] == 90)

	state, pendingMessages, midiOutFeedback, encoderRingSent =
		savedState, savedPending, savedFeedback, savedRings
end

-- MARK: - 86. Popup name: shared position, bigger font, and the board's own term for the A encoder
--
-- Jeroen's requirements from the 2026-09-20 hardware run: the control's name goes ABOVE the ring in
-- BOTH popup modes (the legacy label used to sit below its ring, so the two disagreed), in the larger
-- font, and the A encoder's popup is titled AUDIO MASTER to match what the SL88's own board calls it.
-- SIZE_BIG is not an option here: Max Width truncation is broken at big size and the popup centres with
-- a real maxWidth, so a long name could render as a single letter.
do
	local savedDrawn, savedPending, savedName, savedCc, savedFeedback =
		drawn, pendingMessages, popupControlName, popupCcNumber, popupFeedbackActive

	-- y and size are decoded from the message's own bytes: y msb/lsb at 12/13, size at 17.
	local function drawnAt(regionId)
		for _, m in ipairs(pendingMessages) do
			if m.regionId == regionId then return m[12] * 128 + m[13], m[17] end
		end
		return nil, nil
	end

	drawn, pendingMessages = {}, {}
	draw_popup_title('Volume')
	local y, size = drawnAt('popupTitle')
	check('the feedback popup draws its name at the shared title y', y == POPUP_TITLE_Y)
	check('the feedback popup draws its name at SIZE_MEDIUM', size == SIZE_MEDIUM)

	drawn, pendingMessages = {}, {}
	draw_popup_label('AUDIO MASTER', nil)
	y, size = drawnAt('popupLabel')
	check('the legacy popup draws its name at the SAME title y', y == POPUP_TITLE_Y)
	check('the legacy popup name is SIZE_MEDIUM', size == SIZE_MEDIUM)

	-- Bands must not collide: name, then ring, then the legacy hint, all inside the panel.
	check('the popup name clears the ring', POPUP_TITLE_Y + TEXT_H_MEDIUM <= POPUP_KNOB_Y)
	check('the popup name sits inside the panel', POPUP_TITLE_Y >= POPUP_Y)
	check('the legacy mute hint sits below the ring',
		POPUP_HINT_Y >= POPUP_KNOB_Y + BMP_ICON_H)
	check('the legacy mute hint fits inside the panel',
		POPUP_HINT_Y + POPUP_MUTE_HINT_H <= POPUP_Y + POPUP_H)
	check('the feedback value clears the ring', POPUP_FB_VALUE_Y >= POPUP_KNOB_Y + BMP_ICON_H)
	check('the feedback hint clears the feedback value',
		POPUP_FB_HINT_Y >= POPUP_FB_VALUE_Y + TEXT_H_MEDIUM)

	-- The A encoder's popup carries the board's own name.
	popupFeedbackActive = false
	show_master_volume_popup()
	check('the A encoder popup is titled AUDIO MASTER', popupControlName == 'AUDIO MASTER')

	-- An EMPTY name from MainStage (observed on hardware for cc 59) is not a name: it would paint a blank
	-- title band. The entry survives so the ring keeps its colour, but the popup falls back to LEGACY.
	do
		local savedFb, savedMode, savedActive = midiOutFeedback, displayMode, popupActive
		midiOutFeedback, displayMode, popupActive = {}, 'list', false
		local zoneCc = CC_MAP[ENCODER_CC[EID_ZONE1]]
		local ev = { [0] = CC_STATUS, [1] = zoneCc, [2] = 91 }

		controller_midi_out(ev, '   ', '0,0', { r = 1.0, g = 0.5, b = 0.0 })
		local fb = midiOutFeedback[zoneCc]
		check('an empty reported name is stored as no name', fb ~= nil and fb.name == nil)
		check('...but the entry survives, so the ring keeps its colour',
			fb ~= nil and fb.color ~= nil and rgb7(fb.color.r) == 127)

		show_popup(EID_ZONE1)
		check('a nameless control falls back to the legacy popup title', popupFeedbackActive == false)
		check('...and that title names the physical encoder', popupControlName == ENCODER_NAME[EID_ZONE1])

		-- A real name still selects feedback mode.
		popupActive = false
		controller_midi_out(ev, 'Bass Vol', '0,0', { r = 1.0, g = 0.5, b = 0.0 })
		show_popup(EID_ZONE1)
		check('a real name still selects the feedback popup', popupFeedbackActive == true)
		check('...and shows MainStage name', popupFeedbackName == 'Bass Vol')

		midiOutFeedback, displayMode, popupActive = savedFb, savedMode, savedActive
	end

	drawn, pendingMessages, popupControlName, popupCcNumber, popupFeedbackActive =
		savedDrawn, savedPending, savedName, savedCc, savedFeedback
end

-- MARK: - 87. The ring selects patches: Bank Select + Program Change injection
--
-- Confirmed on hardware 2026-09-20 (MainStage 4.3.1): injecting a Bank Select pair followed by a Program
-- Change selects a patch EXACTLY - no scaling, no skipped patches - and banks lift the 128 ceiling. The
-- earlier absolute-CC approach is gone; see
-- docs/mainstage-integration.md#the-ring-selects-patches-with-bank-select-and-program-change.
do
	local savedRows, savedTarget, savedSet, savedPatch, savedMode =
		listRows, ringPatchTarget, activeSetIndex, activePatchIndex, displayMode
	local savedCC, savedDelta, savedOrder = pendingCC, pendingDelta, pendingCCOrder
	local savedProgram, savedBank = pendingProgram, pendingBank

	-- A concert with set headers interleaved: the ordinal counts patches, not rows.
	local function concert(patchCount)
		local rows = { { label = 'Set A', isPatch = false, setIndex = 0 } }
		for i = 1, patchCount do
			if i == 4 then rows[#rows + 1] = { label = 'Set B', isPatch = false, setIndex = 1 } end
			rows[#rows + 1] = { label = 'P' .. i, isPatch = true, setIndex = i < 4 and 0 or 1,
				patchIndex = i - 1 }
		end
		return rows
	end
	local function ring(delta)
		return frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, EID_JOYSTICK,
			0x40 + delta, 0xF7)
	end

	displayMode, listRows = 'list', concert(10)
	check('the concert patch count skips set headers', concert_patch_count() == 10)

	-- The target moves by the delta and the injection carries ITS bank and program.
	ringPatchTarget, pendingCC, pendingDelta, pendingCCOrder = 1, {}, {}, {}
	pendingProgram, pendingBank = nil, nil
	handle_sl_frame(ring(2))
	check('a ring turn moves the patch target', ringPatchTarget == 3)
	check('...and queues that patch as a program change', pendingProgram == 2)
	check('...in bank 0 for the first 128 patches', pendingBank == 0)

	-- The injected bytes: Bank MSB, Bank LSB, then the PC - the order Apple's guidance requires, since
	-- MainStage latches the bank and acts on the program change.
	local out = flush_pending_cc()
	local bytes = out ~= nil and out.midi or {}
	local tail = {}
	for i = math.max(1, #bytes - 7), #bytes do tail[#tail + 1] = bytes[i] end
	check('the injection ends with Bank MSB, Bank LSB, then Program Change',
		hex(tail) == string.format('%02X 00 00 %02X 20 00 %02X 02',
			0xB0 + CC_CHANNEL, 0xB0 + CC_CHANNEL, 0xC0 + CC_CHANNEL))
	check('the pending program is consumed by the flush', pendingProgram == nil)
	check('the pending bank is consumed by the flush', pendingBank == nil)

	-- NOTHING but the patch selection goes out: the ring's old relative CC was removed once patch
	-- selection worked, so a turn injects bank + program and no CC at all.
	ringPatchTarget, pendingCC, pendingDelta, pendingCCOrder = 1, {}, {}, {}
	handle_sl_frame(ring(1))
	check('the ring emits no CC alongside the patch selection',
		next(pendingDelta) == nil and next(pendingCC) == nil)
	check('...only the program change', pendingProgram == 1)

	-- Past 128 patches the bank advances instead of the program wrapping silently: patch 129 is bank 1,
	-- program 0. This is what lifts the 128-patch ceiling, and it was verified across the boundary.
	listRows = concert(200)
	ringPatchTarget, pendingCC, pendingDelta, pendingCCOrder = 128, {}, {}, {}
	pendingProgram, pendingBank = nil, nil
	handle_sl_frame(ring(1))
	check('patch 129 crosses into bank 1', pendingBank == 1)
	check('...with the program wrapping to 0', pendingProgram == 0)
	ringPatchTarget = 128
	pendingProgram, pendingBank = nil, nil
	handle_sl_frame(ring(0 - 1))
	check('patch 127 stays in bank 0', pendingBank == 0 and pendingProgram == 126)

	-- Clamps at the concert's own ends.
	listRows = concert(10)
	ringPatchTarget, pendingProgram = 2, nil
	handle_sl_frame(ring(-8))
	check('scrolling back past the first patch clamps there', ringPatchTarget == 1)
	check('...and selects program 0', pendingProgram == 0)
	ringPatchTarget, pendingProgram = 9, nil
	handle_sl_frame(ring(8))
	check('scrolling past the last patch clamps at the count', ringPatchTarget == 10)
	check('...and selects that patch', pendingProgram == 9)

	-- In config mode the ring scrolls that screen and injects NOTHING.
	displayMode = 'config'
	ringPatchTarget, pendingProgram, pendingBank = 1, nil, nil
	pendingCC, pendingDelta, pendingCCOrder = {}, {}, {}
	handle_sl_frame(ring(2))
	check('the ring injects no program change while the config screen shows', pendingProgram == nil)
	check('...and does not move the patch target either', ringPatchTarget == 1)

	-- NO popup for the ring: the patch list is the feedback, and a popup would cover it. A zone encoder
	-- still pops up, so this is a ring-specific suppression rather than the popup being broken.
	displayMode, listRows = 'list', concert(10)
	local savedPopupActive, savedPopupEid = popupActive, popupEid
	popupActive, popupEid, midiOutFeedback = false, nil, {}
	handle_sl_frame(ring(1))
	check('the ring shows no popup - the patch list is the feedback', popupActive == false)
	handle_sl_frame(frame(0xF0, 0x00, 0x20, 0x1A, 0x16, SL_HOST_ID, instanceID, IT_ENCODER, EID_ZONE1,
		0x41, 0xF7))
	check('a zone encoder still shows its popup', popupActive == true)
	popupActive, popupEid = savedPopupActive, savedPopupEid

	-- A patch change re-syncs the target, however the patch was selected.
	displayMode, listRows = 'list', concert(10)
	ringPatchTarget = 99
	local rows = {
		{ IsPatch = false, Label = 'Set A', SetIndex = 0 },
		{ IsPatch = true, Label = 'P1', SetIndex = 0, PatchIndex = 0 },
		{ IsPatch = true, Label = 'P2', SetIndex = 0, PatchIndex = 1 },
		{ IsPatch = false, Label = 'Set B', SetIndex = 1 },
		{ IsPatch = true, Label = 'P3', SetIndex = 1, PatchIndex = 0 },
	}
	controller_select_patch(0, 'P3', 'Set B', 'Concert', rows, 1, 0)
	check('a patch change re-syncs the ring target to the active patch ordinal', ringPatchTarget == 3)

	listRows, ringPatchTarget, activeSetIndex, activePatchIndex, displayMode =
		savedRows, savedTarget, savedSet, savedPatch, savedMode
	pendingCC, pendingDelta, pendingCCOrder = savedCC, savedDelta, savedOrder
	pendingProgram, pendingBank = savedProgram, savedBank
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
