import CoreMIDI
import Foundation

// Standalone Master Volume (item 0x07) test bed, independent of MainStage.
// Identifies, waits for a real Login Confirmation, then runs a scripted
// read/write/read-back sequence and prints a verdict table — see
// docs/mainstage-integration.md "Master Volume" sections for what this is
// chasing and what has already been ruled out.

var APP_NAME = "SL MVol Probe"
let ID1: UInt8 = 0x03
var ID2: UInt8 = 0x2B   // distinct from probe-sllink.swift's 0x2A
let HEADER: [UInt8] = [0x00, 0x20, 0x1A, 0x16]
var duration: Double = 90
var pauseMs: Double = 500
var waitForLogin = true
let loginTimeout: Double = 25

var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--duration": if let v = args.next(), let d = Double(v) { duration = d }
    case "--app-name": if let v = args.next() { APP_NAME = v }
    case "--id2": if let v = args.next(), let b = UInt8(v, radix: 16) { ID2 = b }
    case "--pause-ms": if let v = args.next(), let p = Double(v) { pauseMs = p }
    case "--no-login-wait": waitForLogin = false
    default: print("unknown option \(a), ignoring")
    }
}
let pauseSeconds = pauseMs / 1000.0

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
    case (0x07, 0x00):
        if payload.isEmpty {
            what = "MASTER VOLUME READ REQUEST"
        } else {
            let vol = Int(payload[0])
            let muteStr = payload.count > 1 ? " mute=\(payload[1])" : ""
            what = "MASTER VOLUME READ REPLY vol=\(vol)\(muteStr)"
        }
    case (0x07, 0x01):
        let vol = payload.first.map { "\($0)" } ?? "?"
        let muteStr = payload.count > 1 ? " mute=\(payload[1])" : ""
        what = "MASTER VOLUME WRITE vol=\(vol)\(muteStr)"
    default:
        what = "item=0x\(String(format: "%02X", item)) fn=0x\(String(format: "%02X", fn)) payload=\(hex(payload))"
    }
    return "\(what)  [\(idNote)]"
}

// One decoded Master Volume (item 0x07) reply, addressed to us, captured for the sequence runner.
struct MVCapture { let kind: String; let vol: Int?; let mute: Int? }

func mvCapture(from b: [UInt8]) -> MVCapture? {
    guard b.count >= 9, b[0] == 0xF0, Array(b[1...4]) == HEADER,
          b[5] == ID1, b[6] == ID2, b[7] == 0x07 else { return nil }
    let fn = b[8]
    let payload = Array(b.dropFirst(9).dropLast())
    switch fn {
    case 0x00 where payload.isEmpty:
        return MVCapture(kind: "READ REQUEST", vol: nil, mute: nil)
    case 0x00:
        return MVCapture(kind: "READ REPLY", vol: Int(payload[0]), mute: payload.count > 1 ? Int(payload[1]) : nil)
    case 0x01:
        return MVCapture(kind: "WRITE", vol: payload.first.map(Int.init), mute: payload.count > 1 ? Int(payload[1]) : nil)
    default:
        return MVCapture(kind: "OTHER fn=0x\(String(format: "%02X", fn))", vol: nil, mute: nil)
    }
}

var loginConfirmed = false
var lastMV: MVCapture? = nil

// ---- SysEx reassembly ---------------------------------------------------------
// CoreMIDI delivers each SL Link frame split across multiple packets/callbacks (confirmed on
// hardware: header bytes in one packet, the rest in the next). decode()/mvCapture()/the login
// check all require a complete F0..F7 frame, so accumulate bytes here and only dispatch on F7.
var recvBuffer: [UInt8] = []
let recvBufferCap = 512 // guard: reset if F7 never arrives instead of growing forever

func dispatchFrame(_ frame: [UInt8]) {
    log("RX  \(hex(frame))")
    log("    → \(decode(frame))")
    if frame.count >= 9, frame[5] == ID1, frame[6] == ID2, frame[7] == 0x00, frame[8] == 0x01 {
        loginConfirmed = true
    }
    if let cap = mvCapture(from: frame) { lastMV = cap }
}

func feedReassembly(_ bytes: [UInt8]) {
    for b in bytes {
        if b == 0xF0 {
            recvBuffer = [b] // start of a frame - drop any unterminated partial we were holding
        } else if !recvBuffer.isEmpty {
            recvBuffer.append(b)
            if b == 0xF7 {
                dispatchFrame(recvBuffer)
                recvBuffer.removeAll(keepingCapacity: true)
            } else if recvBuffer.count > recvBufferCap {
                log("⚠️ RX buffer exceeded \(recvBufferCap) bytes without F7 - discarding")
                recvBuffer.removeAll(keepingCapacity: true)
            }
        }
        // bytes before the first 0xF0 we've seen are stray and dropped
    }
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
MIDIClientCreate("SLMasterVolumeProbe" as CFString, nil, nil, &client)

var inPort = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "probe-in" as CFString, &inPort) { pktList, _ in
    var p = pktList.pointee.packet
    for _ in 0..<pktList.pointee.numPackets {
        let len = Int(p.length)
        let bytes: [UInt8] = withUnsafeBytes(of: p.data) { Array($0.prefix(len)) }
        feedReassembly(bytes)
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

func runLoopWait(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

// ---- on-screen progress --------------------------------------------------------
// The user stands at the keyboard with no view of stdout - mirror progress onto the SL88's
// own display. Byte layout copied from config.lua's msg_write_text (Display/Write Text).
let IT_DISPLAY: UInt8 = 0x04
let DISP_WRITE_TEXT: UInt8 = 0x00
let ALIGN_LEFT: UInt8 = 0x00
let SIZE_SMALL: UInt8 = 0x00
let SIZE_MEDIUM: UInt8 = 0x01
let SCREEN_WIDTH = 320
let TEXT_X = 8
let TEXT_MAXW = SCREEN_WIDTH - (2 * TEXT_X)
let TITLE_Y = 10
let STATUS_Y = 70
let RESULT_Y = 105
let VERDICT_Y = 165
let DRAW_PAUSE = 0.1

func appendMsbLsb(_ msg: inout [UInt8], _ value: Int) {
    let v = max(0, value)
    msg.append(UInt8((v / 128) % 128))
    msg.append(UInt8(v % 128))
}
func appendRGB(_ msg: inout [UInt8], _ r: Int, _ g: Int, _ b: Int) {
    msg.append(UInt8(r / 2)); msg.append(UInt8(g / 2)); msg.append(UInt8(b / 2))
}
// ASCII-clamps and 0x00-terminates, same as config.lua's append_text.
func appendText(_ msg: inout [UInt8], _ text: String, maxLength: Int) {
    let bytes = Array(text.utf8)
    for i in 0..<min(bytes.count, maxLength) {
        let b = bytes[i]
        msg.append((b < 0x20 || b > 0x80) ? 0x20 : b)
    }
    msg.append(0x00)
}

func msgWriteText(_ text: String, x: Int, y: Int, maxWidth: Int, size: UInt8) -> [UInt8] {
    var m: [UInt8] = [IT_DISPLAY, DISP_WRITE_TEXT]
    appendMsbLsb(&m, x)
    appendMsbLsb(&m, y)
    appendMsbLsb(&m, maxWidth)
    m.append(ALIGN_LEFT)
    m.append(size)
    appendRGB(&m, 255, 255, 255) // white text
    appendRGB(&m, 0, 0, 0)       // black background - also erases the region, no Clear Screen needed
    appendText(&m, text, maxLength: 40)
    return m
}

// One fixed, non-overlapping region per line so a redraw only touches its own line.
func drawTitle(_ text: String) {
    send(msgWriteText(text, x: TEXT_X, y: TITLE_Y, maxWidth: TEXT_MAXW, size: SIZE_MEDIUM), "Draw Text: title")
    runLoopWait(DRAW_PAUSE)
}
func drawStatus(_ text: String) {
    send(msgWriteText(text, x: TEXT_X, y: STATUS_Y, maxWidth: TEXT_MAXW, size: SIZE_SMALL), "Draw Text: status")
    runLoopWait(DRAW_PAUSE)
}
func drawResult(_ text: String) {
    send(msgWriteText(text, x: TEXT_X, y: RESULT_Y, maxWidth: TEXT_MAXW, size: SIZE_SMALL), "Draw Text: result")
    runLoopWait(DRAW_PAUSE)
}
func drawVerdict(_ text: String) {
    send(msgWriteText(text, x: TEXT_X, y: VERDICT_Y, maxWidth: TEXT_MAXW, size: SIZE_MEDIUM), "Draw Text: verdict")
    runLoopWait(DRAW_PAUSE)
}

// ---- identify + keepalive -----------------------------------------------------
log("Using DeviceID bytes \(String(format: "%02X %02X", ID1, ID2)), app name \"\(APP_NAME)\"")
send([0x7F, 0x00] + Array(APP_NAME.utf8) + [0x00], "Identification Request (spec path: 7F 00 + name)")
drawTitle(APP_NAME)

var ticks = 0
let keepalive = Timer(timeInterval: 3.0, repeats: true) { _ in
    ticks += 1
    send([0x00, 0x00], "System Device Notification (keepalive #\(ticks))")
}
RunLoop.main.add(keepalive, forMode: .common)

let startTime = Date()
func remaining() -> Double { duration - (-startTime.timeIntervalSinceNow) }

// ---- wait for a real Login Confirmation before touching Master Volume ---------
if waitForLogin {
    log("")
    log(">>> Waiting up to \(Int(loginTimeout))s for a System Login Confirmation.")
    log(">>> On the SL88, press APP and select \"\(APP_NAME)\" now. <<<")
    drawStatus("Waiting for login - press APP")
    let deadline = Date().addingTimeInterval(loginTimeout)
    while !loginConfirmed && Date() < deadline { runLoopWait(0.25) }
    if loginConfirmed {
        log("✓ Login confirmed — running the sequence in the logged-in state.")
        drawStatus("Logged in - running sequence")
    } else {
        log("✗ No Login Confirmation within \(Int(loginTimeout))s — running the sequence anyway, in the UN-LOGGED-IN state (labelled accordingly below).")
        drawStatus("No login - running anyway")
    }
} else {
    log("--no-login-wait given — skipping the wait, running the sequence immediately.")
    drawStatus("Skipping login wait")
}

// ---- scripted sequence ----------------------------------------------------------
struct Op { let step: Int; let label: String; let isRead: Bool; let sentVol: Int?; let replied: Bool; let repliedVol: Int?; let repliedMute: Int?; let isNegativeControl: Bool }
var ops: [Op] = []
var stepNum = 0

@discardableResult
func doOp(_ label: String, display: String, isRead: Bool, sentVol: Int?, body: [UInt8], txLabel: String, isNegativeControl: Bool = false) -> Op {
    stepNum += 1
    log("")
    log("=== Step \(stepNum): \(label) ===")
    drawStatus("Step \(stepNum): \(display)")
    lastMV = nil
    send(body, txLabel)
    runLoopWait(pauseSeconds)
    let cap = lastMV
    let op = Op(step: stepNum, label: label, isRead: isRead, sentVol: sentVol,
                replied: cap != nil, repliedVol: cap?.vol, repliedMute: cap?.mute,
                isNegativeControl: isNegativeControl)
    ops.append(op)
    log(cap != nil ? "    ← 0x07 reply: \(cap!.kind) vol=\(cap!.vol.map{"\($0)"} ?? "-") mute=\(cap!.mute.map{"\($0)"} ?? "-")"
                   : "    ← no 0x07 reply within \(Int(pauseSeconds * 1000))ms")
    if isRead {
        drawResult(cap?.vol.map { "read -> \($0)" } ?? "read -> no reply")
    } else if let sv = sentVol {
        drawResult("wrote vol=\(sv)")
    }
    return op
}

// Step A — bare read.
doOp("bare read (07 00)", display: "bare read", isRead: true, sentVol: nil,
     body: [0x07, 0x00], txLabel: "Master Volume Read Request (bare)")

// Step B — write then read back, for a few volumes.
if remaining() > 4 {
    for vol in [20, 60, 90] {
        doOp("write vol=\(vol) (07 01 \(vol))", display: "write vol=\(vol)", isRead: false, sentVol: vol,
             body: [0x07, 0x01, UInt8(vol)], txLabel: "Master Volume Write vol=\(vol)")
        doOp("read after write vol=\(vol) (07 00)", display: "read after write \(vol)", isRead: true, sentVol: nil,
             body: [0x07, 0x00], txLabel: "Master Volume Read Request (after write \(vol))")
    }
} else {
    log("⚠️ time budget low — skipping Step B")
}

// Step C — shape variants on record as untested-or-failed, each followed by a read-back.
if remaining() > 3 {
    let c1vol = 45
    doOp("write vol=\(c1vol) with explicit mute=0 (07 01 \(c1vol) 00)", display: "write \(c1vol) mute=0", isRead: false, sentVol: c1vol,
         body: [0x07, 0x01, UInt8(c1vol), 0x00], txLabel: "Master Volume Write vol=\(c1vol) mute=0 (explicit MUTE variant)")
    doOp("read after write (07 00)", display: "read after C1", isRead: true, sentVol: nil,
         body: [0x07, 0x00], txLabel: "Master Volume Read Request (after C1 write)")

    let c2vol = 55
    doOp("device-reply-shape write attempt vol=\(c2vol) (07 00 \(c2vol) 00)", display: "07-00-shape write \(c2vol)", isRead: false, sentVol: c2vol,
         body: [0x07, 0x00, UInt8(c2vol), 0x00],
         txLabel: "Master Volume '07 00' shape write attempt vol=\(c2vol) (known reply shape, tried only for completeness)",
         isNegativeControl: true)
    doOp("read after write (07 00)", display: "read after C2", isRead: true, sentVol: nil,
         body: [0x07, 0x00], txLabel: "Master Volume Read Request (after C2 write)")
} else {
    log("⚠️ time budget low — skipping Step C")
}

// ---- verdict summary ------------------------------------------------------------
func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s + " " : s + String(repeating: " ", count: w - s.count) }

log("")
log(String(repeating: "=", count: 62))
log("VERDICT SUMMARY")
log(String(repeating: "=", count: 62))
log(pad("Step", 6) + pad("Sent", 46) + pad("Replied", 9) + "VOL")
for op in ops {
    log(pad("\(op.step)", 6) + pad(op.label, 46) + pad(op.replied ? "yes" : "no", 9) + (op.repliedVol.map { "\($0)" } ?? "-"))
}

let reads = ops.filter { $0.isRead }
let readsAnswered = reads.filter { $0.replied }.count
// Genuine writes (07 01 ...) count toward the pass/fail headline. The 07-00-shape attempt is a
// deliberate negative control — it is EXPECTED not to write, so it's judged separately: it passes
// when the read-back matches the read BEFORE it (unchanged), not when it matches the sent value.
var writeTotal = 0, writeConfirmed = 0
var negControlOp: Op? = nil
var negControlPassed = false
for i in 0..<ops.count {
    let op = ops[i]
    if !op.isRead, let sv = op.sentVol, i + 1 < ops.count, ops[i + 1].isRead {
        if op.isNegativeControl {
            let priorVol = i > 0 ? ops[i - 1].repliedVol : nil
            negControlOp = op
            negControlPassed = ops[i + 1].replied && priorVol != nil && ops[i + 1].repliedVol == priorVol
        } else {
            writeTotal += 1
            if ops[i + 1].replied && ops[i + 1].repliedVol == sv { writeConfirmed += 1 }
        }
    }
}

log("")
log("Logged in during sequence: \(loginConfirmed ? "yes" : "no")")
log("Reads answered: \(readsAnswered)/\(reads.count) — read \(readsAnswered > 0 ? "answered" : "never answered")")
log("Writes confirmed by matching read-back: \(writeConfirmed)/\(writeTotal) — write \(writeConfirmed > 0 ? "took effect at least once" : "did not take effect")")
if let negOp = negControlOp {
    log("Negative control (\(negOp.label)): \(negControlPassed ? "PASS — value did not change, as expected" : "FAIL — value changed unexpectedly")")
}
if !loginConfirmed { log("NOTE: sequence ran in the UN-LOGGED-IN state — treat the above as that condition's result, not a general verdict.") }

let readsOK = reads.count > 0 && readsAnswered == reads.count
let writesOK = writeTotal > 0 && writeConfirmed == writeTotal
var headline = readsOK ? "READS OK" : "READS FAIL"
headline += " / " + (writesOK ? "WRITES OK" : "WRITES FAIL")
if !loginConfirmed { headline += " [unlogged]" }
drawVerdict(headline)

// ---- clean shutdown ---------------------------------------------------------------
keepalive.invalidate()
send([0x00, 0x02], "Logout Request (clean exit)")
runLoopWait(1.0)
log("done")
