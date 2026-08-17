import CoreMIDI
import Foundation

// PASSIVE sniffer. Connects to the SL LINK source and logs every inbound
// message with no filtering and no identification of its own, so it does not
// disturb whatever session the app already has. Also captures non-SysEx
// channel-voice traffic (CC / pitch bend), which the encoder-reserved-for-audio
// theory would produce.

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func stamp() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }
func log(_ s: String) { print("[\(stamp())] \(s)"); fflush(stdout) }
func str(_ o: MIDIObjectRef, _ p: CFString) -> String {
    var out: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(o, p, &out) == noErr, let out else { return "" }
    return out.takeRetainedValue() as String
}

let HEADER: [UInt8] = [0x00, 0x20, 0x1A, 0x16]

let encoderName: [UInt8: String] = [
    0x00: "Zone1", 0x01: "Zone2", 0x02: "Zone3", 0x03: "Zone4",
    0x04: "Joystick", 0x05: "A ENCODER", 0x06: "B encoder"
]
let buttonName: [UInt8: String] = [
    0x00: "Zone1 enc btn", 0x01: "Zone2 enc btn", 0x02: "Zone3 enc btn", 0x03: "Zone4 enc btn",
    0x04: "Zone1 select", 0x05: "Zone2 select", 0x06: "Zone3 select", 0x07: "Zone4 select",
    0x09: "Global", 0x0A: "DAW", 0x0B: "A ENC BUTTON", 0x0C: "B enc button",
    0x0E: "Apply", 0x0F: "Cancel", 0x10: "Home",
    0x11: "Joy Up", 0x12: "Joy Left", 0x13: "Joy Down", 0x14: "Joy Right", 0x15: "Joy Main"
]
let itemName: [UInt8: String] = [
    0x00: "System", 0x01: "Button", 0x02: "WhiteLED", 0x03: "Encoder",
    0x04: "Display", 0x05: "RGBLED", 0x06: "HardwareSettings", 0x07: "MasterVolume", 0x7F: "Identification"
]

var counts: [String: Int] = [:]

func report(_ frame: [UInt8]) {
    guard frame.count >= 10, Array(frame[1...4]) == HEADER else {
        log("RAW  \(hex(frame))   <- not an SL Link frame")
        counts["non-SLLink", default: 0] += 1
        return
    }
    let id1 = frame[5], id2 = frame[6], item = frame[7], fn = frame[8]
    let payload = Array(frame.dropFirst(9).dropLast())
    let itemLabel = itemName[item] ?? "UNKNOWN-ITEM"

    var detail = ""
    switch item {
    case 0x03:
        let tick = Int(payload.first ?? 0x40) - 0x40
        detail = "\(encoderName[fn] ?? "encoder 0x\(String(format: "%02X", fn))") delta \(tick > 0 ? "+" : "")\(tick)"
    case 0x01:
        let evt = payload.first ?? 0
        detail = "\(buttonName[fn] ?? "button 0x\(String(format: "%02X", fn))") " +
                 (evt == 1 ? "SHORT" : evt == 2 ? "LONG" : "evt=0x\(String(format: "%02X", evt))")
    case 0x07:
        detail = "MASTER VOLUME rw=\(payload.count > 0 ? "\(payload[0])" : "-") " +
                 "vol=\(payload.count > 1 ? "\(payload[1])" : "-") mute=\(payload.count > 2 ? "\(payload[2])" : "-")"
    case 0x06: detail = "HARDWARE SETTINGS hst=\(payload.first.map { String($0, radix: 2) } ?? "-")"
    case 0x00: detail = "system fn=0x\(String(format: "%02X", fn)) payload=[\(hex(payload))]"
    case 0x7F: detail = "identification fn=0x\(String(format: "%02X", fn)) payload=[\(hex(payload))]"
    default:   detail = "fn=0x\(String(format: "%02X", fn)) payload=[\(hex(payload))]"
    }

    counts["\(itemLabel): \(detail.split(separator: " ").prefix(2).joined(separator: " "))", default: 0] += 1
    log("SYSEX \(hex(frame))")
    log("      dev=\(String(format: "%02X %02X", id1, id2))  \(itemLabel)  \(detail)")
}

func describeVoice(_ b: [UInt8]) -> String {
    guard let s = b.first else { return "" }
    let ch = (s & 0x0F) + 1, kind = s & 0xF0
    switch kind {
    case 0xB0: return "CC ch\(ch) controller=\(b.count > 1 ? "\(b[1])" : "?") value=\(b.count > 2 ? "\(b[2])" : "?")"
    case 0xE0: return "PitchBend ch\(ch)"
    case 0x90: return "NoteOn ch\(ch)"
    case 0x80: return "NoteOff ch\(ch)"
    case 0xC0: return "ProgramChange ch\(ch) program=\(b.count > 1 ? "\(b[1])" : "?")"
    default:   return "status 0x\(String(format: "%02X", s))"
    }
}

guard let source: MIDIEndpointRef = {
    for i in 0..<MIDIGetNumberOfSources() {
        let e = MIDIGetSource(i)
        if str(e, kMIDIPropertyDisplayName).range(of: "LINK", options: .caseInsensitive) != nil { return e }
    }
    return nil
}() else { log("✗ SL LINK source not found"); exit(1) }

var client = MIDIClientRef(); MIDIClientCreate("SLSniffer" as CFString, nil, nil, &client)
var acc: [UInt8] = []
var inPort = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "sniff" as CFString, &inPort) { pktList, _ in
    var p = pktList.pointee.packet
    for _ in 0..<pktList.pointee.numPackets {
        let len = Int(p.length)
        let bytes: [UInt8] = withUnsafeBytes(of: p.data) { Array($0.prefix(len)) }
        var voice: [UInt8] = []
        for byte in bytes {
            if byte == 0xF0 { acc = [byte] }
            else if !acc.isEmpty {
                acc.append(byte)
                if byte == 0xF7 { let f = acc; acc = []; report(f) }
            } else {
                voice.append(byte)          // channel-voice traffic, not SysEx
            }
        }
        if !voice.isEmpty {
            log("VOICE \(hex(voice))   \(describeVoice(voice))")
            counts["channel-voice", default: 0] += 1
        }
        p = MIDIPacketNext(&p).pointee
    }
}
MIDIPortConnectSource(inPort, source, nil)

log("✓ Passively sniffing \"\(str(source, kMIDIPropertyDisplayName))\" — sends nothing, disturbs nothing.")
log("   Turn the A encoder, press the A encoder button, and try some LONG presses.")

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 90 : 90
RunLoop.main.run(until: Date().addingTimeInterval(duration))

log("── summary ──")
for (k, v) in counts.sorted(by: { $0.value > $1.value }) { log(String(format: "%5d  %@", v, k)) }
log("done")
