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
-- outbound is therefore queued into `pendingOut` and flushed by whichever
-- callback fires next (see queue_message/flush_pending). Consequence: the
-- keepalive cadence is bounded by how often controller_timer_trigger fires.
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
pendingOut = {}

-- Latest patch info from MainStage, painted once the session goes active.
currentPatch = ''
currentSet = ''
currentConcert = ''
screenDirty = false

-- MARK: - Outbound plumbing
--
-- A script can only send by returning MIDI from a callback, so build up a
-- flat byte array here and let the next callback flush it. Flat (rather than
-- nested-per-message) is the Launchkey MK3 reference's form, and multiple
-- complete F0..F7 messages may simply be concatenated.

function queue_message(msg)
	for i = 1, #msg do
		table.insert(pendingOut, msg[i])
	end
end

-- Inserts a delay marker (negative number = milliseconds) so CoreMIDI does
-- not interleave a burst of display writes - the VAX77 reference does the
-- same around its own SysEx dump.
function queue_delay(ms)
	table.insert(pendingOut, -ms)
end

function flush_pending()
	if #pendingOut == 0 then return nil end
	local out = pendingOut
	pendingOut = {}
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

-- Repaints the whole screen. The SL88 keeps no display state across Standby,
-- so this is also what a Restart triggers.
-- CURRENT STATE (2026-08-19): a single Write Text, sent on its own, renders
-- correctly on the SL88. **Confirmed working on hardware.**
--
-- An earlier version of this function queued Clear Screen + three Write Texts
-- + negative delay markers into one flat array, and the result was a black
-- screen: the Clear Screen clearly landed, nothing after it did. Bisecting to
-- this single message made text appear, so the fault is in one of the two
-- things that were removed:
--   (a) the negative delay markers (-20/-10) - prime suspect. In a flat array
--       they may be corrupting everything that follows them, which would
--       explain "first message applied, rest dropped" exactly. The Launchkey
--       MK3 reference uses -2 between messages, so the mechanism itself is
--       real; the encoding of our values may not be.
--   (b) multiple complete F0..F7 messages concatenated in one flat array. The
--       Launchkey reference does exactly this and works, so this is the less
--       likely of the two - but it has not been isolated yet.
--
-- NEXT STEP: re-add one element at a time (first a second Write Text with no
-- delays; then Clear Screen; then delays) to find which one breaks it, rather
-- than restoring the whole original paint at once.
function paint_screen()
	queue_message(msg_write_text(currentPatch, 8, 80, 304,
		ALIGN_CENTER, SIZE_BIG, 255, 255, 255, 0, 0, 0))

	screenDirty = false
	print('[sllink] painted: "' .. currentPatch .. '"')
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
			-- Reply to our own keepalive query. Nothing to do with it beyond
			-- having received it: arriving here is what re-armed the timer.
			if e[9] == 0x00 and state ~= STATE_IDENTIFYING then
				-- Keyboard says we are NOT identified - session was dropped, so
				-- climb back in rather than keep talking into the void.
				print('[sllink] <- query says not identified; re-identifying')
				state = STATE_IDLE
				start_identification()
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
	pendingOut = {}
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
	pendingOut = {}
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
	print('[sllink] timer tick #' .. timerTicks .. ' state=' .. state)

	-- Keepalive UNCONDITIONALLY once we have sent an Identification Request.
	--
	-- Originally this only fired in LISTED/ACTIVE, i.e. only after seeing an
	-- IDENTIFICATION APPROVED come back. On hardware the approval is never
	-- delivered to this script (MainStage does not appear to pass the SL88's
	-- SysEx to controller_midi_in - only channel-voice traffic), so the state
	-- machine sat in IDENTIFYING, no keepalive was ever sent, and the entry
	-- aged out of the SL88's APP list after ~5s - "MainStage showed up
	-- briefly, then disappeared".
	--
	-- So the session is driven open-loop: keep announcing ourselves whether or
	-- not we can observe the replies. Harmless if the keyboard has already
	-- logged us in, and it is what keeps us in the list if it hasn't.
	if state == STATE_IDLE then
		start_identification()
	else
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
	queue_message(msg_identification_query())

	return flush_pending()
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
function controller_midi_in(midiEvent, portName)
	settriggertimer(KEEPALIVE_MS)

	-- Log EVERY inbound SysEx, matched or not. This is the diagnostic for
	-- whether MainStage delivers the SL88's protocol traffic to the script at
	-- all - so far it appears not to, which is why the session runs open-loop.
	if midiEvent[0] == 0xF0 then
		print('[sllink] <- SYSEX on port=' .. tostring(portName) .. ': ' .. dump_event(midiEvent))
	end

	if is_our_sl_frame(midiEvent) then
		handle_sl_frame(midiEvent)
		-- Protocol traffic, not music: swallow it, and use the opportunity to
		-- flush whatever the handler queued.
		local out = flush_pending()
		if out ~= nil then return out end
		return { midi = {} }
	end

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

	-- Paint open-loop: we cannot see login confirmations (see the note in
	-- controller_timer_trigger), so draw whenever MainStage tells us the patch
	-- changed and let the keyboard ignore it if we are not logged in yet.
	paint_screen()
	return flush_pending()
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
