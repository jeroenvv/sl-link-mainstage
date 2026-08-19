-- SL MainStage - MainStage MIDI Device Script for the Studiologic SL88 MK2
--
-- Speaks the SL Link protocol **directly from Lua**, with no helper
-- application involved: the script identifies itself to the keyboard, holds
-- the session alive, and draws the current MainStage patch on the SL88's
-- screen. See docs/mainstage-integration.md for how this was established and
-- SL-Link-Mainstage/SLLink/ for the Swift implementation every byte here is
-- checked against.
--
-- =========================================================================
-- THE ONE THING THAT MATTERS MOST (2026-08-19)
--
--     outport must be the SHORT kMIDIPropertyName:  'LINK'
--     NOT the CoreMIDI display name:                'SL LINK'
--
-- Getting this wrong makes MainStage silently drop every outbound message,
-- with no error anywhere. It cost this project a dozen test rounds and a
-- premature "this is impossible" conclusion. MainStage tells you the right
-- name itself: the `portName` argument handed to controller_midi_in is
-- 'LINK'. Confirmed on hardware - with outport='LINK' the SL88 answers an
-- Identification Request with IDENTIFICATION APPROVED:
--   F0 00 20 1A 16 03 6D 7F 01 01 01 02 01 F7   (firmware 1.1.2, model SL88)
-- =========================================================================
--
-- MATCHING: generic, on the SL88's own manufacturer/model ('STUDIOLOGIC'/
-- 'SL'), not usb_vendor_id/usb_product_id - see controller_info() at the
-- bottom and docs/mainstage-integration.md's "MIDI outbound, round 2".
--
-- MULTIPLE INSTANCES: MainStage loads this script once per matched USB-MIDI
-- interface (two instances observed on this SL88). They cannot share a
-- DeviceID - the second one gets IDENTIFICATION REJECTED with reason 0x00
-- ("DeviceID taken"). Rather than trying to invent per-instance entropy in a
-- sandboxed Lua with no `os`/`io`, this script simply walks its instance byte
-- forward on every rejection until the keyboard accepts one. Self-healing and
-- deterministic - see handle_identification_rejected().
--
-- SENDING IS RETURN-VALUE ONLY: a device script can only emit MIDI by
-- returning it from a callback. There is no "send now" function. Everything
-- outbound is therefore queued into `pendingMessages` and flushed by whichever
-- callback fires next (see queue_message/flush_pending). Consequence: the
-- keepalive cadence is bounded by how often controller_timer_trigger fires.
--
-- DRAWING RULES, all found the hard way on hardware (see
-- docs/mainstage-integration.md for the full evidence):
--   * MainStage silently discards a returned array over ~78-87 bytes - the
--     WHOLE array, not the overflow. Hence FLUSH_BUDGET and one message per
--     flush. The SL Link spec has no such limit; this is a MainStage cap.
--   * Do NOT send Clear Screen. With a clear at the head of a repaint exactly
--     one text line went missing every time, and which line varied run to run
--     - a race against a slow full-screen fill. Write Text overwrites the
--     pixels it covers (spec, display-messages.md), so redrawing is
--     self-cleaning and the clear is unnecessary.
--   * Do not truncate strings. Max Width truncates visually in pixels and
--     appends '...' by itself.
--
-- SL Link message shape (docs/, and SLLinkEncoder.swift):
--   F0 00 20 1A 16 <id1> <id2> <itemType> <function> [payload...] F7
--   00 20 1A = Fatar/Studiologic manufacturer ID, 16 = SL Link protocol ID.

-- MARK: - Protocol constants (mirror SLLinkProtocol.swift exactly)

SL_PORT = 'LINK' -- see the banner above; NOT 'SL LINK'

SL_HEADER = { 0xF0, 0x00, 0x20, 0x1A, 0x16 }
SL_END = 0xF7

SL_HOST_ID = 0x03 -- SLLinkHeader.defaultHostID
SL_INSTANCE_START = 0x6D -- first instance byte tried; bumped on rejection

-- Item types
IT_SYSTEM = 0x00
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

-- Text align / size
ALIGN_LEFT, ALIGN_CENTER = 0x00, 0x01
SIZE_SMALL, SIZE_MEDIUM, SIZE_BIG = 0x00, 0x01, 0x02

-- The keyboard drops a host that goes quiet for ~5s; the app uses 3s.
KEEPALIVE_MS = 3000

APP_NAME = 'MainStage'

-- MARK: - Session state

STATE_IDLE = 'idle'
STATE_IDENTIFYING = 'identifying'
STATE_LISTED = 'listed' -- approved, waiting for the user to pick us on the SL88
STATE_ACTIVE = 'active'
STATE_STANDBY = 'standby'

state = STATE_IDLE
instanceID = SL_INSTANCE_START
pendingMessages = {}

-- Latest patch info from MainStage, painted once the session goes active.
currentPatch = ''
currentSet = ''
currentConcert = ''
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

-- While output is still queued, ask for the next tick quickly rather than
-- waiting a whole keepalive period, so a repaint converges in a fraction of a
-- second instead of one message every KEEPALIVE_MS.
FLUSH_SOON_MS = 100

function queue_message(msg)
	table.insert(pendingMessages, msg)
end

function has_pending()
	return #pendingMessages > 0
end

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
	if #pendingMessages > 0 then
		local m = pendingMessages[1]
		if #m + reserve <= FLUSH_BUDGET then
			table.remove(pendingMessages, 1)
			for i = 1, #m do out[#out + 1] = m[i] end
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
	append_text(m, text, 96)
	table.insert(m, SL_END)
	return m
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
TEXT_X = 8
TEXT_MAXW = SCREEN_WIDTH - (2 * TEXT_X)

-- Repaints the screen. The SL88 keeps no display state across Standby, so this
-- is also what a Restart triggers.
-- Drops display messages still sitting in the queue. A newer paint completely
-- supersedes an older one; letting the two interleave mid-drain draws garbage.
-- Protocol messages (identification, logout, ...) are preserved.
function drop_queued_display()
	local keep = {}
	for i = 1, #pendingMessages do
		local m = pendingMessages[i]
		if m[8] ~= IT_DISPLAY then keep[#keep + 1] = m end
	end
	pendingMessages = keep
end

function paint_screen()
	drop_queued_display()

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

	-- ORDER TEST (2026-08-19): patch drawn FIRST, concert/set after. All four
	-- messages are confirmed to leave the script (see the FLUSH log), yet the
	-- patch line never appears while concert and set always do - and the patch
	-- has always been queued LAST. Swapping the order distinguishes
	-- "the last message of a repaint gets lost" from "this particular message
	-- is bad": if the patch now renders and the set line disappears instead,
	-- it is positional; if all three render, it is ordering-sensitive.
	queue_message(msg_write_text(currentPatch, TEXT_X, 80, TEXT_MAXW,
		ALIGN_CENTER, SIZE_BIG, 255, 255, 255, 0, 0, 0))
	queue_message(msg_write_text(currentConcert, TEXT_X, 4, TEXT_MAXW,
		ALIGN_LEFT, SIZE_SMALL, 150, 150, 150, 0, 0, 0))
	queue_message(msg_write_text(currentSet, TEXT_X, 30, TEXT_MAXW,
		ALIGN_LEFT, SIZE_SMALL, 110, 170, 230, 0, 0, 0))

	-- TRAILING SACRIFICIAL REDRAW.
	--
	-- Empirically the FINAL flush of a repaint never takes effect: whichever
	-- display message ends up last is silently lost, and swapping the draw
	-- order just moves the loss to whatever is now last. It is not about the
	-- message's content, size, position, or what it is bundled with - a lone
	-- 43-byte Write Text as the last flush is dropped just the same as one
	-- paired with a keepalive. Anything with a further transmission after it
	-- renders reliably.
	--
	-- So end every repaint with a harmless duplicate. Re-drawing the concert
	-- line is idempotent (identical pixels, same coordinates), so it costs one
	-- extra message and is safe to lose - which it duly is, while everything
	-- that matters now has something following it.
	queue_message(msg_write_text(currentConcert, TEXT_X, 4, TEXT_MAXW,
		ALIGN_LEFT, SIZE_SMALL, 150, 150, 150, 0, 0, 0))

	screenDirty = false
	lastPaintedPatch = currentPatch
	lastPaintTick = idleTicks
	print('[sllink] paint queued (' .. #pendingMessages .. ' msgs): "' .. currentPatch .. '"')
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
	print('[sllink] <- IDENTIFICATION APPROVED as ' ..
	      string.format('%02X %02X', SL_HOST_ID, instanceID) ..
	      ' - now in the SL88 APP list; select it there to activate')
end

-- Reason 0x00 = DeviceID taken/reserved. Walk the instance byte forward and
-- try again; this is what lets a second script instance coexist with the
-- first without any source of per-instance entropy.
function handle_identification_rejected(reason)
	print('[sllink] <- IDENTIFICATION REJECTED (reason ' ..
	      string.format('%02X', reason or 0) .. ') for instance ' ..
	      string.format('%02X', instanceID))
	instanceID = instanceID + 1
	if instanceID > 0x7E then instanceID = 0x10 end
	start_identification()
end

function handle_login()
	state = STATE_ACTIVE
	print('[sllink] <- LOGIN - session active')
	paint_screen()
end

function handle_standby()
	state = STATE_STANDBY
	print('[sllink] <- STANDBY')
end

function handle_restart()
	state = STATE_ACTIVE
	print('[sllink] <- RESTART - repainting (SL88 retains no screen state)')
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
				if currentPatch ~= '' and not has_pending() then
					local stale = (lastPaintedPatch ~= currentPatch)
					local due = (idleTicks - lastPaintTick) >= REPAINT_EVERY_IDLE_TICKS
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
	end
end

-- MARK: - MainStage callbacks

function controller_initialize(applicationName, deviceNewlyDetected)
	settriggertimer(KEEPALIVE_MS)
	state = STATE_IDLE
	instanceID = SL_INSTANCE_START
	pendingMessages = {}
	currentPatch, currentSet, currentConcert = '', '', ''

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

	if is_our_sl_frame(midiEvent) then
		handle_sl_frame(midiEvent)
		-- Protocol traffic, not music: swallow it, and use the opportunity to
		-- flush whatever the handler queued.
		local out = flush_pending(true)
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

function controller_select_patch(programchangeNumber, patchname, setname, concertname,
                                 patchlist, currentSetIndex, currentPatchIndex)
	local p, s, c = patchname or '', setname or '', concertname or ''

	-- MainStage calls this repeatedly with identical values (observed 5x for
	-- one patch change, partly because the script is loaded once per USB-MIDI
	-- interface). Repainting each time would waste a lot of MIDI - a full
	-- repaint is several messages - so only redraw on a real change.
	if p == currentPatch and s == currentSet and c == currentConcert then
		return nil
	end

	currentPatch, currentSet, currentConcert = p, s, c
	print('[sllink] controller_select_patch: "' .. currentPatch .. '"')

	-- Draw whenever MainStage says the patch changed, without waiting to be
	-- sure we are logged in: a LOGIN CONFIRMATION only arrives on a *fresh*
	-- login, and the keyboard harmlessly ignores drawing we are not entitled
	-- to do. The ID_QUERY branch repaints again once the session is confirmed.
	paint_screen()
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
