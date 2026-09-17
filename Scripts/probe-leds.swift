import CoreMIDI
import Foundation

// Standalone LED identification sweep, independent of MainStage. Lights every White LED id
// (ItemType 0x02) and every RGB LED id (ItemType 0x05) one at a time, naming the id under test
// on the SL88's own screen, so a human watching the keyboard can map id -> physical lamp.
//
// Neither LED id table is vendored in this repo; only WLID 0x0A (A encoder ring) and 0x00
// (Zone 1 button) have ever been confirmed on hardware. This probe produces the rest.
//
// No stdin - this runs from an automated shell with no terminal, where readLine() returns
// instantly capturing nothing. Steps are paced on a fixed interval and labelled on-screen
// instead. Modelled closely on probe-mute-led.swift: same endpoint discovery, identification,
// keepalive, SysEx reassembly, login wait and on-screen status mirroring.

var APP_NAME = "SL LED Map"
let ID1: UInt8 = 0x03
var ID2: UInt8 = 0x2D   // distinct from probe-sllink 0x2A, probe-mastervolume 0x2B, probe-mute-led 0x2C
let HEADER: [UInt8] = [0x00, 0x20, 0x1A, 0x16]
var stepSeconds: Double = 3.0
var maxWlid: Int = 0x1F // spec says 12 white LEDs; sweep well past that so the dark ids bound the table
var maxRgbLid: Int = 0x07 // spec says 4 (the zone encoders); same reasoning
var onlyWlid: Int? = nil    // --only <hex>: re-test a single white id instead of sweeping
var onlyWlids: [Int]? = nil // --ids <hex,hex,...>: re-test just these, in order
var waitForLogin = true
let loginTimeout: Double = 25

var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--app-name": if let v = args.next() { APP_NAME = v }
    case "--id2": if let v = args.next(), let b = UInt8(v, radix: 16) { ID2 = b }
    case "--step-seconds": if let v = args.next(), let d = Double(v) { stepSeconds = d }
    case "--max-wlid": if let v = args.next(), let n = Int(v, radix: 16) { maxWlid = n }
    case "--max-rgb-lid": if let v = args.next(), let n = Int(v, radix: 16) { maxRgbLid = n }
    case "--only": if let v = args.next(), let n = Int(v, radix: 16) { onlyWlid = n }
    case "--ids": if let v = args.next() { onlyWlids = v.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces), radix: 16) } }
    case "--no-login-wait": waitForLogin = false
    default: print("unknown option \(a), ignoring")
    }
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
func hx(_ n: Int) -> String { String(format: "0x%02X", n) }
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
    switch (item, fn) {
    case (0x7F, 0x01): return "IDENTIFICATION APPROVED [\(idNote)]"
    case (0x7F, 0x02): return "IDENTIFICATION REJECTED [\(idNote)]"
    case (0x00, 0x01): return "LOGIN CONFIRMATION [\(idNote)]"
    case (0x00, 0x02): return "LOGOUT REQUEST [\(idNote)]"
    case (0x00, 0x03): return "LOGOUT CONFIRMATION [\(idNote)]"
    case (0x00, 0x04): return "STANDBY [\(idNote)]"
    case (0x00, 0x05): return "RESTART [\(idNote)]"
    case (0x01, _):    return "BUTTON bid=\(hx(Int(fn))) evt=\(b.count > 9 ? hx(Int(b[9])) : "?") [\(idNote)]"
    case (0x03, _):    return "ENCODER eid=\(hx(Int(fn))) tick=\(b.count > 9 ? hx(Int(b[9])) : "?") [\(idNote)]"
    default:           return "item=\(hx(Int(item))) fn=\(hx(Int(fn))) [\(idNote)]"
    }
}

var loginConfirmed = false

// ---- SysEx reassembly ---------------------------------------------------------
// CoreMIDI delivers each SL Link frame split across multiple packets/callbacks (confirmed on
// hardware), so accumulate and only dispatch on F7.
var recvBuffer: [UInt8] = []
let recvBufferCap = 512 // guard: reset if F7 never arrives instead of growing forever

func dispatchFrame(_ frame: [UInt8]) {
    log("RX  \(hex(frame))")
    log("    → \(decode(frame))")
    if frame.count >= 9, frame[5] == ID1, frame[6] == ID2, frame[7] == 0x00, frame[8] == 0x01 {
        loginConfirmed = true
    }
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
MIDIClientCreate("SLLedMapProbe" as CFString, nil, nil, &client)

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
// The user stands at the keyboard with no view of stdout - the id under test must be on the
// SL88's own display, or an observation cannot be attributed to an id. Byte layout copied
// from config.lua's msg_write_text.
let IT_DISPLAY: UInt8 = 0x04
let IT_LED: UInt8 = 0x02
let IT_RGB_LED: UInt8 = 0x05
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
let HINT_Y = 165
let DRAW_PAUSE = 0.1

func appendMsbLsb(_ msg: inout [UInt8], _ value: Int) {
    let v = max(0, value)
    msg.append(UInt8((v / 128) % 128))
    msg.append(UInt8(v % 128))
}
// Colours are right-shifted to 7-bit, for display and LEDs alike.
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

func msgWhiteLed(_ wlid: Int, _ on: Bool) -> [UInt8] { [IT_LED, UInt8(wlid), on ? 1 : 0] }

// RGB LED: <LID> <R> <G> <B> <BR 0-127>. One lamp per zone encoder, not a segmented ring.
func msgRgbLed(_ lid: Int, r: Int, g: Int, b: Int, brightness: Int) -> [UInt8] {
    var m: [UInt8] = [IT_RGB_LED, UInt8(lid)]
    appendRGB(&m, r, g, b)
    m.append(UInt8(max(0, min(127, brightness))))
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
func drawHint(_ text: String) {
    send(msgWriteText(text, x: TEXT_X, y: HINT_Y, maxWidth: TEXT_MAXW, size: SIZE_SMALL), "Draw Text: hint")
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

// ---- wait for login ------------------------------------------------------------
// LED writes from an app that is not the selected one are silently discarded, so without this
// every id would read as dark - a failure that looks exactly like a result.
if waitForLogin {
    log("")
    log(">>> Waiting up to \(Int(loginTimeout))s for a System Login Confirmation.")
    log(">>> On the SL88, press APP and select \"\(APP_NAME)\" now. <<<")
    drawStatus("Waiting for login - press APP")
    let deadline = Date().addingTimeInterval(loginTimeout)
    while !loginConfirmed && Date() < deadline { runLoopWait(0.25) }
    if loginConfirmed {
        log("✓ Login confirmed.")
        drawStatus("Logged in")
    } else {
        log("✗ No Login Confirmation within \(Int(loginTimeout))s.")
        log("  LED writes are discarded when the app is not selected, so a dark sweep would be")
        log("  meaningless. Phase 0 below is the check that decides whether to trust this run.")
        drawStatus("NO LOGIN - results suspect")
    }
} else {
    log("--no-login-wait given — running immediately.")
    drawStatus("Skipping login wait")
}

func allWhiteOff() {
    for wlid in 0...maxWlid {
        send(msgWhiteLed(wlid, false), "White LED \(hx(wlid)) off")
        runLoopWait(0.03)
    }
}
func allRgbOff() {
    for lid in 0...maxRgbLid {
        send(msgRgbLed(lid, r: 0, g: 0, b: 0, brightness: 0), "RGB LED \(hx(lid)) off")
        runLoopWait(0.03)
    }
}

// =============================================================================
// Phase 0 — prove the probe can produce a visible signal before any id is called dark.
// =============================================================================
// WLID 0x0A (A encoder ring) and 0x00 (Zone 1 button) are the two ids already confirmed on
// hardware. If neither lights, every "dark" result below is a failure to observe, not a finding.
log("")
log(String(repeating: "=", count: 70))
log("PHASE 0 — control: the two ids already confirmed on hardware")
log(String(repeating: "=", count: 70))
allWhiteOff()
drawTitle("PHASE 0 - CONTROL")
drawStatus("Lighting the two KNOWN ids")
drawResult("WLID 0x0A (A ring) + 0x00 (Zone 1)")
drawHint("Both lit? then the sweep is trustworthy")
send(msgWhiteLed(0x0A, true), "White LED 0x0A on (A encoder ring, confirmed)")
send(msgWhiteLed(0x00, true), "White LED 0x00 on (Zone 1 button, confirmed)")
runLoopWait(stepSeconds * 2)
allWhiteOff()

// =============================================================================
// Phase 1 — everything at once, to count the lamps.
// =============================================================================
// A total count bounds the table: it catches ids that light a lamp outside the swept range and
// tells us up front whether the spec's "12 white LEDs" holds on this firmware.
log("")
log(String(repeating: "=", count: 70))
log("PHASE 1 — all white ids \(hx(0))-\(hx(maxWlid)) lit together (count the lamps)")
log(String(repeating: "=", count: 70))
drawTitle("PHASE 1 - ALL ON")
drawStatus("White ids \(hx(0))-\(hx(maxWlid)) together")
drawResult("Count how many lamps are lit")
drawHint("Spec says 12")
for wlid in 0...maxWlid {
    send(msgWhiteLed(wlid, true), "White LED \(hx(wlid)) on")
    runLoopWait(0.03)
}
runLoopWait(stepSeconds * 3)
allWhiteOff()

// =============================================================================
// Phase 2 — one white id at a time.
// =============================================================================
let whiteIds = onlyWlids ?? onlyWlid.map { [$0] } ?? Array(0...maxWlid)
log("")
log(String(repeating: "=", count: 70))
log("PHASE 2 — white ids one at a time, \(stepSeconds)s each, id shown on the SL88 screen")
log(String(repeating: "=", count: 70))
for (i, wlid) in whiteIds.enumerated() {
    let known = wlid == 0x0A ? "  (known: A encoder ring)" : wlid == 0x00 ? "  (known: Zone 1 button)" : ""
    log("")
    log("--- WHITE \(hx(wlid))  [\(i + 1)/\(whiteIds.count)]\(known) ---")
    drawTitle("WHITE LED \(hx(wlid))")
    drawStatus("step \(i + 1) of \(whiteIds.count)")
    drawResult("Which lamp is lit?")
    drawHint(known.isEmpty ? "note it against \(hx(wlid))" : "expected:\(known)")
    send(msgWhiteLed(wlid, true), "White LED \(hx(wlid)) ON")
    runLoopWait(stepSeconds)
    send(msgWhiteLed(wlid, false), "White LED \(hx(wlid)) off")
    runLoopWait(0.2)
}

// =============================================================================
// Phase 3 — RGB LEDs, one at a time.
// =============================================================================
// Spec: only the four zone encoders, one lamp each, colour and brightness but never a value.
log("")
log(String(repeating: "=", count: 70))
log("PHASE 3 — RGB ids \(hx(0))-\(hx(maxRgbLid)) one at a time, full brightness amber")
log(String(repeating: "=", count: 70))
allRgbOff()
for lid in 0...maxRgbLid {
    log("")
    log("--- RGB \(hx(lid))  [\(lid + 1)/\(maxRgbLid + 1)] ---")
    drawTitle("RGB LED \(hx(lid))")
    drawStatus("step \(lid + 1) of \(maxRgbLid + 1)")
    drawResult("Which encoder is lit?")
    drawHint("spec: zone encoders only")
    send(msgRgbLed(lid, r: 255, g: 140, b: 0, brightness: 127), "RGB LED \(hx(lid)) ON amber")
    runLoopWait(stepSeconds)
    send(msgRgbLed(lid, r: 0, g: 0, b: 0, brightness: 0), "RGB LED \(hx(lid)) off")
    runLoopWait(0.2)
}

// =============================================================================
// Recap — a table to fill in from what was seen.
// =============================================================================
// Nothing here is captured programmatically: an LED has no reply and no log signal of its own.
log("")
log(String(repeating: "=", count: 70))
log("RECAP — paste into docs/implementing-sl-link.md once filled in")
log(String(repeating: "=", count: 70))
log("")
log("| WLID | Lamp |")
log("|:---|:---|")
for wlid in whiteIds {
    let known = wlid == 0x0A ? " A encoder ring (confirmed)" : wlid == 0x00 ? " Zone 1 button (confirmed)" : ""
    log("| `\(hx(wlid))` |\(known) |")
}
log("")
log("| RGB LID | Lamp |")
log("|:---|:---|")
for lid in 0...maxRgbLid { log("| `\(hx(lid))` | |") }
log("")
if !loginConfirmed {
    log("⚠️ NO LOGIN CONFIRMATION — if Phase 0's two known ids did not light, discard this run")
    log("   entirely rather than recording its dark ids as findings.")
}

// ---- clean shutdown ---------------------------------------------------------------
allWhiteOff()
allRgbOff()
keepalive.invalidate()
send([0x00, 0x02], "Logout Request (clean exit)")
runLoopWait(1.0)
log("done")
