import CoreMIDI
import Foundation

// PASSIVE multi-port sniffer for the MainStage bridge investigation
// (see docs/mainstage-integration.md). Connects to every CoreMIDI **source**
// whose display name starts with "SL " and logs raw bytes per port.
//
// IMPORTANT - what this can and cannot see:
//   * SOURCES only (data flowing device -> host). That is all this watches.
//   * It therefore CANNOT observe a send to a *destination*. A device script's
//     `outport` names a destination, so MainStage sending to 'SL LINK' goes
//     INTO the keyboard and is invisible here. Several 2026-08-18 test rounds
//     drew "nothing arrived" conclusions from this sniffer that were actually
//     unobserved rather than negative - don't repeat that.
//     To test a send to a destination, provoke a REPLY that comes back on a
//     source (e.g. an SL Link Identification Request -> IDENTIFICATION
//     APPROVED), and validate with a positive control first
//     (Scripts/probe-sllink.swift sends exactly such a request).
//
// Uses one dedicated MIDIInputPort per source, each with its own capturing
// block, so port attribution is structural. An earlier version passed the port
// name through `srcConnRefCon` as an `UnsafeMutablePointer<String>` and read it
// back with `load(as: String.self)` - loading a managed Swift type out of raw
// memory in a real-time callback, which is not sound. Results happened to look
// consistent, but don't reintroduce it.

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func stamp() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }
func log(_ s: String) { print("[\(stamp())] \(s)"); fflush(stdout) }
func str(_ o: MIDIObjectRef, _ p: CFString) -> String {
    var out: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(o, p, &out) == noErr, let out else { return "" }
    return out.takeRetainedValue() as String
}

var client = MIDIClientRef()
MIDIClientCreate("SLAllPortsSniffer" as CFString, nil, nil, &client)

var ports: [MIDIPortRef] = []
var connected = 0

for i in 0..<MIDIGetNumberOfSources() {
    let endpoint = MIDIGetSource(i)
    let name = str(endpoint, kMIDIPropertyDisplayName)
    guard name.hasPrefix("SL ") else { continue }

    var port = MIDIPortRef()
    // `name` is captured by the block - no refcon indirection, so two ports can
    // never be confused for one another.
    let status = MIDIInputPortCreateWithBlock(client, "sniff-\(i)" as CFString, &port) { pktList, _ in
        var packet = pktList.pointee.packet
        for _ in 0..<pktList.pointee.numPackets {
            let length = Int(packet.length)
            let bytes: [UInt8] = withUnsafeBytes(of: packet.data) { Array($0.prefix(length)) }
            if !bytes.isEmpty { log("\(name): \(hex(bytes))") }
            packet = MIDIPacketNext(&packet).pointee
        }
    }
    guard status == noErr else {
        log("FAILED to create input port for \"\(name)\": \(status)")
        continue
    }
    let connectStatus = MIDIPortConnectSource(port, endpoint, nil)
    log(connectStatus == noErr
        ? "connected to \"\(name)\""
        : "FAILED to connect to \"\(name)\": \(connectStatus)")
    ports.append(port)
    connected += 1
}

guard connected > 0 else { log("no SL * sources found"); exit(1) }
log("Listening on \(connected) SL * source(s). Reminder: sources only - see the header comment.")

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 60 : 60
RunLoop.main.run(until: Date().addingTimeInterval(duration))
log("done")
