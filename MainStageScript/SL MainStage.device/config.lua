-- SL MainStage bridge - MainStage MIDI Device Script
--
-- Pairs with the "SL Link MainStage" macOS app, which publishes a *virtual*
-- CoreMIDI source + destination named to match `controller_info()` below.
-- This script is the MainStage-side half of that bridge: it receives the
-- full patch list on every patch change and forwards it to the app as a
-- private SysEx dump, and it tells the app when MainStage/the script is
-- alive (hello / heartbeat / goodbye) so the app can show real connection
-- status instead of a stale list. See docs/mainstage-integration.md and
-- CLAUDE.md for how this was established (Phase 0 spike) and
-- MainStageProtocol.swift for the Swift-side decoder that must agree with
-- every byte offset below.
--
-- Installed outside the app bundle (the app is sandboxed and cannot write
-- here itself) via Scripts/install-mainstage-script.sh, into:
--   ~/Music/Audio Music Apps/MIDI Device Scripts/<manufacturer>/<model>.device/
--
-- =========================================================================
-- SysEx dialect ("SM bridge") - KEEP THIS BLOCK IN SYNC WITH
-- MainStageProtocol.swift's matching header comment. Every byte between F0
-- and F7 is 7-bit (MSB clear, as CoreMIDI/SysEx requires); every string is
-- ASCII, 0x00-terminated; any value that can exceed 127 is split MSB-then-
-- LSB (msb = v >> 7, lsb = v & 0x7F), the same convention SL Link itself
-- uses (see SLLinkEncoder.msbLsb) - the two dialects are otherwise
-- unrelated but agree on this so both codebases share one mental model.
--
--   F0 7D 53 4D <function> [payload...] F7
--
--   7D       = MIDI "non-commercial / reserved for private use"
--              manufacturer ID (never assigned to a real manufacturer -
--              keeps this private dialect from colliding with anyone
--              else's SysEx, without registering our own ID).
--   53 4D    = ASCII "SM" ("SL MainStage") - a private bridge tag that
--              disambiguates this dialect from any other private-use
--              SysEx that also happens to share manufacturer ID 0x7D.
--   function = one of the message IDs below. All of the following flow
--              Lua (MainStage) -> app; the app answers on the same pair of
--              endpoints with plain Bank Select + Program Change (below),
--              not SysEx.
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
-- NOT SysEx: `controller_info()` below declares `patchselector = true`, so
-- MainStage's own core - not this script - expects the device to select a
-- patch with plain Bank Select MSB/LSB followed by a Program Change, per
-- the project plan: Bank Select MSB = PatchIndex, Bank Select LSB =
-- SetIndex, then Program Change (on MIDI channel 1, i.e. status bytes 0xB0/
-- 0xC0, matching the VAX77 reference). NOTE: the VAX77 script's own
-- comment and its `controller_select_patch` code both do the opposite
-- (Bank Select MSB = SetIndex via CC0, LSB = PatchIndex via CC32) - see
-- MainStageProtocol.swift's `encodeSelection` doc comment for the full
-- discrepancy. This script never needs to send that triple itself (that is
-- the app's job); it is documented here only so both ends agree on what
-- the app will emit and what this script's `controller_midi_in` must
-- therefore swallow.
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

	return { midi = { event } }
end

function controller_finalize()
	event = bridge_header(FUNC_GOODBYE)
	table.insert(event, 0xF7)
	return { midi = { event } }
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

	return { midi = { event } }
end

-- MARK: - Patch list (Patch List Dump)

-- MainStage pushes the whole patch list on every patch change. Encode it
-- into the private SysEx dump above, skipping the send if nothing changed
-- (the VAX77's own optimization - the SL88's screen redraw is not free
-- either) and using a negative-number delay in the returned event list so
-- CoreMIDI doesn't interleave this with whatever else might follow it in a
-- future revision of this script (again mirroring the VAX77).
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

	-- Only send if the dump actually changed, exactly like the VAX77 does
	-- for its own display SysEx.
	unchanged = (#savedPatchListEvent == #event)
	if unchanged then
		for i = 1, #savedPatchListEvent do
			if savedPatchListEvent[i] ~= event[i] then
				unchanged = false
				break
			end
		end
	end

	if unchanged then
		return { midi = {} }
	end

	savedPatchListEvent = event
	return { midi = { event, -50 } }
end

-- MARK: - Inbound filtering

-- Swallow inbound Program Change, exactly like the VAX77: patch selection
-- already happened via patchselector's Bank Select + Program Change
-- handling in MainStage's own core before this callback runs, so letting
-- the Program Change fall through as a generic mapped event would be a
-- second, spurious trigger.
function controller_midi_in(midiEvent, portName)
	if midiEvent[0] == 0xC0 then
		return { midi = {} }
	end
	return nil -- allow everything else through unmodified
end

-- MARK: - Device declaration

-- Model/manufacturer here MUST match what MainStageEndpoint.swift sets via
-- kMIDIPropertyManufacturer/kMIDIPropertyModel on the virtual endpoint -
-- deliberately distinct from the physical SL88's own identity
-- (manufacturer "STUDIOLOGIC", model "SL" - see docs/mainstage-
-- integration.md) so this script never shadows the real keyboard.
--
-- `items` are declared for Layout-mode mappability per the project plan,
-- even though nothing in this milestone actually sends this MIDI yet -
-- Smart Control feedback (controller_midi_out) is the next milestone (see
-- the project plan's "Out of scope" section). Kept on channel 16 (0xBF),
-- well clear of the patch-selector's Bank Select/Program Change on channel
-- 1 (0xB0/0xC0).
function controller_info()
	return {
		model = 'SL MainStage',
		manufacturer = 'SL Link Bridge',

		-- Patch selection is by Bank Select + Program Change, not raw PC
		-- numbers - see the SysEx dialect comment block above.
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
