import CoreMIDI
import Foundation

// Text-metrics probe. Measures, on real hardware, what the spec contradicts itself about:
// the pixel height of Write Text's box at each SIZE, and where the Knob bitmap's hole
// actually sits inside its 61x54 bounds.
//
// The spec (sl-link/docs/display-messages.md, pinned commit 4c0824d) says BOTH:
//   table: 0x00 Small (21px) / 0x01 Medium (22px) / 0x02 Big (33px)
//   prose: "small (21px), medium (27px), big (33px)"
// Small and big agree, so they are the control: if the calipers below do not read 21 and 33
// for those, the method is wrong and the medium reading is worthless.
//
// Read the screen and report, per row, which caliper column's BOTTOM edge is flush with the
// text box's bottom edge. Session plumbing is lifted from probe-display.swift.

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
let GREEN   = C(0, 120, 0)     // caliper: 21px, the documented SIZE_SMALL height
let RED     = C(120, 0, 0)     // caliper: 27px, the spec's PROSE figure for SIZE_MEDIUM
let YELLOW  = C(120, 120, 0)   // caliper: 33px, the documented SIZE_BIG height
let BOXBG   = C(25, 45, 90)    // text box background - the rectangle being measured
let GREY    = C(60, 60, 60)
let KNOBFG  = C(127, 70, 0)

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
         label ?? "text \"\(s)\" x=\(x) y=\(y) w=\(w) size=\(size)")
}
func bitmap(group: UInt8, icon: UInt8, x: Int, y: Int, fg: C, bg: C) {
    send([0x04, 0x03] + msbLsb(x) + msbLsb(y) + [group, icon] + fg.bytes + bg.bytes, "bitmap g\(group)/i\(icon) x=\(x) y=\(y)")
}

// ---- geometry ----------------------------------------------------------------
// Agreed layout. Nothing may exceed y=239: a clipped row is indistinguishable from a short
// glyph box, which would silently corrupt the measurement.
let TITLE_Y   = 2
let ROW_Y     = [26, 66, 106]          // SIZE_SMALL, SIZE_MEDIUM, SIZE_BIG
let ROW_LABEL = ["Hg S", "Hg M", "Hg B"]
let CAL_X     = [40, 62, 84]           // green / red / yellow columns
let CAL_H     = [21, 27, 33]
let CAL_C     = [GREEN, RED, YELLOW]
let CAL_W     = 18
let BOX_X     = 110
let BOX_W     = 190
let KNOB_Y    = 150                    // + BMP_ICON_H (54) = 204
let KNOB_L_X  = 40                     // left icon, carries the 38-wide value box
let KNOB_R_X  = 180                    // right icon, carries the 45-wide value box
let ICON_W    = 61
let ICON_H    = 54
let LADDER_X  = 120
let VALUE_BOX_Y = KNOB_Y + 16           // neutral y - this row answers WIDTH only
let FOOTER_Y  = 210                    // + 21 = 231

func paintAll() {
    log("── painting text-metrics screen ──")
    clearScreen(BLACK)
    text("TEXT METRICS PROBE", 0, TITLE_Y, w: 320, align: 1, size: 0, fg: DIMTEXT, bg: BLACK)

    // Three rows: caliper columns whose TOPS align with the text box's top, so the answer is
    // "which column's bottom edge is flush with the box's bottom edge".
    for (row, y) in ROW_Y.enumerated() {
        for i in 0..<3 {
            rect(CAL_X[i], y, CAL_W, CAL_H[i], CAL_C[i], "caliper row\(row) \(CAL_H[i])px")
        }
        // Non-zero maxWidth on purpose: Write Text's opaque background box then fills the whole
        // width, giving a clean rectangle of known width and UNKNOWN height - the measurement.
        // 'Hg' carries an ascender and a descender, so ink sitting high inside the box shows up
        // as asymmetric padding instead of being guessed at.
        text(ROW_LABEL[row], BOX_X, y, w: BOX_W, align: 1, size: UInt8(row), fg: WHITE, bg: BOXBG)
    }

    // Knob row. Two copies of the same icon; the ladder between them reads off where the ring's
    // hole starts and ends, the two boxes answer whether 38 or 45 fits inside it.
    bitmap(group: 0x00, icon: 0x0C, x: KNOB_L_X, y: KNOB_Y, fg: KNOBFG, bg: BLACK)
    bitmap(group: 0x00, icon: 0x0C, x: KNOB_R_X, y: KNOB_Y, fg: KNOBFG, bg: BLACK)
    // Ladder: 1px rules every 6px down the icon's height. Long+white every 12px (0,12,24,36,48),
    // short+grey on the odd 6px steps, so the rules can be counted rather than estimated.
    for step in 0...9 {
        let dy = step * 6
        let major = dy % 12 == 0
        rect(LADDER_X, KNOB_Y + dy, major ? 14 : 8, 1, major ? WHITE : GREY, "ladder +\(dy)")
    }
    // Both boxes at the same y - white background so the box's edges are unmistakable against
    // the ring. Drawn AFTER the icons so the box is on top, which is what the real popup does.
    text("188", KNOB_L_X + (ICON_W - 38) / 2, VALUE_BOX_Y, w: 38, align: 1, size: 1, fg: BLACK, bg: WHITE,
         label: "value box w=38")
    text("188", KNOB_R_X + (ICON_W - 45) / 2, VALUE_BOX_Y, w: 45, align: 1, size: 1, fg: BLACK, bg: WHITE,
         label: "value box w=45")

    text("G21 R27 Y33  ticks 6px  boxes 38/45", 0, FOOTER_Y, w: 320, align: 1, size: 0, fg: DIMTEXT, bg: BLACK)
    log("── painted (\(sent) messages sent) ──")
    log("READ: per row, which caliper column's BOTTOM edge is flush with the text box's bottom edge?")
    log("      rows drawn at y=\(ROW_Y) for SIZE_SMALL/MEDIUM/BIG; calipers \(CAL_H) px at x=\(CAL_X)")
    log("      knob icons at y=\(KNOB_Y) (x=\(KNOB_L_X), \(KNOB_R_X)); ladder x=\(LADDER_X), rules every 6px from y=\(KNOB_Y)")
    log("      value boxes w=38 (left) and w=45 (right) at y=\(VALUE_BOX_Y) - do either box's sides poke through the ring?")
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
        log("RX  \(fn == 1 ? "LOGIN CONFIRMATION" : "LOGIN RECALL") payload=[\(hex(payload))] → painting")
        paintAll()
    case (0x00, 0x02): log("RX  LOGOUT REQUEST → confirming"); send([0x00, 0x03], "logout confirmation")
    case (0x00, 0x04): log("RX  STANDBY")
    case (0x00, 0x05): log("RX  RESTART → repainting"); paintAll()
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

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 300 : 300
log("Listening \(Int(duration))s — press APP, select \"\(APP_NAME)\", then read the screen")
RunLoop.main.run(until: Date().addingTimeInterval(duration))

keepalive.invalidate()
send([0x00, 0x02], "logout request")
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
log("done — \(sent) messages sent")
