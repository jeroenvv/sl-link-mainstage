import CoreMIDI
import Foundation

// Live SL Link handshake probe. Sends a spec-conformant Identification Request,
// then keeps the session alive with Device Notifications and logs everything the
// SL88 sends back. Ends with a clean Logout Request.

let APP_NAME = "SL MainStage"
let ID1: UInt8 = 0x03   // reference impls call this HOST_ID (0x03 = third-party app)
let ID2: UInt8 = 0x2A   // instance id, fixed here for reproducibility
let HEADER: [UInt8] = [0x00, 0x20, 0x1A, 0x16]

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}
func log(_ s: String) { print("[\(stamp())] \(s)"); fflush(stdout) }

func str(_ o: MIDIObjectRef, _ p: CFString) -> String {
    var out: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(o, p, &out) == noErr, let out else { return "" }
    return out.takeRetainedValue() as String
}

func decode(_ b: [UInt8]) -> String {
    guard b.count >= 10, b[0] == 0xF0, b.last == 0xF7,
          Array(b[1...4]) == HEADER else { return "not an SL Link frame" }
    let id1 = b[5], id2 = b[6], item = b[7], fn = b[8]
    let idNote = (id1 == ID1 && id2 == ID2) ? "ours" : "OTHER(\(String(format: "%02X %02X", id1, id2)))"
    let payload = Array(b.dropFirst(9).dropLast())

    var what: String
    switch (item, fn) {
    case (0x7F, 0x01): what = "IDENTIFICATION APPROVED"
    case (0x7F, 0x02):
        let rsn = payload.first ?? 0xFF
        what = "IDENTIFICATION REJECTED (reason \(rsn) = " +
               (rsn == 0 ? "ID taken/reserved" : rsn == 1 ? "app list full" : "unknown") + ")"
    case (0x7F, 0x03): what = "IDENTIFICATION QUERY REPLY (identified=\(payload.first ?? 0xFF))"
    case (0x00, 0x01), (0x00, 0x06):
        let kind = fn == 0x01 ? "LOGIN CONFIRMATION" : "LOGIN RECALL"
        if payload.count >= 4 {
            let model = ["SL88 GT", "SL88", "SL73"]
            let m = Int(payload[3])
            what = "\(kind) — firmware \(payload[0]).\(payload[1]).\(payload[2]), model " +
                   (m < model.count ? model[m] : "unknown(\(m))")
        } else { what = "\(kind) — payload \(hex(payload))" }
    case (0x00, 0x02): what = "LOGOUT REQUEST"
    case (0x00, 0x03): what = "LOGOUT CONFIRMATION"
    case (0x00, 0x04): what = "STANDBY"
    case (0x00, 0x05): what = "RESTART"
    case (0x00, 0x08): what = "ICON ACK (packet \(payload.first ?? 0))"
    case (0x00, 0x09): what = "ICON NACK (packet \(payload.first ?? 0))"
    case (0x01, _):
        let evt = payload.first ?? 0
        what = "BUTTON id=0x\(String(format: "%02X", fn)) " + (evt == 1 ? "SHORT" : evt == 2 ? "LONG" : "evt=\(evt)")
    case (0x03, _):
        let tick = Int(payload.first ?? 0x40) - 0x40
        what = "ENCODER id=0x\(String(format: "%02X", fn)) delta=\(tick > 0 ? "+" : "")\(tick)"
    default:
        what = "item=0x\(String(format: "%02X", item)) fn=0x\(String(format: "%02X", fn)) payload=\(hex(payload))"
    }
    return "\(what)  [\(idNote)]"
}

// ---- find the LINK endpoints -------------------------------------------------
func findLink() -> (MIDIEndpointRef, MIDIEndpointRef)? {
    var src: MIDIEndpointRef = 0, dst: MIDIEndpointRef = 0
    for i in 0..<MIDIGetNumberOfSources() {
        let e = MIDIGetSource(i)
        if str(e, kMIDIPropertyDisplayName).range(of: "LINK", options: .caseInsensitive) != nil { src = e; break }
    }
    for i in 0..<MIDIGetNumberOfDestinations() {
        let e = MIDIGetDestination(i)
        if str(e, kMIDIPropertyDisplayName).range(of: "LINK", options: .caseInsensitive) != nil { dst = e; break }
    }
    return (src != 0 && dst != 0) ? (src, dst) : nil
}

guard let (source, destination) = findLink() else {
    log("✗ Could not find both a LINK source and destination.")
    exit(1)
}
log("✓ LINK endpoints found (\(str(source, kMIDIPropertyDisplayName)))")

var client = MIDIClientRef()
MIDIClientCreate("SLLinkProbe" as CFString, nil, nil, &client)

var inPort = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "probe-in" as CFString, &inPort) { pktList, _ in
    var p = pktList.pointee.packet
    for _ in 0..<pktList.pointee.numPackets {
        let len = Int(p.length)
        let bytes: [UInt8] = withUnsafeBytes(of: p.data) { Array($0.prefix(len)) }
        log("RX  \(hex(bytes))")
        log("    → \(decode(bytes))")
        p = MIDIPacketNext(&p).pointee
    }
}
MIDIPortConnectSource(inPort, source, nil)

var outPort = MIDIPortRef()
MIDIOutputPortCreate(client, "probe-out" as CFString, &outPort)

func send(_ body: [UInt8], _ label: String) {
    let msg: [UInt8] = [0xF0] + HEADER + [ID1, ID2] + body + [0xF7]
    let size = 1024
    let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { buf.deallocate() }
    let list = buf.bindMemory(to: MIDIPacketList.self, capacity: 1)
    var pkt = MIDIPacketListInit(list)
    pkt = MIDIPacketListAdd(list, size, pkt, 0, msg.count, msg)
    let err = MIDISend(outPort, destination, list)
    log("TX  \(hex(msg))\(err == noErr ? "" : "  (MIDISend error \(err))")")
    log("    → \(label)")
}

// ---- run ---------------------------------------------------------------------
log("Using DeviceID bytes \(String(format: "%02X %02X", ID1, ID2)), app name \"\(APP_NAME)\"")
send([0x7F, 0x00] + Array(APP_NAME.utf8) + [0x00], "Identification Request (spec path: 7F 00 + name)")

var ticks = 0
let keepalive = Timer(timeInterval: 3.0, repeats: true) { _ in
    ticks += 1
    send([0x00, 0x00], "System Device Notification (keepalive #\(ticks))")
}
RunLoop.main.add(keepalive, forMode: .common)

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 45 : 45
log("Listening for \(Int(duration))s — press APP on the SL88 and select \"\(APP_NAME)\"")
RunLoop.main.run(until: Date().addingTimeInterval(duration))

keepalive.invalidate()
send([0x00, 0x02], "Logout Request (clean exit)")
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
log("done")
