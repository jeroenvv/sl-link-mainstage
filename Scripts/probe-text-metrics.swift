import CoreMIDI
import Foundation

// Interactive text/bitmap metrics caliper for the SL88 MK2.
//
// Round 1 of this probe asked for flush-edge judgements against fixed 21/27/33px caliper bars
// and established that all three of the spec's figures are too large (small < 21, medium ~21,
// big ~27), but 1px resolution and the ring hole were "hard to see". So the keyboard measures
// itself here instead: every quantity is driven by an encoder until the screen shows an
// unambiguous binary signal, and the probe prints the number.
//
// MODE A - TEXT BOX HEIGHT (the seam test)
//   Three copies of the same string are stacked exactly H apart, in alternating background
//   colours. Write Text's background box fills its whole maxWidth, so each copy paints a solid
//   rectangle whose height is what we want:
//     H too big   -> black seams between the stripes
//     H too small -> earlier stripes are clipped to H; the LAST stripe looks thicker
//     H exact     -> continuous block, all stripes equal, no seam
//   Turn encoder 1 until that holds. Zone 1/2/3 buttons pick SIZE_SMALL/MEDIUM/BIG.
//
// MODE B - KNOB HOLE (the real popup box)
//   Draws the Knob bitmap and, on top of it, the actual Write Text box config.lua paints inside
//   the ring ('188', SIZE_MEDIUM, opaque background). Turn encoder 1 for its maxWidth and
//   encoder 4 for its y offset until the white box sits entirely inside the hole and touches
//   nothing. Those two numbers are POPUP_VALUE_W and the value box's offset from the icon top.
//
//   ZOOM button toggles A/B. Joystick press prints a snapshot line.
//
// Session plumbing is lifted from probe-display.swift.

let APP_NAME = "SL MainStage"
let ID1: UInt8 = 0x03
let ID2: UInt8 = 0x2B
let HEADER: [UInt8] = [0x00, 0x20, 0x1A, 0x16]

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func stamp() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }
func log(_ s: String) { print("[\(stamp())] \(s)"); fflush(stdout) }
func str(_ o: MIDIObjectRef, _ p: CFString) -> String {
    var out: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(o, p, &out) == noErr, let out else { return "" }
    return out.takeRetainedValue() as String
}

// 7-bit helpers from the spec. NOTE: C() masks to 0x7F, so every colour component must be
// 0-127 - a literal like 220 would silently become 92.
func msbLsb(_ v: Int) -> [UInt8] { [UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)] }
struct C { let r: UInt8; let g: UInt8; let b: UInt8
    init(_ r: Int, _ g: Int, _ b: Int) { self.r = UInt8(r & 0x7F); self.g = UInt8(g & 0x7F); self.b = UInt8(b & 0x7F) }
    var bytes: [UInt8] { [r, g, b] } }

let BLACK   = C(0, 0, 0)
let WHITE   = C(127, 127, 127)
let DIMTEXT = C(70, 70, 80)
let STRIPE_A = C(20, 50, 110)   // alternating stripe backgrounds - a black seam between them
let STRIPE_B = C(0, 90, 60)     // is the signal that H is too large
let KNOBFG  = C(127, 70, 0)

// ---- endpoints ---------------------------------------------------------------
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
}() else { log("✗ LINK endpoints not found - is MainStage still running and holding the port?"); exit(1) }

var client = MIDIClientRef(); MIDIClientCreate("SLTextMetricsProbe" as CFString, nil, nil, &client)
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
func clearScreen(_ c: C) { send([0x04, 0x01] + c.bytes, "clear screen") }
func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: C, _ label: String? = nil) {
    send([0x04, 0x02] + msbLsb(x) + msbLsb(y) + msbLsb(w) + msbLsb(h) + c.bytes, label)
}
// align 0=left 1=center 2=right, size 0=small 1=medium 2=big
func text(_ s: String, _ x: Int, _ y: Int, w: Int = 0, align: UInt8 = 0, size: UInt8 = 0,
          fg: C = WHITE, bg: C = BLACK, label: String? = nil) {
    let ascii = s.unicodeScalars.map { UInt8($0.value >= 0x20 && $0.value <= 0x80 ? $0.value : 0x20) }
    send([0x04, 0x00] + msbLsb(x) + msbLsb(y) + msbLsb(w) + [align, size] + fg.bytes + bg.bytes + ascii + [0x00],
         label)
}
func bitmap(group: UInt8, icon: UInt8, x: Int, y: Int, fg: C, bg: C) {
    send([0x04, 0x03] + msbLsb(x) + msbLsb(y) + [group, icon] + fg.bytes + bg.bytes, nil)
}

// ---- geometry ----------------------------------------------------------------
let WORK_Y = 30, WORK_H = 152          // scratch band both modes repaint; 30..182
let STRIPE_X = 60, STRIPE_W = 200
let STRIPE_Y = 40
let ICON_W = 61, ICON_H = 54
let KNOB_X = 130, KNOB_Y = 60          // 130..191, 60..114
let READ1_Y = 188, READ2_Y = 212       // two readout lines, SIZE_SMALL, opaque full width

// ---- state -------------------------------------------------------------------
var mode = 0                            // 0 = text height, 1 = knob hole
var sizeSel = 1                         // 0 small, 1 medium, 2 big
var stripeH = [19, 21, 27]              // per-size candidate, seeded from round 1's readings
var boxW = 38                           // POPUP_VALUE_W candidate
var boxDY = 16                          // value box offset from the icon's top
var boxDX = -1                          // -1 = keep centred on the icon
let SIZE_NAME = ["SMALL", "MEDIUM", "BIG"]

func centredDX() -> Int { (ICON_W - boxW) / 2 }

func readout(_ line1: String, _ line2: String) {
    // Full-width opaque boxes, so each new readout erases the previous one.
    text(line1, 0, READ1_Y, w: 320, align: 1, size: 0, fg: WHITE, bg: BLACK, label: nil)
    text(line2, 0, READ2_Y, w: 320, align: 1, size: 0, fg: DIMTEXT, bg: BLACK, label: nil)
}

func paintTextMode() {
    rect(0, WORK_Y, 320, WORK_H, BLACK, nil)
    let h = stripeH[sizeSel]
    // Drawn top to bottom on purpose: if h is smaller than the real box height, each stripe
    // clips the one above it and the LAST stripe is left visibly thicker.
    for i in 0..<3 {
        text("Hg 123", STRIPE_X, STRIPE_Y + i * h, w: STRIPE_W, align: 1, size: UInt8(sizeSel),
             fg: WHITE, bg: i % 2 == 0 ? STRIPE_A : STRIPE_B, label: nil)
    }
    readout("A  \(SIZE_NAME[sizeSel])  H=\(h)",
            "E1 turns H - no seam, equal stripes. Z1/2/3 size, ZOOM mode")
    log("MODE A  size=\(SIZE_NAME[sizeSel]) H=\(h)  (stripes at y=\(STRIPE_Y), \(STRIPE_Y + h), \(STRIPE_Y + 2 * h))")
}

func paintKnobMode() {
    rect(0, WORK_Y, 320, WORK_H, BLACK, nil)
    bitmap(group: 0x00, icon: 0x0C, x: KNOB_X, y: KNOB_Y, fg: KNOBFG, bg: BLACK)
    let dx = boxDX < 0 ? centredDX() : boxDX
    // The real thing config.lua paints inside the ring: Write Text, opaque background, SIZE_MEDIUM.
    text("188", KNOB_X + dx, KNOB_Y + boxDY, w: boxW, align: 1, size: 1, fg: BLACK, bg: WHITE, label: nil)
    readout("B  w=\(boxW)  dy=\(boxDY)  dx=\(dx)\(boxDX < 0 ? " (auto)" : "")",
            "E1 w, E4 dy, E3 dx - box inside the ring, touching nothing")
    log("MODE B  w=\(boxW) dy=\(boxDY) dx=\(dx)\(boxDX < 0 ? " (auto-centred)" : "")  box at x=\(KNOB_X + dx) y=\(KNOB_Y + boxDY)")
}

func paintAll() {
    log("── painting ──")
    clearScreen(BLACK)
    text("TEXT METRICS CALIPER", 0, 4, w: 320, align: 1, size: 0, fg: DIMTEXT, bg: BLACK, label: nil)
    repaint()
}

func repaint() { mode == 0 ? paintTextMode() : paintKnobMode() }

func snapshot() {
    log("SNAPSHOT  small=\(stripeH[0])px  medium=\(stripeH[1])px  big=\(stripeH[2])px  |  "
        + "POPUP_VALUE_W=\(boxW)  value box dy=\(boxDY) dx=\(boxDX < 0 ? centredDX() : boxDX)")
}

// ---- inbound with reassembly -------------------------------------------------
var acc: [UInt8] = []

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
        log("RX  \(fn == 1 ? "LOGIN CONFIRMATION" : "LOGIN RECALL") → painting")
        paintAll()
    case (0x00, 0x02): log("RX  LOGOUT REQUEST → confirming"); send([0x00, 0x03], "logout confirmation")
    case (0x00, 0x04): log("RX  STANDBY")
    case (0x00, 0x05): log("RX  RESTART → repainting"); paintAll()

    case (0x03, _):    // encoder: payload is 0x40-relative, multi-step when turned fast
        let delta = Int(payload.first ?? 0x40) - 0x40
        guard delta != 0 else { return }
        switch (mode, Int(fn)) {
        case (0, 0x00): stripeH[sizeSel] = max(6, min(48, stripeH[sizeSel] + delta)); repaint()
        case (1, 0x00): boxW = max(6, min(ICON_W, boxW + delta)); repaint()
        case (1, 0x03): boxDY = max(0, min(ICON_H - 4, boxDY + delta)); repaint()
        case (1, 0x02): boxDX = max(0, min(ICON_W - 4, (boxDX < 0 ? centredDX() : boxDX) + delta)); repaint()
        default: log("RX  ENCODER \(fn) delta \(delta) (unbound in mode \(mode == 0 ? "A" : "B"))")
        }

    case (0x01, _):    // button
        let evt = payload.first ?? 0
        guard evt == 1 || evt == 2 else { return }   // SHORT or LONG only
        switch Int(fn) {
        case 0x10: mode = 1 - mode; log("MODE → \(mode == 0 ? "A (text height)" : "B (knob hole)")"); repaint()
        case 0x04, 0x05, 0x06:
            guard mode == 0 else { return }
            sizeSel = Int(fn) - 0x04; repaint()
        case 0x15: snapshot()
        case 0x02:
            guard mode == 1 else { return }
            boxDX = -1; log("dx → auto-centred"); repaint()
        default: log("RX  BUTTON 0x\(String(format: "%02X", fn)) \(evt == 1 ? "SHORT" : "LONG") (unbound)")
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

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 600 : 600
log("Listening \(Int(duration))s — press APP, select \"\(APP_NAME)\"")
log("MODE A: encoder 1 turns H; Zone 1/2/3 pick size. ZOOM switches mode. Joystick press = snapshot.")
log("MODE B: encoder 1 = box width, encoder 4 = y offset, encoder 3 = x offset, Z3 encoder press = re-centre.")
RunLoop.main.run(until: Date().addingTimeInterval(duration))

keepalive.invalidate()
send([0x00, 0x02], "logout request")
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
snapshot()
log("done — \(sent) messages sent")
