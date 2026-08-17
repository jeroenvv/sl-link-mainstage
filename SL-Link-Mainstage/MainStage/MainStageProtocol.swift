import Foundation

// MARK: - SysEx dialect ("SM bridge")
//
// Pure encode/decode for the private SysEx dialect shared with
// `MainStageScript/SL MainStage.device/config.lua`. KEEP THIS COMMENT BLOCK
// IN SYNC WITH THE MATCHING ONE AT THE TOP OF THAT FILE - the two are the
// only source of truth for the wire format, and they must agree byte for
// byte. `import Foundation` only: no CoreMIDI, no SwiftUI, so this file
// compiles standalone into `Scripts/run-codec-tests.sh` alongside the SL
// Link codec, per CLAUDE.md's "Codec tests" convention.
//
// Every byte between F0 and F7 is 7-bit (MSB clear); every string is
// ASCII, 0x00-terminated; any value that can exceed 127 is split MSB-then-
// LSB (msb = v >> 7, lsb = v & 0x7F) - the same convention SL Link itself
// uses (`SLLinkEncoder.msbLsb`). The two dialects are otherwise unrelated
// (deliberately not sharing code, in case they diverge later) but agree on
// this formula so both codebases share one mental model.
//
//   F0 7D 53 4D <function> [payload...] F7
//
//   7D       = MIDI "non-commercial / reserved for private use"
//              manufacturer ID (never assigned to a real manufacturer -
//              keeps this private dialect from colliding with anyone
//              else's SysEx, without registering our own ID).
//   53 4D    = ASCII "SM" ("SL MainStage") - a private bridge tag that
//              disambiguates this dialect from any other private-use
//              SysEx that also happens to share manufacturer ID 0x7D.
//   function = one of the message IDs below. All of them flow
//              Lua (MainStage) -> app; the app answers on the same pair of
//              endpoints with plain Bank Select + Program Change (see
//              `encodeSelection` below), not SysEx.
//
//   0x01  Bridge Hello        controller_initialize
//     F0 7D 53 4D 01 <protocolVersion> <appName> 00 F7
//       protocolVersion : 1 byte (currently 1; always < 128, not split).
//       appName         : MainStage's `applicationName` argument, 0x00-terminated.
//
//   0x02  Bridge Goodbye      controller_finalize
//     F0 7D 53 4D 02 F7
//       No payload.
//
//   0x03  Heartbeat           controller_timer_trigger (periodic)
//     F0 7D 53 4D 03 <seqMSB> <seqLSB> F7
//       seq : 14-bit counter, incremented and wrapped every beat.
//
//   0x10  Patch List Dump     controller_select_patch
//     F0 7D 53 4D 10 <concertName> 00 <entryCountMSB> <entryCountLSB>
//         entry* <currentSetIndex> <currentPatchIndex> F7
//       concertName  : 0x00-terminated.
//       entryCount   : 14-bit (a large concert can plausibly exceed 127
//                      combined sets+patches).
//       entry        : <entryType> <patchIndex> <setIndex> <label> 00
//         entryType  : 0x01 = set/song (IsPatch == false),
//                      0x02 = patch     (IsPatch == true).
//         patchIndex : 0-127, or 0x7F meaning "n/a". Never split MSB/LSB:
//                      this is the same value used verbatim as a Bank
//                      Select byte (see `encodeSelection`), which is
//                      inherently a 7-bit MIDI field, so 128 sets/patches
//                      is MainStage's own ceiling, not one this dialect
//                      adds.
//         setIndex   : same shape as patchIndex.
//         label      : 0x00-terminated.
//       currentSetIndex, currentPatchIndex : same 0-127-or-0x7F shape,
//         the currently active entry.
//
// Patch selection (app -> MainStage) is deliberately NOT part of this
// SysEx dialect - see `encodeSelection` below.

nonisolated enum MainStageHeader {
    static let sysexStart: UInt8 = 0xF0
    static let sysexEnd: UInt8 = 0xF7
    static let manufacturerID: UInt8 = 0x7D
    static let tag1: UInt8 = 0x53 // 'S'
    static let tag2: UInt8 = 0x4D // 'M'

    /// Sentinel for "no set/patch index" on the wire - mirrors the
    /// Infinite Response VAX77 reference script's own use of `0x7F` for the
    /// same purpose.
    static let indexNone: UInt8 = 0x7F
}

nonisolated enum MainStageFunction: UInt8 {
    case hello = 0x01
    case goodbye = 0x02
    case heartbeat = 0x03
    case patchList = 0x10
}

/// One row of a `MainStagePatchList` - either a set/song header or a patch.
/// `patchIndex`/`setIndex` are `nil` when the wire carried the `0x7F`
/// "n/a" sentinel (e.g. a set header has no patch index of its own).
nonisolated struct MainStagePatchEntry: Equatable {
    let isPatch: Bool
    let patchIndex: UInt8?
    let setIndex: UInt8?
    let label: String
}

/// A fully decoded Patch List Dump.
nonisolated struct MainStagePatchList: Equatable {
    let concertName: String
    let entries: [MainStagePatchEntry]
    let currentSetIndex: UInt8?
    let currentPatchIndex: UInt8?
}

/// A decoded inbound "SM bridge" message (always Lua -> app).
nonisolated enum MainStageInbound: Equatable {
    case hello(protocolVersion: UInt8, appName: String)
    case goodbye
    case heartbeat(sequence: Int)
    case patchList(MainStagePatchList)
}

/// Pure, side-effect-free encode/decode for the "SM bridge" dialect. No
/// CoreMIDI, no state - see the file header for the byte layout.
nonisolated enum MainStageProtocol {

    // MARK: - Shared helpers

    /// Same formula as `SLLinkEncoder.msbLsb`, kept as an independent copy
    /// deliberately - the two dialects are otherwise unrelated and this
    /// file must stay compilable/testable without depending on the SL Link
    /// layer.
    private static func msbLsb(_ value: Int) -> (msb: UInt8, lsb: UInt8) {
        let clamped = UInt16(clamping: max(0, value))
        return (UInt8((clamped >> 7) & 0x7F), UInt8(clamped & 0x7F))
    }

    private static func combine(msb: UInt8, lsb: UInt8) -> Int {
        (Int(msb & 0x7F) << 7) | Int(lsb & 0x7F)
    }

    private static func indexOrNil(_ byte: UInt8) -> UInt8? {
        byte == MainStageHeader.indexNone ? nil : byte
    }

    private static func indexByte(_ value: UInt8?) -> UInt8 {
        guard let value, value <= 0x7E else { return MainStageHeader.indexNone }
        return value
    }

    /// Reads a `0x00`-terminated ASCII string starting at `start`. Returns
    /// the decoded string and the index just past the terminator, or `nil`
    /// if no terminator is found before the payload ends (truncated/malformed).
    private static func readString(_ bytes: [UInt8], from start: Int) -> (value: String, next: Int)? {
        guard start <= bytes.count else { return nil }
        var i = start
        while i < bytes.count, bytes[i] != 0x00 {
            i += 1
        }
        guard i < bytes.count else { return nil } // ran off the end without a terminator
        let scalars = bytes[start..<i].map { UnicodeScalar($0) }
        return (String(String.UnicodeScalarView(scalars)), i + 1)
    }

    private static func writeString(_ text: String, into bytes: inout [UInt8]) {
        for scalar in text.unicodeScalars where scalar.value <= 0x7F {
            bytes.append(UInt8(scalar.value))
        }
        bytes.append(0x00)
    }

    // MARK: - Decode (Lua -> app)

    /// Decodes one complete `F0 ... F7` SysEx byte stream. Returns `nil` for
    /// anything malformed: bad header, MSB set on a data byte, unknown
    /// function, or a payload whose shape doesn't match its function
    /// (wrong length, bad entry count, unterminated string, trailing
    /// garbage).
    static func decode(_ bytes: [UInt8]) -> MainStageInbound? {
        guard bytes.count >= 6 else { return nil }
        guard bytes.first == MainStageHeader.sysexStart, bytes.last == MainStageHeader.sysexEnd else { return nil }
        guard bytes[1] == MainStageHeader.manufacturerID,
              bytes[2] == MainStageHeader.tag1,
              bytes[3] == MainStageHeader.tag2 else { return nil }

        // Every data byte between F0 and F7 must have its MSB clear.
        let dataBytes = bytes[1..<(bytes.count - 1)]
        guard dataBytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }

        guard let function = MainStageFunction(rawValue: bytes[4]) else { return nil }
        let payload = Array(bytes[5..<(bytes.count - 1)])

        switch function {
        case .hello:
            return decodeHello(payload)
        case .goodbye:
            guard payload.isEmpty else { return nil }
            return .goodbye
        case .heartbeat:
            guard payload.count == 2 else { return nil }
            return .heartbeat(sequence: combine(msb: payload[0], lsb: payload[1]))
        case .patchList:
            return decodePatchList(payload)
        }
    }

    private static func decodeHello(_ payload: [UInt8]) -> MainStageInbound? {
        guard payload.count >= 2 else { return nil }
        let version = payload[0]
        guard let (name, next) = readString(payload, from: 1), next == payload.count else { return nil }
        return .hello(protocolVersion: version, appName: name)
    }

    private static func decodePatchList(_ payload: [UInt8]) -> MainStageInbound? {
        guard let (concertName, afterName) = readString(payload, from: 0) else { return nil }
        var index = afterName

        guard index + 2 <= payload.count else { return nil }
        let entryCount = combine(msb: payload[index], lsb: payload[index + 1])
        index += 2

        var entries: [MainStagePatchEntry] = []
        entries.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard index + 3 <= payload.count else { return nil }
            let entryTypeByte = payload[index]
            let patchIndexByte = payload[index + 1]
            let setIndexByte = payload[index + 2]
            index += 3

            let isPatch: Bool
            switch entryTypeByte {
            case 0x01: isPatch = false
            case 0x02: isPatch = true
            default: return nil
            }

            guard let (label, afterLabel) = readString(payload, from: index) else { return nil }
            index = afterLabel

            entries.append(MainStagePatchEntry(
                isPatch: isPatch,
                patchIndex: indexOrNil(patchIndexByte),
                setIndex: indexOrNil(setIndexByte),
                label: label
            ))
        }

        // Exactly two bytes (currentSetIndex, currentPatchIndex) must
        // remain - anything else is trailing garbage or truncation.
        guard index + 2 == payload.count else { return nil }
        let currentSetIndex = indexOrNil(payload[index])
        let currentPatchIndex = indexOrNil(payload[index + 1])

        return .patchList(MainStagePatchList(
            concertName: concertName,
            entries: entries,
            currentSetIndex: currentSetIndex,
            currentPatchIndex: currentPatchIndex
        ))
    }

    // MARK: - Encode (app -> MainStage: patch selection)

    /// Encodes a patch selection as plain (non-SysEx) MIDI: Bank Select MSB
    /// (CC0) = **SetIndex**, Bank Select LSB (CC32) = **PatchIndex**, then a
    /// Program Change - on **channel 16** - matching `controller_info()`'s
    /// `patchselector = true` in `config.lua`.
    ///
    /// The ordering and the channel both come from the Infinite Response
    /// VAX77 reference script, whose header states what MainStage itself
    /// listens for:
    ///
    /// > MainStage is listening to MIDI Bank Select MSB/LSB on channel 16,
    /// > with MSB being an index to the set that should be selected and LSB
    /// > being the patch inside this set.
    ///
    /// Its code agrees (`0xB0,0x00,currentSetIndex` and
    /// `0xB0,0x20,currentPatchIndex`).
    ///
    /// An earlier revision had MSB and LSB swapped and defaulted to channel
    /// 1, taken from the "bank select MSB/LSB" labels further down that
    /// script. Those labels describe the VAX77's *own* device-bound SysEx
    /// dump - what it tells its hardware to send later - not what MainStage
    /// receives, and the channel was missed entirely. The header is the
    /// authoritative statement of the host-facing contract.
    ///
    /// Still unconfirmed against real MainStage: the whole `patchselector`
    /// path depends on MainStage generically matching a *virtual* endpoint,
    /// which no shipped script does. Verify before trusting.
    static func encodeSelection(patchIndex: UInt8?, setIndex: UInt8?, channel: UInt8 = 15) -> [UInt8] {
        let ch = channel & 0x0F
        let controlChange: UInt8 = 0xB0 | ch
        let programChange: UInt8 = 0xC0 | ch
        return [
            controlChange, 0x00, indexByte(setIndex),   // Bank Select MSB (CC0)  = SetIndex
            controlChange, 0x20, indexByte(patchIndex), // Bank Select LSB (CC32) = PatchIndex
            programChange, MainStageHeader.indexNone,   // PC value is irrelevant to patchselector; VAX77 uses 0x7F
        ]
    }
}
