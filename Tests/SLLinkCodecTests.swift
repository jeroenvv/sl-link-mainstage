import Foundation

// Plain top-level executable (no XCTest, no test target - see CLAUDE.md /
// Scripts/run-codec-tests.sh). Golden byte vectors are derived from the
// tables in /tmp/sl-link-spec/docs/*.md, NOT from the malformed worked
// example at basics.md:29 (`F0 00 20 1A 16 15 E3 04 01 00 F7`), which has an
// illegal MSB-set data byte (`E3`) and a truncated Clear Screen payload.
// That exact example is instead used below as a negative test proving the
// decoder rejects it.

var failures: [String] = []
var passCount = 0

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        passCount += 1
    } else {
        failures.append(name)
        print("FAIL: \(name)")
    }
}

func checkBytes(_ name: String, _ actual: [UInt8], _ expected: [UInt8]) {
    check(name, actual == expected)
    if actual != expected {
        print("       actual:   \(hex(actual))")
        print("       expected: \(hex(expected))")
    }
}

// MARK: - Shared test fixtures

let id1: UInt8 = 0x05
let id2: UInt8 = 0x03
let header: [UInt8] = [0xF0, 0x00, 0x20, 0x1A, 0x16, id1, id2]
let sysexEnd: UInt8 = 0xF7

// MARK: - msbLsb (About the Coordinates table, display-messages.md)

// X = 84 -> MSB 0, LSB 84 (0x54)
check("msbLsb(84) == (0, 84)", SLLinkEncoder.msbLsb(84) == (0, 84))
// Y = 156 -> MSB 1, LSB 28 (0x1C)
check("msbLsb(156) == (1, 28)", SLLinkEncoder.msbLsb(156) == (1, 28))
// Y = 31 -> MSB 0, LSB 31 (0x1F)
check("msbLsb(31) == (0, 31)", SLLinkEncoder.msbLsb(31) == (0, 31))
// X = 293 -> MSB 2. The table's own decimal LSB column ("5") contradicts its
// own binary column (`0b0010 0101` = 37); we trust the formula (msb = v>>7,
// lsb = v&0x7F) and the binary column, not the mistyped decimal restatement.
// Judgment call: flagged in the final report as something hardware testing
// could contradict if the firmware actually implements the "5" reading.
check("msbLsb(293) == (2, 37)", SLLinkEncoder.msbLsb(293) == (2, 37))

// MARK: - rgb7 (About the Colors, display-messages.md)
// "keeping the 7 most significant bits of each channel (shifting one bit
// right)" - the prose and reference implementations, not the code sample's
// >>3/>>2/>>3 (which is RGB565, pasted into the wrong section).

check("rgb7(black) == (0,0,0)", SLLinkEncoder.rgb7(.black) == (0, 0, 0))
check("rgb7(white) == (127,127,127)", SLLinkEncoder.rgb7(.white) == (127, 127, 127))
check(
    "rgb7(128,64,32) == (64,32,16)",
    SLLinkEncoder.rgb7(SLColor(r: 128, g: 64, b: 32)) == (64, 32, 16)
)

// MARK: - Identification Messages (identification-messages.md)

checkBytes(
    "identificationRequest",
    SLLinkEncoder.identificationRequest(id1: id1, id2: id2, name: "AB"),
    header + [0x7F, 0x00, 0x41, 0x42, 0x00, sysexEnd]
)

checkBytes(
    "identificationQuery (request)",
    SLLinkEncoder.identificationQuery(id1: id1, id2: id2),
    header + [0x7F, 0x03, sysexEnd]
)

check(
    "decode identificationApproved (spec-derived, no firmware/model payload)",
    SLLinkDecoder.decode(header + [0x7F, 0x01, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .identificationApproved(firmware: nil, model: nil))
)

check(
    "decode identificationApproved with wrong payload length (neither 10 nor 14 bytes) rejects",
    SLLinkDecoder.decode(header + [0x7F, 0x01, 1, 2, sysexEnd]) == nil
)

check(
    "decode identificationRejected(deviceIDTakenOrReserved)",
    SLLinkDecoder.decode(header + [0x7F, 0x02, 0x00, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .identificationRejected(reason: .deviceIDTakenOrReserved))
)

check(
    "decode identificationRejected(noSpaceInList)",
    SLLinkDecoder.decode(header + [0x7F, 0x02, 0x01, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .identificationRejected(reason: .noSpaceInList))
)

check(
    "decode identificationQueryResult(notIdentified)",
    SLLinkDecoder.decode(header + [0x7F, 0x03, 0x00, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .identificationQueryResult(.notIdentified))
)

check(
    "decode identificationQueryResult(identified)",
    SLLinkDecoder.decode(header + [0x7F, 0x03, 0x01, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .identificationQueryResult(.identified))
)

// MARK: - Real hardware captures (SL88 MK2, firmware 1.1.2, DeviceID 03 2A)
//
// Live SysEx captures taken from a physically attached SL88 MK2. These
// contradict the written spec in two ways the decoder must accept:
//   - Identification Approved carries a 4-byte `MAJ MIN REV SL`
//     firmware/model payload the spec does not document.
//   - Login Confirmation is a bare 10 bytes with NO firmware/model payload,
//     even though the spec documents one there. The firmware/model info is
//     effectively swapped relative to the docs: it arrives on the
//     Identification Approved, not on Login Confirmation.
// See CLAUDE.md's "SL Link protocol (as implemented)" section.

check(
    "REAL HARDWARE: Identification Approved carries MAJ MIN REV SL (firmware 1.1.2, SL88)",
    SLLinkDecoder.decode([0xF0, 0x00, 0x20, 0x1A, 0x16, 0x03, 0x2A, 0x7F, 0x01, 0x01, 0x01, 0x02, 0x01, 0xF7])
        == SLLinkMessage(id1: 0x03, id2: 0x2A, inbound: .identificationApproved(firmware: (1, 1, 2), model: .sl88))
)

check(
    "REAL HARDWARE: Login Confirmation is a bare 10 bytes, no firmware/model payload",
    SLLinkDecoder.decode([0xF0, 0x00, 0x20, 0x1A, 0x16, 0x03, 0x2A, 0x00, 0x01, 0xF7])
        == SLLinkMessage(id1: 0x03, id2: 0x2A, inbound: .loginConfirmed(firmware: nil, model: nil))
)

// MARK: - System Messages (system-messages.md)

checkBytes(
    "systemDeviceNotification",
    SLLinkEncoder.systemDeviceNotification(id1: id1, id2: id2),
    header + [0x00, 0x00, sysexEnd]
)

checkBytes(
    "systemDeviceNotification(name:) reference-implementation variant",
    SLLinkEncoder.systemDeviceNotification(id1: id1, id2: id2, name: "Z"),
    header + [0x00, 0x00, 0x5A, 0x00, sysexEnd]
)

checkBytes(
    "systemLogoutRequest",
    SLLinkEncoder.systemLogoutRequest(id1: id1, id2: id2),
    header + [0x00, 0x02, sysexEnd]
)

checkBytes(
    "systemLogoutConfirmation",
    SLLinkEncoder.systemLogoutConfirmation(id1: id1, id2: id2),
    header + [0x00, 0x03, sysexEnd]
)

check(
    "decode logoutRequest",
    SLLinkDecoder.decode(header + [0x00, 0x02, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .logoutRequest)
)

check(
    "decode logoutConfirmation",
    SLLinkDecoder.decode(header + [0x00, 0x03, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .logoutConfirmation)
)

check(
    "decode standby",
    SLLinkDecoder.decode(header + [0x00, 0x04, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .standby)
)

check(
    "decode restart",
    SLLinkDecoder.decode(header + [0x00, 0x05, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .restart)
)

check(
    "decode loginConfirmed (spec-derived, with firmware/model payload)",
    SLLinkDecoder.decode(header + [0x00, 0x01, 1, 2, 3, 0x00, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .loginConfirmed(firmware: (1, 2, 3), model: .sl88GT))
)

check(
    "decode loginConfirmed (synthetic, no firmware/model payload - the form real hardware actually sends)",
    SLLinkDecoder.decode(header + [0x00, 0x01, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .loginConfirmed(firmware: nil, model: nil))
)

check(
    "decode loginRecall (spec-derived, with firmware/model payload)",
    SLLinkDecoder.decode(header + [0x00, 0x06, 4, 5, 6, 0x02, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .loginRecall(firmware: (4, 5, 6), model: .sl73))
)

check(
    // Login Recall's payload has never actually been observed on hardware
    // (only Login Confirmation has been captured); this covers the
    // payload-absent form the same way Login Confirmation was found to
    // behave, on the assumption it's symmetric. Synthetic, not a capture.
    "decode loginRecall (synthetic, no firmware/model payload)",
    SLLinkDecoder.decode(header + [0x00, 0x06, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .loginRecall(firmware: nil, model: nil))
)

check(
    "decode loginConfirmed with unknown SL model rejects",
    SLLinkDecoder.decode(header + [0x00, 0x01, 1, 2, 3, 0x03, sysexEnd]) == nil
)

check(
    "decode loginConfirmed with wrong payload length (neither 10 nor 14 bytes) rejects",
    SLLinkDecoder.decode(header + [0x00, 0x01, 1, 2, sysexEnd]) == nil
)

// MARK: - Display Messages (display-messages.md)

checkBytes(
    "displayClearScreen black",
    SLLinkEncoder.displayClearScreen(id1: id1, id2: id2, color: .black),
    header + [0x04, 0x01, 0, 0, 0, sysexEnd]
)

checkBytes(
    "displayClearScreen (255,128,1)",
    SLLinkEncoder.displayClearScreen(id1: id1, id2: id2, color: SLColor(r: 255, g: 128, b: 1)),
    header + [0x04, 0x01, 127, 64, 0, sysexEnd]
)

checkBytes(
    "displayDrawRectangle",
    SLLinkEncoder.displayDrawRectangle(
        id1: id1, id2: id2, x: 10, y: 20, width: 30, height: 40,
        color: SLColor(r: 200, g: 100, b: 50)
    ),
    header + [0x04, 0x02, 0, 10, 0, 20, 0, 30, 0, 40, 100, 50, 25, sysexEnd]
)

checkBytes(
    "displayWriteText",
    SLLinkEncoder.displayWriteText(
        id1: id1, id2: id2, text: "Hi!", x: 5, y: 6, maxWidth: 100,
        align: .center, size: .big,
        foreground: SLColor(r: 255, g: 0, b: 0),
        background: SLColor(r: 0, g: 255, b: 0)
    ),
    header + [0x04, 0x00, 0, 5, 0, 6, 0, 100, 0x01, 0x02, 127, 0, 0, 0, 127, 0, 0x48, 0x69, 0x21, 0x00, sysexEnd]
)

checkBytes(
    "displayWriteText clamps out-of-font characters to space",
    SLLinkEncoder.displayWriteText(
        id1: id1, id2: id2, text: "A\u{00E9}B", x: 0, y: 0, maxWidth: 0,
        align: .left, size: .small,
        foreground: .black, background: .black
    ),
    header + [0x04, 0x00, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0x41, 0x20, 0x42, 0x00, sysexEnd]
)

checkBytes(
    "displayPlotBitmap",
    SLLinkEncoder.displayPlotBitmap(
        id1: id1, id2: id2, x: 1, y: 2, groupIndex: 0x03, iconIndex: 0x05,
        foreground: .white, background: .black
    ),
    header + [0x04, 0x03, 0, 1, 0, 2, 0x03, 0x05, 127, 127, 127, 0, 0, 0, sysexEnd]
)

// MARK: - Hardware I/O (hardware-io.md)

checkBytes(
    "ledWhite on",
    SLLinkEncoder.ledWhite(id1: id1, id2: id2, led: .zone1Button, on: true),
    header + [0x02, 0x00, 0x01, sysexEnd]
)

checkBytes(
    "ledWhite off",
    SLLinkEncoder.ledWhite(id1: id1, id2: id2, led: .appButton, on: false),
    header + [0x02, 0x04, 0x00, sysexEnd]
)

checkBytes(
    "ledRGB clamps brightness above 127",
    SLLinkEncoder.ledRGB(id1: id1, id2: id2, ledIndex: 2, color: SLColor(r: 255, g: 0, b: 128), brightness: 200),
    header + [0x05, 0x02, 127, 0, 64, 127, sysexEnd]
)

checkBytes(
    "ledRGB passes brightness through under 127",
    SLLinkEncoder.ledRGB(id1: id1, id2: id2, ledIndex: 2, color: SLColor(r: 255, g: 0, b: 128), brightness: 50),
    header + [0x05, 0x02, 127, 0, 64, 50, sysexEnd]
)

check(
    "decode button short press",
    SLLinkDecoder.decode(header + [0x01, 0x04, 0x01, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .button(id: .zone1SelectButton, event: .short))
)

check(
    "decode button long press",
    SLLinkDecoder.decode(header + [0x01, 0x15, 0x02, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .button(id: .joystickMain, event: .long))
)

check(
    "decode button with unknown BID rejects",
    SLLinkDecoder.decode(header + [0x01, 0x08, 0x01, sysexEnd]) == nil
)

// MARK: - Encoder ticks: signed, 64-centered (hardware-io.md)

func encoderDelta(_ tick: UInt8) -> Int? {
    guard case let .encoder(_, delta)? = SLLinkDecoder.decode(header + [0x03, 0x00, tick, sysexEnd])?.inbound else {
        return nil
    }
    return delta
}

check("encoder tick 0x40 (centre) -> delta 0", encoderDelta(0x40) == 0)
check("encoder tick 0x41 -> delta +1", encoderDelta(0x41) == 1)
check("encoder tick 0x3F -> delta -1", encoderDelta(0x3F) == -1)
check("encoder tick 0x00 -> delta -64 (most negative)", encoderDelta(0x00) == -64)
check("encoder tick 0x7F -> delta +63 (most positive)", encoderDelta(0x7F) == 63)

check(
    "decode encoder identifies EID",
    SLLinkDecoder.decode(header + [0x03, 0x06, 0x50, sysexEnd])
        == SLLinkMessage(id1: id1, id2: id2, inbound: .encoder(id: .bEncoder, delta: 0x50 - 64))
)

// MARK: - Malformed input is rejected, not crashed on

check("decode empty returns nil", SLLinkDecoder.decode([]) == nil)
check("decode too short returns nil", SLLinkDecoder.decode([0xF0, 0x00, 0x20, 0x1A, 0x16, id1, id2, 0xF7]) == nil)
check(
    "decode missing sysex end returns nil",
    SLLinkDecoder.decode(header + [0x7F, 0x01, 0x00]) == nil
)
check(
    "decode wrong manufacturer ID returns nil",
    SLLinkDecoder.decode([0xF0, 0x00, 0x20, 0x1B, 0x16, id1, id2, 0x7F, 0x01, sysexEnd]) == nil
)
check(
    "decode unknown ItemType returns nil",
    SLLinkDecoder.decode(header + [0x08, 0x00, sysexEnd]) == nil
)
check(
    "decode Device -> SL only messages (display) returns nil",
    SLLinkDecoder.decode(header + [0x04, 0x01, 0, 0, 0, sysexEnd]) == nil
)
check(
    "decode out-of-scope Hardware Settings (0x06) returns nil",
    SLLinkDecoder.decode(header + [0x06, 0x00, sysexEnd]) == nil
)
check(
    "decode out-of-scope Master Volume (0x07) returns nil",
    SLLinkDecoder.decode(header + [0x07, 0x00, 50, 0, sysexEnd]) == nil
)

// The spec's own worked example (basics.md:29) is malformed: `E3` has its
// MSB set, which is illegal for a MIDI data byte. Confirm the decoder
// rejects it rather than silently misinterpreting it.
check(
    "decode rejects basics.md's malformed worked example (MSB set on ID byte)",
    SLLinkDecoder.decode([0xF0, 0x00, 0x20, 0x1A, 0x16, 0x15, 0xE3, 0x04, 0x01, 0x00, sysexEnd]) == nil
)

// MARK: - MainStage bridge dialect (MainStageProtocol.swift)
//
// Golden vectors for the private "SM" SysEx dialect shared with
// MainStageScript/SL MainStage.device/config.lua. Unlike the SL Link
// vectors above there is no captured hardware/MainStage traffic to check
// against yet (MainStage hasn't been confirmed to bind a virtual endpoint -
// see CLAUDE.md / docs/mainstage-integration.md); these vectors instead pin
// down the dialect's own hand-computed byte layout so config.lua and this
// decoder can't silently drift apart. "Both directions" here means: decode
// for every message that flows Lua -> app (hello/goodbye/heartbeat/patch
// list), and encode for the one message that flows app -> Lua (patch
// selection) - there is nothing to decode in that direction, since
// MainStage's own core (not this codec) interprets the raw Bank Select/
// Program Change bytes.

func ascii(_ text: String) -> [UInt8] {
    text.unicodeScalars.map { UInt8($0.value) }
}

let msHeader: [UInt8] = [0xF0, 0x7D, 0x53, 0x4D]
let msEnd: UInt8 = 0xF7

// MARK: Bridge Hello (0x01)

check(
    "MainStage decode: Bridge Hello",
    MainStageProtocol.decode(msHeader + [0x01, 0x01] + ascii("MainStage") + [0x00, msEnd])
        == .hello(protocolVersion: 1, appName: "MainStage")
)

check(
    "MainStage decode: Bridge Hello with empty app name",
    MainStageProtocol.decode(msHeader + [0x01, 0x01, 0x00, msEnd])
        == .hello(protocolVersion: 1, appName: "")
)

check(
    "MainStage decode: Bridge Hello missing terminator rejects",
    MainStageProtocol.decode(msHeader + [0x01, 0x01] + ascii("MainStage") + [msEnd]) == nil
)

// MARK: Bridge Goodbye (0x02)

check(
    "MainStage decode: Bridge Goodbye",
    MainStageProtocol.decode(msHeader + [0x02, msEnd]) == .goodbye
)

check(
    "MainStage decode: Bridge Goodbye with unexpected payload rejects",
    MainStageProtocol.decode(msHeader + [0x02, 0x00, msEnd]) == nil
)

// MARK: Heartbeat (0x03)

check(
    "MainStage decode: Heartbeat sequence 0",
    MainStageProtocol.decode(msHeader + [0x03, 0x00, 0x00, msEnd]) == .heartbeat(sequence: 0)
)

check(
    "MainStage decode: Heartbeat sequence over 127 splits MSB/LSB (200 -> msb 1, lsb 72)",
    MainStageProtocol.decode(msHeader + [0x03, 0x01, 0x48, msEnd]) == .heartbeat(sequence: 200)
)

check(
    "MainStage decode: Heartbeat wrong payload length rejects",
    MainStageProtocol.decode(msHeader + [0x03, 0x00, msEnd]) == nil
)

// MARK: Patch List Dump (0x10) - realistic multi-song list

let multiSongPatchList: [UInt8] = {
    var event = msHeader
    event.append(0x10)
    event.append(contentsOf: ascii("Joseph key2"))
    event.append(0x00)
    event.append(contentsOf: [0x00, 0x05]) // entryCount = 5
    // Song 1 (set, no patch index of its own, set index 0)
    event.append(contentsOf: [0x01, 0x7F, 0x00])
    event.append(contentsOf: ascii("Song 1"))
    event.append(0x00)
    // Piano (patch 0 of set 0)
    event.append(contentsOf: [0x02, 0x00, 0x00])
    event.append(contentsOf: ascii("Piano"))
    event.append(0x00)
    // Strings (patch 1 of set 0)
    event.append(contentsOf: [0x02, 0x01, 0x00])
    event.append(contentsOf: ascii("Strings"))
    event.append(0x00)
    // Song 2 (set, no patch index of its own, set index 1)
    event.append(contentsOf: [0x01, 0x7F, 0x01])
    event.append(contentsOf: ascii("Song 2"))
    event.append(0x00)
    // Organ (patch 0 of set 1) - the currently active entry
    event.append(contentsOf: [0x02, 0x00, 0x01])
    event.append(contentsOf: ascii("Organ"))
    event.append(0x00)
    event.append(contentsOf: [0x01, 0x00]) // currentSetIndex=1, currentPatchIndex=0
    event.append(msEnd)
    return event
}()

let expectedMultiSongPatchList = MainStagePatchList(
    concertName: "Joseph key2",
    entries: [
        MainStagePatchEntry(isPatch: false, patchIndex: nil, setIndex: 0, label: "Song 1"),
        MainStagePatchEntry(isPatch: true, patchIndex: 0, setIndex: 0, label: "Piano"),
        MainStagePatchEntry(isPatch: true, patchIndex: 1, setIndex: 0, label: "Strings"),
        MainStagePatchEntry(isPatch: false, patchIndex: nil, setIndex: 1, label: "Song 2"),
        MainStagePatchEntry(isPatch: true, patchIndex: 0, setIndex: 1, label: "Organ"),
    ],
    currentSetIndex: 1,
    currentPatchIndex: 0
)

check(
    "MainStage decode: realistic multi-song patch list",
    MainStageProtocol.decode(multiSongPatchList) == .patchList(expectedMultiSongPatchList)
)

// MARK: Patch List Dump - empty list

let emptyPatchList: [UInt8] = msHeader + [0x10] + ascii("Empty Concert") + [0x00, 0x00, 0x00, 0x7F, 0x7F, msEnd]

check(
    "MainStage decode: empty patch list",
    MainStageProtocol.decode(emptyPatchList)
        == .patchList(MainStagePatchList(concertName: "Empty Concert", entries: [], currentSetIndex: nil, currentPatchIndex: nil))
)

// MARK: Patch List Dump - malformed input is rejected, not crashed on

check(
    "MainStage decode: wrong manufacturer ID rejects",
    MainStageProtocol.decode([0xF0, 0x7C, 0x53, 0x4D, 0x02, msEnd]) == nil
)

check(
    "MainStage decode: wrong bridge tag rejects",
    MainStageProtocol.decode([0xF0, 0x7D, 0x53, 0x4E, 0x02, msEnd]) == nil
)

check(
    "MainStage decode: unknown function rejects",
    MainStageProtocol.decode(msHeader + [0x7F, msEnd]) == nil
)

check(
    "MainStage decode: MSB set on a data byte rejects",
    MainStageProtocol.decode(msHeader + [0x02, 0x80, msEnd]) == nil
)

check(
    "MainStage decode: entry count exceeds available bytes (truncated) rejects",
    MainStageProtocol.decode(msHeader + [0x10] + ascii("X") + [0x00, 0x00, 0x05, msEnd]) == nil
)

check(
    "MainStage decode: unknown entry type byte rejects",
    MainStageProtocol.decode(msHeader + [0x10] + ascii("X") + [0x00, 0x00, 0x01, 0x03, 0x00, 0x00, msEnd]) == nil
)

let trailingGarbagePatchList: [UInt8] = msHeader + [0x10] + ascii("Empty Concert") + [0x00, 0x00, 0x00, 0x7F, 0x7F, 0x01, msEnd]

check(
    "MainStage decode: trailing garbage after current indices rejects",
    MainStageProtocol.decode(trailingGarbagePatchList) == nil
)

check(
    "MainStage decode: missing sysex end rejects",
    MainStageProtocol.decode(msHeader + [0x02]) == nil
)

check(
    "MainStage decode: empty input rejects",
    MainStageProtocol.decode([]) == nil
)

// MARK: Patch selection encode (app -> MainStage)
//
// Bank Select MSB = PatchIndex, Bank Select LSB = SetIndex, then Program
// Change - see MainStageProtocol.encodeSelection's doc comment for the
// unresolved discrepancy against the VAX77 reference script's own
// (inverted) MSB/LSB usage, flagged there for hardware verification.

checkBytes(
    "MainStage encodeSelection",
    MainStageProtocol.encodeSelection(patchIndex: 3, setIndex: 1),
    [0xB0, 0x00, 3, 0xB0, 0x20, 1, 0xC0, 0x7F]
)

checkBytes(
    "MainStage encodeSelection with nil indices sends the 0x7F sentinel",
    MainStageProtocol.encodeSelection(patchIndex: nil, setIndex: nil),
    [0xB0, 0x00, 0x7F, 0xB0, 0x20, 0x7F, 0xC0, 0x7F]
)

checkBytes(
    "MainStage encodeSelection on a non-zero channel",
    MainStageProtocol.encodeSelection(patchIndex: 5, setIndex: 2, channel: 3),
    [0xB3, 0x00, 5, 0xB3, 0x20, 2, 0xC3, 0x7F]
)

// MARK: - Summary

print("")
if failures.isEmpty {
    print("PASS: \(passCount)/\(passCount) SL Link codec tests passed.")
    exit(0)
} else {
    print("FAIL: \(failures.count) of \(passCount + failures.count) SL Link codec tests failed:")
    for name in failures {
        print("  - \(name)")
    }
    exit(1)
}
