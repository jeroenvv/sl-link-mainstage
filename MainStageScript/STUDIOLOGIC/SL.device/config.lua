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
-- MATCHING: by usb_vendor_id/usb_product_id against the real SL88 MK2
-- (see controller_info() below), NOT generically against a virtual
-- CoreMIDI endpoint. An earlier revision matched generically against a
-- virtual endpoint the app published (manufacturer "SL Link Bridge") to
-- avoid claiming the real keyboard's own device-script identity - that
-- was established dead (docs/mainstage-integration.md's "Virtual device
-- registration" section: a bare MIDISourceCreate/MIDIDestinationCreate
-- endpoint has no MIDIDeviceRef/MIDIEntityRef parent, and MainStage never
-- binds config.lua to one). USB-ID matching against the physical SL88 is
-- the only method confirmed (Phase 0 v2 spike) to actually get this script
-- invoked, with real patch data. Consequence: this script now occupies the
-- SL88's own device-script slot, and `MainStageProtocol.encodeSelection`/
-- `MainStageEndpoint.sendSelection` (app -> MainStage patch selection,
-- sent from the app's *virtual* endpoint) are even less likely to be
-- recognized by MainStage's patchselector handling than before, since that
-- now targets a different endpoint than the one actually matched to this
-- script. Unconfirmed either way; out of scope for the inbound (MainStage
-- -> app) direction this file implements.
--
-- TRANSPORT: file-based, not MIDI. Phase 0 v2 (docs/mainstage-
-- integration.md) exhaustively confirmed that no `outport` value - not the
-- app's virtual destination, not any of the SL88's own port names, not
-- omitting `outport` - ever delivers a script-returned MIDI event in this
-- MainStage version. Every lifecycle hook below writes its frame straight
-- to a file with `io.open` instead of returning `{midi=...}`; the app
-- polls those files. The on-the-wire byte layout is unchanged from the
-- original MIDI-SysEx design (still F0...F7, still decoded by the same
-- `MainStageProtocol.decode` on the Swift side) so only the transport
-- changed, not the dialect.
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

function controller_initialize(applicationName, deviceNewlyDetected)
	settriggertimer(HEARTBEAT_MS) -- prime the periodic heartbeat
	heartbeatSeq = 0
	savedPatchListEvent = {}

	event = bridge_header(FUNC_HELLO)
	table.insert(event, PROTOCOL_VERSION)
	append_string(event, applicationName)
	table.insert(event, 0xF7)
	write_frame(STATUS_PATH, event)

	return nil
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
function controller_midi_in(midiEvent, portName)
	if midiEvent[0] == 0xC0 then
		return { midi = {} }
	end
	return nil -- allow everything else through unmodified
end

-- MARK: - Device declaration

-- Manufacturer/model here are the real SL88 MK2's own identity (see
-- docs/mainstage-integration.md's "The SL88's own MIDI identity" section),
-- not a separate virtual-endpoint identity - see the MATCHING note at the
-- top of this file for why. usb_vendor_id/usb_product_id are the values
-- captured live in the Phase 0 v2 spike (`LUA: Script matched for USB ID
-- 0x9516,0x4039`), decimal per this field's convention in Apple's own
-- bundled scripts (e.g. Arturia/KeyLab 88.device/config.lua).
--
-- `items` are declared for Layout-mode mappability per the project plan,
-- but the CC numbers below are placeholders invented for this project's
-- own (never-shipped) virtual-endpoint design - they do NOT correspond to
-- anything the real SL88 actually transmits, and now that this script is
-- matched to the real hardware that distinction matters more than it used
-- to. Left in as-is (harmless: nothing currently depends on them mapping
-- to real output) rather than removed, since redesigning them against the
-- SL88's real MIDI output is unstarted work, not a regression from this
-- change.
function controller_info()
	return {
		model = 'SL',
		manufacturer = 'STUDIOLOGIC',

		usb_vendor_id = 38166,  -- 0x9516
		usb_product_id = 16441, -- 0x4039

		-- Patch selection is by Bank Select + Program Change, not raw PC
		-- numbers - see the frame dialect comment block above.
		patchselector = true,

		items = {
			{name='Joystick Up', objectType='Button', midiType='Momentary', midi={0xBF,0x50,MIDI_LSB}},
			{name='Joystick Down', objectType='Button', midiType='Momentary', midi={0xBF,0x51,MIDI_LSB}},
			{name='Joystick Left', objectType='Button', midiType='Momentary', midi={0xBF,0x52,MIDI_LSB}},
			{name='Joystick Right', objectType='Button', midiType='Momentary', midi={0xBF,0x53,MIDI_LSB}},
			{name='Joystick Main', objectType='Button', midiType='Momentary', midi={0xBF,0x54,MIDI_LSB}},

			{name='A Encoder', objectType='Knob', midiType='Relative2C', midi={0xBF,0x55,MIDI_LSB}},
			{name='A Encoder Button', objectType='Button', midiType='Momentary', midi={0xBF,0x56,MIDI_LSB}},
			{name='B Encoder', objectType='Knob', midiType='Relative2C', midi={0xBF,0x57,MIDI_LSB}},
			{name='B Encoder Button', objectType='Button', midiType='Momentary', midi={0xBF,0x58,MIDI_LSB}},

			{name='Zone 1 Select', objectType='Button', midiType='Momentary', midi={0xBF,0x59,MIDI_LSB}},
			{name='Zone 2 Select', objectType='Button', midiType='Momentary', midi={0xBF,0x5A,MIDI_LSB}},
			{name='Zone 3 Select', objectType='Button', midiType='Momentary', midi={0xBF,0x5B,MIDI_LSB}},
			{name='Zone 4 Select', objectType='Button', midiType='Momentary', midi={0xBF,0x5C,MIDI_LSB}},
		}
	}
end
