import CoreMIDI
import Foundation

// PASSIVE multi-port sniffer for the MainStage bridge outbound re-test
// (see docs/mainstage-integration.md). Unlike sniff.swift (which only
// connects to the SL LINK source and parses SL Link SysEx), this connects
// to every source whose display name starts with "SL " (CTRL, DAW, LINK)
// and just logs raw bytes per port, since we don't know in advance which
// port (if any) MainStage routes a bare, outport-less `{midi=...}` return
// to for a generically-matched multi-port device.

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func stamp() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }
func log(_ s: String) { print("[\(stamp())] \(s)"); fflush(stdout) }
func str(_ o: MIDIObjectRef, _ p: CFString) -> String {
    var out: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(o, p, &out) == noErr, let out else { return "" }
    return out.takeRetainedValue() as String
}

var sources: [(name: String, endpoint: MIDIEndpointRef)] = []
for i in 0..<MIDIGetNumberOfSources() {
    let e = MIDIGetSource(i)
    let name = str(e, kMIDIPropertyDisplayName)
    if name.range(of: "SL ", options: .caseInsensitive) != nil {
        sources.append((name, e))
    }
}
guard !sources.isEmpty else { log("no SL * sources found"); exit(1) }

var client = MIDIClientRef()
MIDIClientCreate("SLAllPortsSniffer" as CFString, nil, nil, &client)

var accByPort: [String: [UInt8]] = [:]
var inPort = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "sniff-all" as CFString, &inPort) { pktList, srcConnRefCon in
    let portName = srcConnRefCon?.load(as: String.self) ?? "?"
    var p = pktList.pointee.packet
    for _ in 0..<pktList.pointee.numPackets {
        let len = Int(p.length)
        let bytes: [UInt8] = withUnsafeBytes(of: p.data) { Array($0.prefix(len)) }
        var acc = accByPort[portName] ?? []
        var voice: [UInt8] = []
        for byte in bytes {
            if byte == 0xF0 { acc = [byte] }
            else if !acc.isEmpty {
                acc.append(byte)
                if byte == 0xF7 {
                    log("SYSEX on \(portName): \(hex(acc))")
                    acc = []
                }
            } else {
                voice.append(byte)
            }
        }
        accByPort[portName] = acc
        if !voice.isEmpty { log("VOICE on \(portName): \(hex(voice))") }
        p = MIDIPacketNext(&p).pointee
    }
}

// Each source gets its own boxed name so the read block can tell them apart.
var boxes: [UnsafeMutablePointer<String>] = []
for (name, endpoint) in sources {
    let box = UnsafeMutablePointer<String>.allocate(capacity: 1)
    box.initialize(to: name)
    boxes.append(box)
    let status = MIDIPortConnectSource(inPort, endpoint, box)
    log(status == noErr ? "connected to \"\(name)\"" : "FAILED to connect to \"\(name)\": \(status)")
}

log("Listening on \(sources.count) SL * port(s). Waiting for MainStage to relaunch/select a patch...")

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 60 : 60
RunLoop.main.run(until: Date().addingTimeInterval(duration))
log("done")
