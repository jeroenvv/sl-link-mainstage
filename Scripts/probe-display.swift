import CoreMIDI
import Foundation

// Display + hardware I/O probe. Identifies, waits for login, then paints a real
// UI on the SL88 LCD and reacts live to buttons and encoders.
// Includes the SysEx reassembly that real hardware requires.

let APP_NAME = "SL MainStage"
let ID1: UInt8 = 0x03
let ID2: UInt8 = 0x2A
let HEADER: [UInt8] = [0x00, 0x20, 0x1A, 0x16]

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func stamp() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }
func log(_ s: String) { print("[\(stamp())] \(s)"); fflush(stdout) }
func str(_ o: MIDIObjectRef, _ p: CFString) -> String {
    var out: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(o, p, &out) == noErr, let out else { return "" }
    return out.takeRetainedValue() as String
}

// 7-bit helpers from the spec
func msbLsb(_ v: Int) -> [UInt8] { [UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)] }
struct C { let r: UInt8; let g: UInt8; let b: UInt8
    init(_ r: Int, _ g: Int, _ b: Int) { self.r = UInt8(r & 0x7F); self.g = UInt8(g & 0x7F); self.b = UInt8(b & 0x7F) }
    var bytes: [UInt8] { [r, g, b] } }

let BG      = C(4, 6, 14)
let FG      = C(127, 127, 127)
let ACCENT  = C(0, 100, 127)
let DIMTEXT = C(70, 70, 80)
let ZONE: [C] = [C(127, 40, 40), C(40, 127, 60), C(50, 70, 127), C(127, 100, 30)]

guard let (source, destination): (MIDIEndpointRef, MIDIEndpointRef) = {
    var s: MIDIEndpointRef = 0, d: MIDIEndpointRef = 0
    for i in 0..<MIDIGetNumberOfSources() {
        let e = MIDIGetSource(i)
        if str(e, kMIDIPropertyDisplayName).range(of: "LINK", options: .caseInsensitive) != nil { s = e; break }
    }
    for i in 0..<MIDIGetNumberOfDestinations() {
        let e = MIDIGetDestination(i)
        if str(e, kMIDIPropertyDisplayName).range(of: "LINK", options: .caseInsensitive) != nil { d = e; break }
    }
    return (s != 0 && d != 0) ? (s, d) : nil
}() else { log("✗ LINK endpoints not found"); exit(1) }

var client = MIDIClientRef(); MIDIClientCreate("SLDisplayProbe" as CFString, nil, nil, &client)
var outPort = MIDIPortRef(); MIDIOutputPortCreate(client, "probe-out" as CFString, &outPort)

var sent = 0
func send(_ body: [UInt8], _ label: String? = nil) {
    let msg: [UInt8] = [0xF0] + HEADER + [ID1, ID2] + body + [0xF7]
    let size = max(1024, msg.count + 64)
    let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { buf.deallocate() }
    let list = buf.bindMemory(to: MIDIPacketList.self, capacity: 1)
    var pkt = MIDIPacketListInit(list)
    pkt = MIDIPacketListAdd(list, size, pkt, 0, msg.count, msg)
    MIDISend(outPort, destination, list)
    sent += 1
    if let label { log("TX  \(label)") }
    usleep(1500)   // pace ~1 msg/ms as both reference implementations do
}

// ---- display API -------------------------------------------------------------
func clearScreen(_ c: C)          { send([0x04, 0x01] + c.bytes, "clear screen") }
func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: C, _ label: String? = nil) {
    send([0x04, 0x02] + msbLsb(x) + msbLsb(y) + msbLsb(w) + msbLsb(h) + c.bytes, label)
}
// align 0=left 1=center 2=right, size 0=small 1=medium 2=big
func text(_ s: String, _ x: Int, _ y: Int, w: Int = 0, align: UInt8 = 0, size: UInt8 = 0,
          fg: C = FG, bg: C = BG, label: String? = nil) {
    let ascii = s.unicodeScalars.map { UInt8($0.value >= 0x20 && $0.value <= 0x80 ? $0.value : 0x20) }
    send([0x04, 0x00] + msbLsb(x) + msbLsb(y) + msbLsb(w) + [align, size] + fg.bytes + bg.bytes + ascii + [0x00],
         label ?? "text \"\(s)\"")
}
func bitmap(group: UInt8, icon: UInt8, x: Int, y: Int, fg: C, bg: C) {
    send([0x04, 0x03] + msbLsb(x) + msbLsb(y) + [group, icon] + fg.bytes + bg.bytes, "bitmap g\(group)/i\(icon)")
}
func whiteLED(_ id: UInt8, _ on: Bool) { send([0x02, id, on ? 1 : 0], "white LED \(id) \(on ? "on" : "off")") }
func rgbLED(_ id: UInt8, _ c: C, _ bright: UInt8 = 0x7F) { send([0x05, id] + c.bytes + [bright], "RGB LED \(id)") }

// ---- screen state ------------------------------------------------------------
var values = [64, 64, 64, 64]
var selected = 0
let panelX = [4, 82, 160, 238], panelW = 74, panelY = 96, panelH = 76

func drawPanel(_ i: Int) {
    let x = panelX[i]
    rect(x, panelY, panelW, panelH, i == selected ? ACCENT : C(20, 22, 30), nil)
    rect(x + 2, panelY + 2, panelW - 4, panelH - 4, C(10, 12, 20), nil)
    rect(x + 6, panelY + 8, panelW - 12, 6, ZONE[i], nil)
    text("Z\(i + 1)", x, panelY + 20, w: panelW, align: 1, size: 0, fg: ZONE[i], bg: C(10, 12, 20), label: nil)
    text("\(values[i])", x, panelY + 44, w: panelW, align: 1, size: 1, fg: FG, bg: C(10, 12, 20), label: nil)
    rgbLED(UInt8(i), ZONE[i], i == selected ? 0x7F : 0x18)
}

func paintAll() {
    log("── painting screen ──")
    clearScreen(BG)
    rect(0, 0, 320, 40, C(10, 14, 28), "header bar")
    text("SL MainStage", 0, 6, w: 320, align: 1, size: 2, fg: FG, bg: C(10, 14, 28))
    text("protocol probe - turn an encoder", 0, 52, w: 320, align: 1, size: 0, fg: DIMTEXT, bg: BG)
    for i in 0..<4 { drawPanel(i) }
    text("joystick L/R selects - buttons toggle LEDs", 0, 200, w: 320, align: 1, size: 0, fg: DIMTEXT, bg: BG)
    bitmap(group: 0x03, icon: 0x00, x: 8, y: 216, fg: FG, bg: BG)
    log("── painted (\(sent) messages sent) ──")
}

// ---- inbound with reassembly -------------------------------------------------
var acc: [UInt8] = []
var ledState = [Bool](repeating: false, count: 12)

func handleFrame(_ b: [UInt8]) {
    guard b.count >= 10, Array(b[1...4]) == HEADER else { log("RX  (foreign) \(hex(b))"); return }
    let item = b[7], fn = b[8]
    let payload = Array(b.dropFirst(9).dropLast())

    switch (item, fn) {
    case (0x7F, 0x01):
        if payload.count >= 4 {
            log("RX  IDENTIFICATION APPROVED — firmware \(payload[0]).\(payload[1]).\(payload[2]), model byte \(payload[3])")
        } else { log("RX  IDENTIFICATION APPROVED (no payload)") }
    case (0x7F, 0x02): log("RX  IDENTIFICATION REJECTED reason=\(payload.first ?? 255)")
    case (0x00, 0x01), (0x00, 0x06):
        log("RX  \(fn == 1 ? "LOGIN CONFIRMATION" : "LOGIN RECALL") payload=[\(hex(payload))] → painting")
        paintAll()
    case (0x00, 0x02): log("RX  LOGOUT REQUEST → confirming"); send([0x00, 0x03], "logout confirmation")
    case (0x00, 0x04): log("RX  STANDBY")
    case (0x00, 0x05): log("RX  RESTART → repainting"); paintAll()
    case (0x03, _):    // encoder
        let tick = Int(payload.first ?? 0x40) - 0x40
        let id = Int(fn)
        log("RX  ENCODER \(id) delta \(tick > 0 ? "+" : "")\(tick)")
        if id < 4 {
            values[id] = max(0, min(127, values[id] + tick))
            selected = id
            for i in 0..<4 { drawPanel(i) }
        }
    case (0x01, _):    // button
        let evt = payload.first ?? 0
        let id = Int(fn)
        log("RX  BUTTON 0x\(String(format: "%02X", id)) \(evt == 1 ? "SHORT" : evt == 2 ? "LONG" : "evt\(evt)")")
        if id >= 0x04 && id <= 0x07 {          // zone select buttons
            let z = id - 0x04
            selected = z
            ledState[z].toggle()
            whiteLED(UInt8(z), ledState[z])
            for i in 0..<4 { drawPanel(i) }
        } else if id == 0x12 || id == 0x14 {   // joystick left / right
            selected = (selected + (id == 0x14 ? 1 : 3)) % 4
            for i in 0..<4 { drawPanel(i) }
        }
    default:
        log("RX  item=0x\(String(format: "%02X", item)) fn=0x\(String(format: "%02X", fn)) payload=[\(hex(payload))]")
    }
}

var inPort = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "probe-in" as CFString, &inPort) { pktList, _ in
    var p = pktList.pointee.packet
    for _ in 0..<pktList.pointee.numPackets {
        let len = Int(p.length)
        let bytes: [UInt8] = withUnsafeBytes(of: p.data) { Array($0.prefix(len)) }
        for byte in bytes {                      // reassembly: hardware splits frames
            if byte == 0xF0 { acc = [byte] }
            else if !acc.isEmpty {
                acc.append(byte)
                if byte == 0xF7 { let f = acc; acc = []; handleFrame(f) }
            }
        }
        p = MIDIPacketNext(&p).pointee
    }
}
MIDIPortConnectSource(inPort, source, nil)

log("✓ LINK found. Identifying as \"\(APP_NAME)\" (ID \(String(format: "%02X %02X", ID1, ID2)))")
send([0x7F, 0x00] + Array(APP_NAME.utf8) + [0x00], "identification request")

let keepalive = Timer(timeInterval: 3.0, repeats: true) { _ in send([0x00, 0x00]) }
RunLoop.main.add(keepalive, forMode: .common)

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 120 : 120
log("Listening \(Int(duration))s — press APP, select \"\(APP_NAME)\", then turn encoders / press buttons")
RunLoop.main.run(until: Date().addingTimeInterval(duration))

keepalive.invalidate()
send([0x00, 0x02], "logout request")
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
log("done — \(sent) messages sent")
