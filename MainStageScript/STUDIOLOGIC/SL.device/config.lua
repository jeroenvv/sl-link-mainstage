-- SL MainStage bridge - MainStage MIDI Device Script
--
-- Pairs with the "SL Link MainStage" macOS app. This script is the
-- MainStage-side half of that bridge: it receives the full patch list on
-- every patch change and forwards it to the app as a private SysEx-shaped
-- frame, and it tells the app when MainStage/the script is alive (hello /
-- heartbeat / goodbye) so the app can show real connection status instead
-- of a stale list. See docs/mainstage-integration.md and CLAUDE.md for how
-- this was established and MainStageProtocol.swift for the Swift-side
-- decoder that must agree with every byte offset below.
--
-- MATCHING: generic (manufacturer/model against the real SL88 MK2's own
-- identity - see controller_info() below), NOT usb_vendor_id/usb_product_id.
-- An earlier revision matched generically against a *virtual* endpoint the
-- app published (manufacturer "SL Link Bridge") to avoid claiming the real
-- keyboard's own device-script identity - that was established dead
-- (docs/mainstage-integration.md's "Virtual device registration" section: a
-- bare MIDISourceCreate/MIDIDestinationCreate endpoint has no
-- MIDIDeviceRef/MIDIEntityRef parent, and MainStage never binds config.lua
-- to one). A later revision switched to usb_vendor_id/usb_product_id
-- matching against the physical SL88 instead - confirmed to get the script
-- invoked, but comparing against all 98 of Apple's bundled reference
-- scripts found that every one of them sending unsolicited MIDI matches
-- generically, and none of the 3 usb_vendor_id-matched ones do (see
-- docs/mainstage-integration.md's "MIDI outbound, round 2"). Generic
-- matching against the real SL88 (unlike the earlier virtual endpoint) also
-- has a real MIDIDeviceRef/MIDIEntityRef, so this is the current, settled
-- choice. Consequence: this script occupies the SL88's own device-script
-- slot, and `MainStageProtocol.encodeSelection`/`MainStageEndpoint.
-- sendSelection` (app -> MainStage patch selection, sent from the app's
-- *virtual* endpoint) are unconfirmed either way; out of scope for the
-- inbound (MainStage -> app) direction this file implements.
--
-- TRANSPORT: **outbound MIDI from this script WORKS** (established
-- 2026-08-19 on real hardware). The blocker for every earlier attempt was
-- simply the `outport` *name*:
--
--     outport must be the SHORT kMIDIPropertyName ('LINK'),
--     NOT the display name ('SL LINK').
--
-- MainStage itself tells you this: the `portName` argument it passes to
-- `controller_midi_in` is 'LINK'. Every prior round used 'SL LINK' (or the
-- app's virtual destination, or omitted it) and silently delivered nothing.
-- Proof: sending an SL Link Identification Request with outport='LINK' drew
-- a real reply from the SL88 on the LINK source -
--   F0 00 20 1A 16 03 6D 7F 01 01 01 02 01 F7  (IDENTIFICATION APPROVED,
--                                               firmware 1.1.2, model SL88)
-- captured by Scripts/sniff-all-sl-ports.swift with the helper app closed,
-- against a positive control that had already proven the observation chain.
--
-- Inbound also works: `controller_midi_in` receives the SL88's traffic,
-- including SysEx, so this script can both send and receive SL Link.
--
-- `io` remains unavailable in MainStage's Lua sandbox (`attempt to index
-- global 'io' (a nil value)`), so the file transport below is dead. The
-- `write_frame`/`io.open` calls are harmless (`pcall`-wrapped) and kept only
-- until the MIDI path fully replaces them. See docs/mainstage-integration.md.
--
-- NOTE for a multi-instance-safe design: MainStage loads this script once
-- per matched USB-MIDI interface (two instances observed). Both used the
-- same hardcoded DeviceID below, so the second got
--   F0 00 20 1A 16 03 6D 7F 02 00 ... F7  (IDENTIFICATION REJECTED,
--                                          reason 0x00 = DeviceID taken)
-- A real implementation needs a per-instance DeviceID, or must tolerate the
-- rejection and retry with a different instance byte.
--
-- Installed outside the app bundle (the app is sandboxed and cannot write
-- here itself) via Scripts/install-mainstage-script.sh, into:
--   ~/Music/Audio Music Apps/MainStage Devices/<manufacturer>/<model>.device/
-- ("MIDI Device Scripts" is Logic Pro's folder of the same shape - see
-- docs/mainstage-integration.md's Phase 0 v2 correction.)
--
-- =========================================================================
-- SysEx-shaped frame dialect ("SM bridge") - KEEP THIS BLOCK IN SYNC WITH
-- MainStageProtocol.swift's matching header comment. Every byte between F0
-- and F7 is 7-bit (MSB clear - a holdover from this dialect's MIDI origins,
-- kept so both sides share one mental model); every string is ASCII,
-- 0x00-terminated; any value that can exceed 127 is split MSB-then-LSB
-- (msb = v >> 7, lsb = v & 0x7F), the same convention SL Link itself uses
-- (see SLLinkEncoder.msbLsb).
--
--   F0 7D 53 4D <function> [payload...] F7
--
--   7D       = MIDI "non-commercial / reserved for private use"
--              manufacturer ID (never assigned to a real manufacturer -
--              keeps this private dialect from colliding with anyone
--              else's SysEx, without registering our own ID). Vestigial
--              now that this isn't sent as real MIDI, but kept so the
--              frame shape doesn't need to change if MIDI delivery is ever
--              revisited.
--   53 4D    = ASCII "SM" ("SL MainStage") - a private bridge tag that
--              disambiguates this dialect from any other private-use
--              SysEx-shaped data that also happens to share ID 0x7D.
--   function = one of the message IDs below. All of the following flow
--              Lua (MainStage) -> app; the app answers on the same pair of
--              endpoints with plain Bank Select + Program Change (below),
--              not this dialect.
--
--   0x01  Bridge Hello        controller_initialize
--     F0 7D 53 4D 01 <protocolVersion> <appName> 00 F7
--       protocolVersion : 1 byte, this dialect's version (currently 1;
--                          always < 128, so not split).
--       appName         : MainStage's `applicationName` argument,
--                          0x00-terminated.
--
--   0x02  Bridge Goodbye      controller_finalize
--     F0 7D 53 4D 02 F7
--       No payload.
--
--   0x03  Heartbeat           controller_timer_trigger (periodic)
--     F0 7D 53 4D 03 <seqMSB> <seqLSB> F7
--       seq : 14-bit counter, incremented and wrapped every beat. Lets the
--             app notice gaps as well as absence; not itself required for
--             the liveness check (which is just "did *a* heartbeat arrive
--             recently"), but cheap and useful in the dev console.
--
--   0x10  Patch List Dump     controller_select_patch
--     F0 7D 53 4D 10 <concertName> 00 <entryCountMSB> <entryCountLSB>
--         entry* <currentSetIndex> <currentPatchIndex> F7
--       concertName  : 0x00-terminated.
--       entryCount   : 14-bit (a large concert can plausibly exceed 127
--                      combined sets+patches).
--       entry        : <entryType> <patchIndex> <setIndex> <label> 00
--         entryType  : 0x01 = set/song (IsPatch == false),
--                      0x02 = patch     (IsPatch == true).
--         patchIndex : 0-127, or 0x7F meaning "n/a" - mirrors the
--                      Infinite Response VAX77 script this structure is
--                      modelled on. Never split MSB/LSB: this is the same
--                      value used verbatim as a Bank Select byte (below),
--                      which is inherently a 7-bit MIDI field, so 128
--                      sets/patches is MainStage's own ceiling, not one
--                      this dialect adds.
--         setIndex   : same shape as patchIndex.
--         label      : 0x00-terminated.
--       currentSetIndex, currentPatchIndex : same 0-127-or-0x7F shape as
--         above; the currently active entry, so the app can highlight it
--         without a round trip, and can tell the difference between "the
--         list changed" and "MainStage's own UI changed the active patch"
--         (see docs/mainstage-integration.md's verification step 6).
--
-- Patch selection (app -> MainStage, the other direction) is deliberately
-- NOT part of this dialect: `controller_info()` below declares
-- `patchselector = true`, so MainStage's own core - not this script -
-- expects the device to select a patch with plain Bank Select MSB/LSB
-- followed by a Program Change: Bank Select MSB (CC0) = SetIndex, Bank
-- Select LSB (CC32) = PatchIndex, then a Program Change, all on MIDI
-- channel 16 (status bytes 0xBF/0xCF). That ordering and channel come from
-- the VAX77 reference script's header, which states what MainStage itself
-- listens for: "MainStage is listening to MIDI Bank Select MSB/LSB on
-- channel 16, with MSB being an index to the set that should be selected
-- and LSB being the patch inside this set." Do not take the "bank select
-- MSB/LSB" labels further down that script as the contract - those
-- describe its own device-bound SysEx dump, not what MainStage receives.
-- This script never sends that triple itself (that would be the app's
-- job, and see the MATCHING note above on why it's now doubtful the app
-- even can); it is documented here only so both ends agree on what
-- `controller_midi_in` below must swallow.
-- =========================================================================

MFR_ID = 0x7D
TAG1 = 0x53 -- 'S'
TAG2 = 0x4D -- 'M'

FUNC_HELLO = 0x01
FUNC_GOODBYE = 0x02
FUNC_HEARTBEAT = 0x03
FUNC_PATCHLIST = 0x10

PROTOCOL_VERSION = 0x01
ENTRY_SET = 0x01
ENTRY_PATCH = 0x02
INDEX_NONE = 0x7F

-- Heartbeat cadence. The app treats the bridge as down if none arrives
-- within a small multiple of this - see MainStageEndpoint's heartbeat
-- timeout, and SLLinkSession's 3s/5s keepalive for the shape this copies.
HEARTBEAT_MS = 2000

heartbeatSeq = 0
savedPatchListEvent = {}

-- MARK: - File-based transport
--
-- Outbound MIDI is confirmed undeliverable in this MainStage version (see
-- the TRANSPORT note at the top of this file), so every frame is written
-- straight to a file instead of returned as `{midi=...}`. Two files, each
-- always fully overwritten (`'wb'`, not appended) rather than kept as a
-- log, since only the latest state matters and an unbounded log would grow
-- forever over a long session:
--   STATUS_PATH    : latest Hello/Heartbeat/Goodbye frame.
--   PATCHLIST_PATH : latest Patch List Dump frame.
-- Kept as two separate files (rather than one) so a heartbeat write can
-- never race with/clobber a patch-list write.
--
-- Every write is `pcall`-wrapped and reports success/failure through
-- `print()` regardless of outcome, so the result is visible in
-- `/tmp/lua.log` under the debugging recipe (docs/mainstage-integration.md)
-- even if `io.open`/`io.write` errors instead of failing quietly. This
-- also doubles as the io-library re-test docs/mainstage-integration.md's
-- "Next thing to try" called for - no separate probe needed once this
-- script is confirmed to actually run (which the matching fix above is
-- what makes true).
STATUS_PATH = '/tmp/sl-mainstage-bridge-status.bin'
PATCHLIST_PATH = '/tmp/sl-mainstage-bridge-patchlist.bin'

function write_frame(path, event)
	local ok, err = pcall(function()
		local file = io.open(path, 'wb')
		if file == nil then
			print('[bridge] io.open returned nil for path=' .. path)
			return
		end
		for i = 1, #event do
			file:write(string.char(event[i]))
		end
		file:close()
		print('[bridge] wrote ' .. #event .. ' byte(s) to ' .. path)
	end)
	if not ok then
		print('[bridge] pcall error writing ' .. path .. ': ' .. tostring(err))
	end
end

-- MARK: - Helpers

-- 0x00-terminates an ASCII string into a growable event table.
function append_string(event, text)
	if text ~= nil then
		for i = 1, #text do
			table.insert(event, string.byte(text, i))
		end
	end
	table.insert(event, 0x00)
end

-- Splits a value that can exceed 127 into (msb, lsb) - mirrors
-- SLLinkEncoder.msbLsb / the comment block above.
function msb_lsb(value)
	if value < 0 then value = 0 end
	return math.floor(value / 128) % 128, value % 128
end

-- Clamps a MainStage set/patch index to the 0-127-or-INDEX_NONE shape used
-- on the wire (see the Patch List Dump section above).
function clamp_index(value)
	if value == nil or value < 0 then
		return INDEX_NONE
	end
	if value > 127 then
		return 127
	end
	return value
end

function bridge_header(func)
	return { 0xF0, MFR_ID, TAG1, TAG2, func }
end

-- MARK: - Lifecycle (Bridge Hello / Goodbye / Heartbeat)

-- MARK: - SL Link session, spoken by the script itself (Lua-only mode)
--
-- See the big block comment on controller_midi_in below for what this is
-- testing and why. Byte shape verified against SLLinkEncoder:
--   F0 00 20 1A 16 <id1> <id2> 7F 00 <ASCII name> 00 F7
-- The instance byte is arbitrary but must be stable across the session.
SLLINK_PROBE_ID1 = 0x03 -- HOST_ID, the same constant the app uses
SLLINK_PROBE_ID2 = 0x6D -- our own instance byte
-- MainStage reports portName='LINK' (short kMIDIPropertyName) in
-- controller_midi_in - so that, not 'SL LINK', is the name MainStage
-- itself uses for this port. Aligning outport to match (2026-08-19).
SLLINK_PROBE_OUTPORT = 'LINK'

function sl_link_identification_request()
	local msg = { 0xF0, 0x00, 0x20, 0x1A, 0x16, SLLINK_PROBE_ID1, SLLINK_PROBE_ID2, 0x7F, 0x00 }
	append_string(msg, 'LuaProbe') -- ASCII + 0x00 terminator
	table.insert(msg, 0xF7)
	return msg
end

function controller_initialize(applicationName, deviceNewlyDetected)
	settriggertimer(HEARTBEAT_MS) -- prime the periodic heartbeat
	heartbeatSeq = 0
	savedPatchListEvent = {}
	capturedEvents = 0
	identificationSent = false

	event = bridge_header(FUNC_HELLO)
	table.insert(event, PROTOCOL_VERSION)
	append_string(event, applicationName)
	table.insert(event, 0xF7)
	write_frame(STATUS_PATH, event)

	-- Unsolicited attempt, kept alongside the reply-path attempt in
	-- controller_midi_in purely as a control: same bytes, same outport, but
	-- now in the **flat** `midi` form rather than the nested form every
	-- previous lifecycle probe used. If the reply path works and this one
	-- doesn't, that isolates unsolicited-vs-reactive as the real difference.
	local probe = sl_link_identification_request()
	print('[capture] controller_initialize -> Identification Request (' ..
	      #probe .. ' bytes, flat form) outport=' .. SLLINK_PROBE_OUTPORT)
	return { midi = probe, outport = SLLINK_PROBE_OUTPORT }
end

function controller_finalize()
	event = bridge_header(FUNC_GOODBYE)
	table.insert(event, 0xF7)
	write_frame(STATUS_PATH, event)
	return nil
end

-- Periodic heartbeat. Re-arms itself every call so it keeps firing for as
-- long as the device stays selected, unlike the VAX77's one-shot use of
-- this same callback.
function controller_timer_trigger()
	settriggertimer(HEARTBEAT_MS)

	heartbeatSeq = (heartbeatSeq + 1) % 16384
	seqMSB, seqLSB = msb_lsb(heartbeatSeq)

	event = bridge_header(FUNC_HEARTBEAT)
	table.insert(event, seqMSB)
	table.insert(event, seqLSB)
	table.insert(event, 0xF7)
	write_frame(STATUS_PATH, event)

	return nil
end

-- MARK: - Patch list (Patch List Dump)

-- MainStage pushes the whole patch list on every patch change. Encode it
-- into the frame dialect above, skipping the write if nothing changed (the
-- VAX77's own optimization for its own display SysEx - a redundant write
-- of the same bytes isn't free either).
function controller_select_patch(programchangeNumber, patchname, setname, concertname, patchlist, currentSetIndex, currentPatchIndex)
	event = bridge_header(FUNC_PATCHLIST)
	append_string(event, concertname)

	countMSB, countLSB = msb_lsb(#patchlist)
	table.insert(event, countMSB)
	table.insert(event, countLSB)

	for i = 1, #patchlist do
		if patchlist[i].IsPatch then
			table.insert(event, ENTRY_PATCH)
		else
			table.insert(event, ENTRY_SET)
		end
		table.insert(event, clamp_index(patchlist[i].PatchIndex))
		table.insert(event, clamp_index(patchlist[i].SetIndex))
		append_string(event, patchlist[i].Label)
	end

	table.insert(event, clamp_index(currentSetIndex))
	table.insert(event, clamp_index(currentPatchIndex))
	table.insert(event, 0xF7)

	unchanged = (#savedPatchListEvent == #event)
	if unchanged then
		for i = 1, #savedPatchListEvent do
			if savedPatchListEvent[i] ~= event[i] then
				unchanged = false
				break
			end
		end
	end

	if not unchanged then
		savedPatchListEvent = event
		write_frame(PATCHLIST_PATH, event)
	end

	return nil
end

-- MARK: - Inbound filtering

-- Swallow inbound Program Change, exactly like the VAX77: patch selection
-- already happened via patchselector's Bank Select + Program Change
-- handling in MainStage's own core before this callback runs, so letting
-- the Program Change fall through as a generic mapped event would be a
-- second, spurious trigger. Harmless to keep even given the MATCHING note
-- at the top of this file casting doubt on whether the app-side half of
-- patchselector actually works now - this side only ever discards, never
-- depends on it.
-- ==========================================================================
-- LUA-ONLY MODE (2026-08-19) - no helper app involved.
--
-- Goal: have the script itself speak SL Link to the SL88 - identify, then
-- capture what comes back - with the "SL Link MainStage" app not running at
-- all, so nothing else holds the LINK port or drives the session.
--
-- Two things are being established here at once:
--
-- 1. WHAT LUA ACTUALLY RECEIVES. Every `controller_midi_in` call is logged
--    with its `portName` and raw bytes. This finally answers an open
--    question: whether MainStage delivers the declared controls to the
--    script at all, and on which port it thinks they arrive. It also shows
--    whether SysEx reaches the script - the VAX77 reference matches
--    `midiEvent[0] == 0xF0` in its own `controller_midi_in`, so SysEx is
--    expected to be delivered, which is what would let Lua read SL Link
--    replies.
--
-- 2. WHETHER A *REPLY* GETS SENT. Every failed outbound test so far sent
--    from a lifecycle hook (`controller_initialize`/`_timer_trigger`/
--    `_select_patch`) - i.e. unsolicited. Returning MIDI from
--    `controller_midi_in` is a different, untested path: a reply to an
--    inbound event. Apple's own M-Audio Oxygen 49 script uses exactly this
--    (`return {midi={0xB0,0x50+midiEvent[1],0x7F}}`), and it is one of the
--    few bundled scripts that sends anything at all. If MainStage flushes
--    the reactive path but not the unsolicited one, this is where it shows.
--
-- Also differs in message *shape*: `midi` is a **flat** byte array here
-- (Launchkey MK3 style, the confirmed-working modern reference), where the
-- earlier lifecycle probes used VAX77-style nesting (`midi = { event }`).
-- Both forms appear in shipped scripts; the flat one has never been tried
-- from this project.
--
-- Success looks like: an IDENTIFICATION APPROVED (`... 7F 01 ...`) arriving
-- back through `controller_midi_in` and/or on the LINK source in
-- Scripts/sniff-all-sl-ports.swift.
-- ==========================================================================

capturedEvents = 0
identificationSent = false

-- Renders a midiEvent (0-indexed, unknown length) as hex for the log.
function dump_event(midiEvent)
	local parts = {}
	local i = 0
	while i < 64 do
		local b = midiEvent[i]
		if b == nil then break end
		parts[#parts + 1] = string.format('%02X', b)
		i = i + 1
	end
	if #parts == 0 then return '(empty)' end
	return table.concat(parts, ' ')
end

function controller_midi_in(midiEvent, portName)
	capturedEvents = capturedEvents + 1
	-- Log everything, but cap the volume: playing the keyboard generates a
	-- lot of traffic and the interesting frames (SysEx replies) are rare.
	local isSysex = (midiEvent[0] == 0xF0)
	if isSysex or capturedEvents <= 40 then
		print('[capture] #' .. capturedEvents ..
		      ' port=' .. tostring(portName) ..
		      (isSysex and ' SYSEX ' or ' ') ..
		      dump_event(midiEvent))
	end

	-- Reply to the very first inbound event with an SL Link Identification
	-- Request. Sending it as a *reply* is the whole point of this test; see
	-- the block comment above. Swallowing that one event is harmless.
	if not identificationSent then
		identificationSent = true
		local msg = sl_link_identification_request()
		print('[capture] -> replying with SL Link Identification Request (' ..
		      #msg .. ' bytes, flat form) outport=' .. SLLINK_PROBE_OUTPORT)
		return { midi = msg, outport = SLLINK_PROBE_OUTPORT }
	end

	if midiEvent[0] == 0xC0 then
		return { midi = {} } -- swallow Program Change, as before
	end
	return nil -- allow everything else through unmodified
end

-- MARK: - Device declaration

-- Manufacturer/model here are the real SL88 MK2's own identity (see
-- docs/mainstage-integration.md's "The SL88's own MIDI identity" section),
-- not a separate virtual-endpoint identity - see the MATCHING note at the
-- top of this file for why.
--
-- MATCH METHOD (2026-08-18 update): generic (manufacturer/model), not
-- usb_vendor_id/usb_product_id. Comparing this project's outbound attempts
-- against all 98 of Apple's own bundled reference scripts found a clean
-- correlation with no counterexamples: every script that sends unsolicited
-- MIDI from a lifecycle hook (VAX77, KeyLab 88, Launch Control, MPK249,
-- etc.) matches generically; of the only 3 scripts in the whole bundle with
-- an active usb_vendor_id, none send unsolicited MIDI at all - the SL88
-- (unlike the earlier abandoned virtual-endpoint design) has a real
-- MIDIDeviceRef/MIDIEntityRef, so generic matching against it is a
-- genuinely new, untested configuration, not a repeat of the dead virtual-
-- endpoint attempt. usb_vendor_id/usb_product_id (`0x9516`/`0x4039`,
-- decimal below, confirmed live in the Phase 0 v2 spike) kept as a comment
-- for reference, mirroring how Apple's own KeyLab 88.device/config.lua
-- keeps its usb ids commented out.
function controller_info()
	return {
		model = 'SL',
		manufacturer = 'STUDIOLOGIC',

		-- usb_vendor_id = 38166,  -- 0x9516
		-- usb_product_id = 16441, -- 0x4039

		-- Patch selection is by Bank Select + Program Change, not raw PC
		-- numbers - see the frame dialect comment block above.
		patchselector = true,

		-- ITEMS describe MIDI the SL88 **actually transmits**, captured live
		-- (2026-08-19) with one input port per source while playing the
		-- keyboard and moving both sticks. Every event - notes, pitch bend,
		-- modulation, sustain - arrived on **SL LINK**, zero on SL CTRL, so
		-- that is the `inport`. The previous table here was invented CC
		-- numbers (0xBF 0x50-0x5C) the SL88 never sends, with no ports
		-- declared at all; the working Launchkey MK3 reference instead
		-- declares real controls on real ports, giving MainStage an actual
		-- bidirectional surface to bind.
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
