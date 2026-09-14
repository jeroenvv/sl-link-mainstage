import CoreMIDI
import Foundation

// Standalone Master Volume MUTE-byte and White LED (item 0x02) test bed, independent of
// MainStage. Two spec-correct forms fail on this SL88 (fw 1.1.2): "07 01 <vol> <mute>" and
// "07 01 7F <mute>" are both ignored, and "02 0A 01" (A encoder LED on) blanks the display.
// This probe hunts for a working mute form using the READ reply (07 00 <VOL> <MUTE>) as an
// objective oracle, then characterises the LED message with paced, screen-labelled steps for a
// human watching the device (no stdin - this runs from an automated shell with no terminal, and
// readLine() previously just returned instantly with nothing captured). Phase C reproduces
// config.lua's flush_pending() [message, query] send shape to test whether pairing a mute write
// with a trailing Identification Query is what makes MainStage's own mute writes get ignored.
// Modelled closely on probe-mastervolume.swift - same endpoint discovery, identification,
// keepalive, SysEx reassembly, login wait and on-screen status mirroring.

var APP_NAME = "SL Mute/LED Probe"
let ID1: UInt8 = 0x03
var ID2: UInt8 = 0x2C   // distinct from probe-sllink.swift's 0x2A and probe-mastervolume.swift's 0x2B
let HEADER: [UInt8] = [0x00, 0x20, 0x1A, 0x16]
var duration: Double = 180
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

// One decoded Master Volume (item 0x07) reply, addressed to us - the oracle every mute attempt
// is judged against, since a mute state has no other observable signal in a log.
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
// hardware). decode()/mvCapture()/the login check all require a complete F0..F7 frame, so
// accumulate bytes here and only dispatch on F7.
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
MIDIClientCreate("SLMuteLEDProbe" as CFString, nil, nil, &client)

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
// own display. Byte layout copied from config.lua's msg_write_text/msg_draw_rect.
let IT_DISPLAY: UInt8 = 0x04
let IT_LED: UInt8 = 0x02
let DISP_WRITE_TEXT: UInt8 = 0x00
let DISP_DRAW_RECT: UInt8 = 0x02
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
let RECT_X = 40, RECT_Y = 190, RECT_W = 240, RECT_H = 40 // Phase B marker - below every text line
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
func msgDrawRect(x: Int, y: Int, w: Int, h: Int, r: Int, g: Int, b: Int) -> [UInt8] {
    var m: [UInt8] = [IT_DISPLAY, DISP_DRAW_RECT]
    appendMsbLsb(&m, x)
    appendMsbLsb(&m, y)
    appendMsbLsb(&m, w)
    appendMsbLsb(&m, h)
    appendRGB(&m, r, g, b)
    return m
}
func msgWhiteLed(_ wlid: UInt8, _ on: Bool) -> [UInt8] { [IT_LED, wlid, on ? 1 : 0] }

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
// Phase B's recognisable marker - a solid amber block distinct from any text region.
func drawMarker() {
    send(msgDrawRect(x: RECT_X, y: RECT_Y, w: RECT_W, h: RECT_H, r: 255, g: 180, b: 0), "Draw Rect: LED-test marker")
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

// =============================================================================
// Phase A — find a working mute form, using the READ reply as the oracle.
// =============================================================================
struct ReadResult { let vol: Int?; let mute: Int? }

// Sends body, then issues a bare READ and waits for its reply. Every mute attempt is judged
// this way - never by ear.
@discardableResult
func writeThenRead(_ body: [UInt8], _ label: String) -> ReadResult {
    lastMV = nil
    send(body, label)
    runLoopWait(pauseSeconds)
    lastMV = nil
    send([0x07, 0x00], "Master Volume Read Request (oracle for: \(label))")
    runLoopWait(pauseSeconds)
    return ReadResult(vol: lastMV?.vol, mute: lastMV?.mute)
}

func fmtResult(_ r: ReadResult) -> String {
    "vol=\(r.vol.map { "\($0)" } ?? "-") mute=\(r.mute.map { "\($0)" } ?? "-")"
}

struct MuteAttempt {
    let candidate: String
    let direction: String   // "mute" or "unmute"
    let sent: [UInt8]
    let result: ReadResult
    let expectedNonzeroMute: Bool
    var passed: Bool {
        guard let m = result.mute else { return false }
        return expectedNonzeroMute ? (m != 0) : (m == 0)
    }
}
var attempts: [MuteAttempt] = []

log("")
log(String(repeating: "=", count: 70))
log("PHASE A — hunting a working mute form (oracle: 07 00 READ reply's MUTE byte)")
log(String(repeating: "=", count: 70))

// Step 0 — baseline: known volume via the confirmed-working plain 3-byte write.
let baselineVol = 60 // 0x3C
drawTitle("Phase A: baseline")
drawStatus("Write vol=\(baselineVol), read back")
let baseline = writeThenRead([0x07, 0x01, UInt8(baselineVol)], "Master Volume Write vol=\(baselineVol) (baseline, plain 3-byte form)")
log("Baseline: wrote vol=\(baselineVol) plain — read back \(fmtResult(baseline))")
drawResult("Baseline: \(fmtResult(baseline))")
if baseline.vol != baselineVol {
    log("⚠️ baseline volume write did not read back as sent — treat every result below with that in mind.")
}

// Candidates. Each runs mute-on then mute-off, both judged against the READ reply's MUTE byte.
let candidates: [(name: String, rw: UInt8, vol: UInt8, muteOn: UInt8, muteOff: UInt8, note: String)] = [
    ("C1: 07 01 <vol> <mute>", 0x01, UInt8(baselineVol), 0x01, 0x00,
     "Volume+mute together — the form that failed from MainStage; retried here to confirm it fails from a clean session too."),
    ("C2: 07 01 7F <mute>", 0x01, 0x7F, 0x01, 0x00,
     "VOL above 100 (0x7F), which the spec says the firmware ignores so only MUTE should take effect."),
    ("C3: 07 01 64 <mute>", 0x01, 0x64, 0x01, 0x00,
     "VOL at exactly 100 (0x64), the top legal value, in case >100 is handled differently from ==100."),
    ("C4: 07 00 <vol> <mute>", 0x00, UInt8(baselineVol), 0x01, 0x00,
     "The read-request opcode with a payload. Spec says the firmware discards everything past R/W here, so this should do nothing; included because an earlier session wrongly believed this was the working write form."),
    ("C5: 07 01 <vol> <mute=0x7F>", 0x01, UInt8(baselineVol), 0x7F, 0x00,
     "Alternate nonzero MUTE encoding — spec says 'every value different from zero', so try a value other than 1 in case firmware checks equality to 1 rather than truthiness."),
]

for c in candidates {
    log("")
    log("--- \(c.name) — \(c.note)")
    drawTitle(c.name)

    let onBody: [UInt8] = [0x07, c.rw, c.vol, c.muteOn]
    drawStatus("mute ON: \(hex(onBody))")
    let onResult = writeThenRead(onBody, "\(c.name) — mute ON")
    log("  mute ON  sent \(hex(onBody)) → \(fmtResult(onResult))")
    drawResult("ON  → \(fmtResult(onResult))")
    let onAttempt = MuteAttempt(candidate: c.name, direction: "mute", sent: onBody, result: onResult, expectedNonzeroMute: true)
    attempts.append(onAttempt)

    let offBody: [UInt8] = [0x07, c.rw, c.vol, c.muteOff]
    drawStatus("mute OFF: \(hex(offBody))")
    let offResult = writeThenRead(offBody, "\(c.name) — mute OFF")
    log("  mute OFF sent \(hex(offBody)) → \(fmtResult(offResult))")
    drawResult("OFF → \(fmtResult(offResult))")
    let offAttempt = MuteAttempt(candidate: c.name, direction: "unmute", sent: offBody, result: offResult, expectedNonzeroMute: false)
    attempts.append(offAttempt)

    let verdict = onAttempt.passed && offAttempt.passed ? "WORKS both ways" :
                  onAttempt.passed ? "mutes but won't unmute" :
                  offAttempt.passed ? "unmutes but won't mute (was already unmuted?)" : "no effect"
    log("  verdict: \(verdict)")
}

// Volume-0 fallback — if mute is genuinely unreachable, this is what the feature would use.
drawTitle("Phase A: volume=0 fallback")
drawStatus("Write vol=0, read back")
let zeroResult = writeThenRead([0x07, 0x01, 0x00], "Master Volume Write vol=0 (mute-unreachable fallback)")
log("")
log("Volume-0 fallback: wrote vol=0 plain — read back \(fmtResult(zeroResult))")
drawResult("vol=0 → \(fmtResult(zeroResult))")
let zeroWorks = zeroResult.vol == 0

// Restore a sane audible state before Phase B.
_ = writeThenRead([0x07, 0x01, UInt8(baselineVol)], "Master Volume Write vol=\(baselineVol) (restore before Phase B)")

// ---- Phase A table + summary ---------------------------------------------------
func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s + " " : s + String(repeating: " ", count: w - s.count) }

log("")
log(String(repeating: "=", count: 70))
log("PHASE A RESULTS")
log(String(repeating: "=", count: 70))
log(pad("Candidate", 26) + pad("Dir", 8) + pad("Sent", 16) + pad("VOL", 6) + pad("MUTE", 6) + "Verdict")
for a in attempts {
    log(pad(a.candidate, 26) + pad(a.direction, 8) + pad(hex(a.sent), 16) +
        pad(a.result.vol.map { "\($0)" } ?? "-", 6) + pad(a.result.mute.map { "\($0)" } ?? "-", 6) +
        (a.passed ? "pass" : "fail"))
}

let workingCandidates = Dictionary(grouping: attempts, by: { $0.candidate })
    .filter { _, pair in pair.count == 2 && pair.allSatisfy { $0.passed } }
    .map { $0.key }
    .sorted()

log("")
if workingCandidates.isEmpty {
    log("MUTE VERDICT: no candidate toggled MUTE both ways. Mute appears unreachable on this firmware from a clean session too.")
} else {
    log("MUTE VERDICT: working form(s): \(workingCandidates.joined(separator: ", "))")
}
log("Volume-0 fallback: \(zeroWorks ? "WORKS — read-back confirms vol=0" : "did not read back as 0 — see table above")")
drawVerdict(workingCandidates.isEmpty ? "No mute form works" : "Mute works: \(workingCandidates.first!)")
runLoopWait(1.0)

// =============================================================================
// Phase B — the White LED message. Observation-only: no stdin (this runs from an automated
// shell with no terminal - readLine() previously returned instantly, capturing nothing). Instead,
// pace a fixed interval per numbered step and label each one on the SL88's own screen, so a human
// watching the device can map what they saw to a step number after the fact from the recap below.
// =============================================================================
let STEP_PAUSE = 4.0 // generous fixed pacing - long enough to attribute an observation to a step
let totalSteps = 8
var stepCount = 0
var stepLog: [(n: Int, desc: String)] = []

func stepBanner(_ desc: String) {
    stepCount += 1
    log("")
    log(String(repeating: "#", count: 70))
    log("STEP \(stepCount)/\(totalSteps): \(desc)")
    log(String(repeating: "#", count: 70))
    drawTitle("STEP \(stepCount)/\(totalSteps)")
    drawStatus(desc)
    stepLog.append((n: stepCount, desc: desc))
}

// Marker → pause → send → pause → redraw → pause, split across two numbered steps so a blank
// screen can be attributed to "the marker never showed" vs "the LED send blanked it" separately.
func testLed(wlid: UInt8, label: String) {
    for lst in [1, 0] {
        let stateLabel = lst == 1 ? "ON" : "OFF"

        stepBanner("MARKER before \(label) \(stateLabel)")
        drawMarker()
        runLoopWait(STEP_PAUSE)

        stepBanner("LED \(label) \(stateLabel)")
        send(msgWhiteLed(wlid, lst == 1), "White LED \(label) wlid=0x\(String(format: "%02X", wlid)) LST=\(lst) (\(stateLabel))")
        runLoopWait(STEP_PAUSE)
        drawMarker()
        runLoopWait(STEP_PAUSE)
    }
}

log("")
log(String(repeating: "=", count: 70))
log("PHASE B — the White LED message (02 0A 01 blanked the display from MainStage)")
log("Observation-only: \(Int(STEP_PAUSE))s per step, each labelled on-screen. No prompts - watch the SL88.")
log(String(repeating: "=", count: 70))

testLed(wlid: 0x0A, label: "A encoder LED")
testLed(wlid: 0x00, label: "Zone 1 button LED")

log("")
log(String(repeating: "=", count: 70))
log("PHASE B RECAP — no observations were captured programmatically; match what you saw to these")
log(String(repeating: "=", count: 70))
for s in stepLog {
    log("  STEP \(s.n)/\(totalSteps): \(s.desc)")
}
drawVerdict("See console for LED step recap")

// =============================================================================
// Phase C — reproduce MainStage's send shape. config.lua's flush_pending() (read directly for
// this) dequeues at most one queued message per flush and, when includeQuery is true, appends an
// Identification Query's bytes straight after it into the SAME `out` array with no separator:
//   for i = 1, #m do out[#out + 1] = m[i] end        -- the message, full F0..F7 frame
//   if query then for i = 1, #query do out[#out+1] = query[i] end end  -- the query, full F0..F7
//   return { midi = out }
// i.e. one flat byte array = message-frame ++ query-frame, handed to MainStage as a single `midi`
// return value. Reproduced here as two full F0..F7 frames concatenated with no gap and sent as
// ONE MIDIPacketList packet in a single MIDISend call - the same shape at the byte and call level.
// A hardware capture showed MainStage's own mute write matches this exactly:
//   F0 00 20 1A 16 03 3B 07 01 7F 01 F7   (item=07 WRITE, vol=0x7F, mute=1 - candidate C2's body)
// flushed (logged) yet not acted on, while plain 3-byte volume writes from the same session work.
// This tests whether the pairing itself is what suppresses it.
// =============================================================================

func buildFrame(_ body: [UInt8]) -> [UInt8] { [0xF0] + HEADER + [ID1, ID2] + body + [0xF7] }

func sendRaw(_ bytes: [UInt8], _ label: String) {
    let size = 1024
    let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { buf.deallocate() }
    let list = buf.bindMemory(to: MIDIPacketList.self, capacity: 1)
    var pkt = MIDIPacketListInit(list)
    pkt = MIDIPacketListAdd(list, size, pkt, 0, bytes.count, bytes)
    let err = MIDISend(outPort, destination, list)
    log("TX  \(hex(bytes))\(err == noErr ? "" : "  (MIDISend error \(err))")")
    log("    → \(label)")
}

// Byte-identical to the captured MainStage write (this probe's own ID1/ID2 substituted).
let MUTE_ON_BODY: [UInt8] = [0x07, 0x01, 0x7F, 0x01]
let MUTE_OFF_BODY: [UInt8] = [0x07, 0x01, 0x7F, 0x00]
let QUERY_BODY: [UInt8] = [0x7F, 0x03]

@discardableResult
func pairedMuteWriteThenRead(_ body: [UInt8], _ label: String) -> ReadResult {
    lastMV = nil
    let combined = buildFrame(body) + buildFrame(QUERY_BODY)
    sendRaw(combined, "PAIRED (flush_pending shape): \(label) + Identification Query, one send")
    runLoopWait(pauseSeconds)
    lastMV = nil
    send([0x07, 0x00], "Master Volume Read Request (oracle for paired: \(label))")
    runLoopWait(pauseSeconds)
    return ReadResult(vol: lastMV?.vol, mute: lastMV?.mute)
}

struct PairTrial { let direction: String; let paired: ReadResult; let unpaired: ReadResult; let expectedMute: Int }
var pairTrials: [PairTrial] = []

// Re-baselines to the SAME known mute state before each attempt, so the paired and unpaired
// results for a given direction are compared from identical starting conditions.
func runPairingDirection(_ direction: String, muteBody: [UInt8], baselineBody: [UInt8], expectedMute: Int, expectedBaselineMute: Int) {
    log("")
    log(String(repeating: "-", count: 70))
    log("PHASE C direction: \(direction)")
    log(String(repeating: "-", count: 70))
    drawTitle("Phase C: \(direction)")

    drawStatus("Baseline: mute=\(expectedBaselineMute)")
    let base1 = writeThenRead(baselineBody, "Phase C baseline before PAIRED (\(direction))")
    log("  baseline before paired: \(fmtResult(base1))")
    if base1.mute != expectedBaselineMute {
        log("  ⚠️ baseline did not read back as expected mute=\(expectedBaselineMute) - treat the paired result with that in mind")
    }

    drawStatus("PAIRED write+query: \(direction)")
    let paired = pairedMuteWriteThenRead(muteBody, "\(direction) (paired)")
    log("  PAIRED result: \(fmtResult(paired))")
    drawResult("Paired: \(fmtResult(paired))")

    drawStatus("Re-baseline: mute=\(expectedBaselineMute)")
    let base2 = writeThenRead(baselineBody, "Phase C baseline before UNPAIRED (\(direction))")
    log("  baseline before unpaired: \(fmtResult(base2))")
    if base2.mute != expectedBaselineMute {
        log("  ⚠️ re-baseline did not read back as expected mute=\(expectedBaselineMute) - treat the unpaired result with that in mind")
    }

    drawStatus("UNPAIRED write (control): \(direction)")
    let unpaired = writeThenRead(muteBody, "\(direction) (unpaired control)")
    log("  UNPAIRED result: \(fmtResult(unpaired))")
    drawResult("Unpaired: \(fmtResult(unpaired))")

    pairTrials.append(PairTrial(direction: direction, paired: paired, unpaired: unpaired, expectedMute: expectedMute))
}

log("")
log(String(repeating: "=", count: 70))
log("PHASE C — reproducing MainStage's [message, query] flush shape (config.lua flush_pending())")
log(String(repeating: "=", count: 70))
drawTitle("Phase C: pairing test")

runPairingDirection("mute ON", muteBody: MUTE_ON_BODY, baselineBody: MUTE_OFF_BODY, expectedMute: 1, expectedBaselineMute: 0)
runPairingDirection("mute OFF", muteBody: MUTE_OFF_BODY, baselineBody: MUTE_ON_BODY, expectedMute: 0, expectedBaselineMute: 1)

_ = writeThenRead(MUTE_OFF_BODY, "Phase C cleanup - ensure unmuted")

log("")
log(String(repeating: "=", count: 70))
log("PHASE C RESULTS")
log(String(repeating: "=", count: 70))
log(pad("Direction", 12) + pad("Paired MUTE", 14) + pad("Unpaired MUTE", 16) + "Verdict")
for t in pairTrials {
    let pairedOk = t.paired.mute == t.expectedMute
    let unpairedOk = t.unpaired.mute == t.expectedMute
    let verdict: String
    if pairedOk && unpairedOk { verdict = "both worked - pairing NOT the cause" }
    else if !pairedOk && unpairedOk { verdict = "PAIRED SUPPRESSED, unpaired worked - pairing IS the cause" }
    else if pairedOk && !unpairedOk { verdict = "paired worked, unpaired failed - unexpected" }
    else { verdict = "neither worked - inconclusive for this direction" }
    log(pad(t.direction, 12) + pad(t.paired.mute.map { "\($0)" } ?? "-", 14) + pad(t.unpaired.mute.map { "\($0)" } ?? "-", 16) + verdict)
}

let pairingSuppressesEveryDirection = pairTrials.allSatisfy { $0.paired.mute != $0.expectedMute }
let unpairedWorksEveryDirection = pairTrials.allSatisfy { $0.unpaired.mute == $0.expectedMute }
let pairingHypothesisConfirmed = pairingSuppressesEveryDirection && unpairedWorksEveryDirection
let pairingHypothesisRefuted = pairTrials.allSatisfy { $0.paired.mute == $0.expectedMute } && unpairedWorksEveryDirection

log("")
if pairingHypothesisConfirmed {
    log("PHASE C VERDICT: CONFIRMED — pairing the mute write with a trailing Identification Query in the same send suppresses it in both directions; the unpaired control worked every time. This matches flush_pending()'s own shape and explains why MainStage's mute writes are ignored.")
} else if pairingHypothesisRefuted {
    log("PHASE C VERDICT: REFUTED — pairing with the query did NOT suppress the mute write; both paired and unpaired forms worked in both directions. Something other than the [message, query] shape explains MainStage's failure.")
} else {
    log("PHASE C VERDICT: MIXED — see the table above; pairing is not a clean yes/no across both directions.")
}
drawVerdict(pairingHypothesisConfirmed ? "Pairing SUPPRESSES mute" : pairingHypothesisRefuted ? "Pairing NOT the cause" : "Phase C: mixed result")
runLoopWait(1.0)

// =============================================================================
// Overall summary — readable without scrolling the log.
// =============================================================================
log("")
log(String(repeating: "=", count: 70))
log("SUMMARY")
log(String(repeating: "=", count: 70))
log("Logged in during sequence: \(loginConfirmed ? "yes" : "no")")
log(workingCandidates.isEmpty
    ? "Mute: NO spec-correct form toggled MUTE both ways from a clean session. Fallback (vol=0): \(zeroWorks ? "confirmed working" : "NOT confirmed - see table")."
    : "Mute: \(workingCandidates.joined(separator: ", ")) toggles MUTE both ways. Fallback (vol=0): \(zeroWorks ? "also confirmed working" : "not confirmed").")
log("LED: see Phase B recap above for the numbered steps — an LED has no log signal of its own; match it against what the user saw on the device.")
log("Pairing (Phase C): " + (pairingHypothesisConfirmed ? "CONFIRMED - pairing with the Identification Query suppresses the mute write." : pairingHypothesisRefuted ? "REFUTED - pairing is not the cause." : "MIXED - see Phase C table."))
if !loginConfirmed { log("NOTE: sequence ran in the UN-LOGGED-IN state — treat the above as that condition's result, not a general verdict.") }

// ---- clean shutdown ---------------------------------------------------------------
keepalive.invalidate()
send([0x00, 0x02], "Logout Request (clean exit)")
runLoopWait(1.0)
log("done")
