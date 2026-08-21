import Foundation
import CoreMIDI

/// CoreMIDI virtual endpoint pair, plus the file-based bridge poller, for
/// the MainStage bridge.
///
/// Mirrors `SLLinkTransport`'s patterns deliberately (the RT-safe ring
/// buffer, the `MIDIReadProc` trampoline that only copies bytes, serial-
/// queue reassembly of `F0...F7` frames, ~1 msg/ms outbound pacing) but
/// talks CoreMIDI's *virtual* endpoint API instead of connecting to a real
/// device, since this side of the bridge doesn't exist as hardware: we
/// publish a **source** (data we generate, which MainStage reads from us -
/// this is where patch *selections* go, though see
/// `MainStageScript/STUDIOLOGIC/SL.device/config.lua`'s MATCHING note for
/// why that direction is doubtful now) and a **destination** (data
/// MainStage would send us over MIDI, which this destination exists to
/// read - kept even though nothing currently arrives this way, per
/// docs/mainstage-integration.md: if MIDI delivery is ever unblocked in a
/// future MainStage version, this path starts working with no further
/// code changes).
///
/// The path that actually carries data today is `pollBridgeFiles`, called
/// on `serialQueue`'s own timer: `config.lua` writes Hello/Heartbeat/
/// Goodbye and Patch List Dump frames straight to two files (see the
/// TRANSPORT note in that same config.lua) since Phase 0 v2 established no
/// MIDI `outport` is ever delivered. Both the file-poll and CoreMIDI-
/// destination paths decode with the same `MainStageProtocol.decode` and
/// feed the same `deliver(_:)`, so `onInbound`/liveness tracking don't care
/// which transport actually produced a given frame.
///
/// Threading contract is identical to `SLLinkTransport` (see CLAUDE.md):
/// `mainStageBridgeReadProc` is the only code that runs on CoreMIDI's
/// real-time thread, and it does nothing but copy bytes into
/// `SLLinkRingBuffer` (reused as-is - it's a generic byte ring buffer, not
/// SL-Link-specific despite the name). Everything else - reassembly,
/// decoding, liveness bookkeeping, file polling - happens on `serialQueue`.
/// Deliberately not `@MainActor`, for the same reason as `SLLinkTransport`:
/// the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default
/// would otherwise make this cross-isolation from the callback's point of
/// view.
///
/// `@unchecked Sendable`: all mutable state is confined to `serialQueue`,
/// which the compiler can't verify but which this file maintains by hand -
/// same rationale as `SLLinkTransport`.
nonisolated final class MainStageEndpoint: @unchecked Sendable {

    /// This virtual endpoint's own identity - unrelated to
    /// `config.lua`'s `controller_info()` now that matching moved to
    /// `usb_vendor_id`/`usb_product_id` against the real SL88
    /// (`STUDIOLOGIC`/`SL`; see that file's MATCHING note and
    /// docs/mainstage-integration.md's "Pivot" section). Kept distinct on
    /// purpose so this endpoint is never confused for the real keyboard in
    /// the macOS MIDI setup, even though nothing currently matches on it.
    static let manufacturer = "SL Link Bridge"
    static let model = "SL MainStage"
    static let endpointName = "SL MainStage"

    /// Must match `STATUS_PATH`/`PATCHLIST_PATH` in config.lua exactly.
    /// Reads happen via these `/tmp/...` paths (the OS resolves the
    /// `/private/tmp` symlink transparently at open time); only the
    /// *entitlement* declaring read access needed the resolved form - see
    /// `SL-Link-Mainstage.entitlements`'s comment for why.
    static let statusFilePath = "/tmp/sl-mainstage-bridge-status.bin"
    static let patchlistFilePath = "/tmp/sl-mainstage-bridge-patchlist.bin"
    /// How often to check the bridge files for new content. Well under the
    /// script's own 2s heartbeat cadence so a patch change feels immediate,
    /// but not so tight it burns CPU polling a file that usually hasn't
    /// changed.
    static let filePollInterval: TimeInterval = 0.3

    /// How often `config.lua`'s `controller_timer_trigger` is expected to
    /// beat (`HEARTBEAT_MS` there). Purely documentation here; the timeout
    /// below is what actually drives liveness.
    static let heartbeatInterval: TimeInterval = 2.0
    /// Bridge is considered down if nothing (hello, heartbeat, or a patch
    /// list) has arrived within this long - mirrors the shape of
    /// `SLLinkSession`'s own 3s-keepalive/~5s-timeout pair.
    static let heartbeatTimeout: TimeInterval = 5.0

    // MARK: - Callbacks (all invoked on `serialQueue`)

    var onLog: ((String) -> Void)?
    var onInbound: ((MainStageInbound) -> Void)?
    /// Fired whenever the bridge transitions live <-> down.
    var onLiveChanged: ((Bool) -> Void)?
    /// Fired once per `start()`/manual-removal call with the outcome of the
    /// `MainStageDeviceRegistration` spike - see that file for what it does
    /// and why it's expected to fail on current macOS.
    var onDeviceRegistrationChanged: ((_ registered: Bool, _ summary: String) -> Void)?

    let serialQueue = DispatchQueue(label: "com.sllink.mainstage.serial")

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()

    private let ringBuffer = SLLinkRingBuffer()
    private var tick: DispatchSourceTimer?
    private var livenessTimer: DispatchSourceTimer?
    private var filePollTimer: DispatchSourceTimer?

    // Reassembly state - serialQueue only.
    private var frame: [UInt8] = []
    private var inFrame = false

    // File-poll transport state - serialQueue only. Last-seen raw bytes per
    // file, so an unchanged file (the common case - config.lua itself
    // already skips redundant patch-list writes, and the status file only
    // changes once per heartbeat) doesn't get re-decoded/re-delivered.
    private var lastStatusFileContents: Data?
    private var lastPatchlistFileContents: Data?

    // Outbound pacing state - serialQueue only.
    private var outbox: [[UInt8]] = []

    // Liveness - serialQueue only.
    private var lastLiveAt: Date?
    private(set) var isLive = false
    private(set) var isPublished = false

    // Device registration spike (see MainStageDeviceRegistration.swift) -
    // serialQueue only. `registeredDevice` is only ever non-zero between a
    // successful `MainStageDeviceRegistration.attempt` and the matching
    // `remove` call.
    private var registeredDevice = MIDIDeviceRef()
    private(set) var isDeviceRegistered = false

    init() {}

    // MARK: - Lifecycle

    /// Returns whether the endpoint pair ended up published, computed
    /// inside the same `serialQueue.sync` that does the work - mirrors
    /// `SLLinkTransport.connect()`/`refreshEndpoints()` returning a value
    /// rather than callers peeking at a stored property from off-queue.
    @discardableResult
    func start() -> Bool {
        serialQueue.sync {
            var status = MIDIClientCreate("SL MainStage Bridge" as CFString, nil, nil, &client)
            guard status == noErr else {
                onLog?("MainStage bridge: MIDIClientCreate failed: \(status)")
                return false
            }

            status = MIDISourceCreate(client, Self.endpointName as CFString, &source)
            guard status == noErr else {
                onLog?("MainStage bridge: MIDISourceCreate failed: \(status)")
                return false
            }

            status = MIDIDestinationCreate(
                client,
                Self.endpointName as CFString,
                mainStageBridgeReadProc,
                Unmanaged.passUnretained(self).toOpaque(),
                &destination
            )
            guard status == noErr else {
                onLog?("MainStage bridge: MIDIDestinationCreate failed: \(status)")
                return false
            }

            // Set on both endpoints: MainStage's generic device match may
            // inspect either one, and real devices normally report the
            // same identity on every port they expose.
            for endpoint in [source, destination] {
                MIDIObjectSetStringProperty(endpoint, kMIDIPropertyManufacturer, Self.manufacturer as CFString)
                MIDIObjectSetStringProperty(endpoint, kMIDIPropertyModel, Self.model as CFString)
            }

            isPublished = true
            startTick()
            startLivenessTimer()
            startFilePolling()
            onLog?("MainStage bridge endpoint published (\"\(Self.endpointName)\", manufacturer \"\(Self.manufacturer)\").")

            // Device registration spike - see MainStageDeviceRegistration
            // for what this does and why it's expected to fail on current
            // macOS. Clean up anything a crashed/force-quit previous run
            // left behind before attempting a fresh registration (project
            // plan constraint 2), regardless of whether this attempt
            // succeeds - the bare endpoints published above are already the
            // working path either way.
            MainStageDeviceRegistration.removeStaleDevices { [weak self] message in self?.onLog?(message) }
            let registration = MainStageDeviceRegistration.attempt { [weak self] message in self?.onLog?(message) }
            registeredDevice = registration.device
            isDeviceRegistered = registration.succeeded
            onDeviceRegistrationChanged?(registration.succeeded, registration.summary)

            return true
        }
    }

    func shutdown() {
        serialQueue.sync {
            tick?.cancel()
            tick = nil
            livenessTimer?.cancel()
            livenessTimer = nil
            filePollTimer?.cancel()
            filePollTimer = nil

            if isDeviceRegistered {
                MainStageDeviceRegistration.remove(registeredDevice) { [weak self] message in self?.onLog?(message) }
            }
            registeredDevice = MIDIDeviceRef()
            isDeviceRegistered = false

            if source != 0 { MIDIEndpointDispose(source) }
            if destination != 0 { MIDIEndpointDispose(destination) }
            if client != 0 { MIDIClientDispose(client) }

            client = MIDIClientRef()
            source = MIDIEndpointRef()
            destination = MIDIEndpointRef()
            isPublished = false
            isLive = false
            lastLiveAt = nil
            lastStatusFileContents = nil
            lastPatchlistFileContents = nil
        }
    }

    /// Manual escape hatch for the dev console (project plan constraint 2):
    /// removes both the currently-tracked registered device (if any) and
    /// any stale one left by a previous run, so the user can always clean
    /// up regardless of internal state. Safe to call at any time, including
    /// when nothing is registered.
    func removeDeviceManually() {
        serialQueue.sync {
            if isDeviceRegistered {
                MainStageDeviceRegistration.remove(registeredDevice) { [weak self] message in self?.onLog?(message) }
                registeredDevice = MIDIDeviceRef()
                isDeviceRegistered = false
            }
            let removedCount = MainStageDeviceRegistration.removeStaleDevices { [weak self] message in self?.onLog?(message) }
            onLog?("MainStage device registration: manual cleanup removed \(removedCount) stale device(s) in addition to the tracked one.")
            onDeviceRegistrationChanged?(false, "removed")
        }
    }

    // MARK: - Outbound (paced ~1 message/ms, mirrors SLLinkTransport)

    /// Enqueues a complete raw-MIDI byte sequence (one or more short
    /// messages back to back, or - in principle - a SysEx frame, though
    /// this bridge only ever sends plain Bank Select/Program Change) for
    /// paced delivery. Safe to call from any thread/queue.
    func send(_ bytes: [UInt8]) {
        serialQueue.async { [weak self] in
            self?.outbox.append(bytes)
        }
    }

    /// Encodes and sends a patch selection - see
    /// `MainStageProtocol.encodeSelection` for the byte layout and its
    /// unverified MSB/LSB discrepancy against the VAX77 reference.
    func sendSelection(patchIndex: UInt8?, setIndex: UInt8?, channel: UInt8 = 0) {
        send(MainStageProtocol.encodeSelection(patchIndex: patchIndex, setIndex: setIndex, channel: channel))
    }

    private func startTick() {
        let timer = DispatchSource.makeTimerSource(queue: serialQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.drainInbound()
            self?.sendNextOutbound()
        }
        timer.resume()
        tick = timer
    }

    private func sendNextOutbound() {
        guard isPublished, source != 0, !outbox.isEmpty else { return }
        let bytes = outbox.removeFirst()
        sendImmediately(bytes)
    }

    private func sendImmediately(_ bytes: [UInt8]) {
        guard source != 0, !bytes.isEmpty else { return }

        // Same correctly-sized allocation as SLLinkTransport.sendImmediately.
        let byteCount = MemoryLayout<MIDIPacketList>.size + bytes.count
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { raw.deallocate() }

        let packetList = raw.assumingMemoryBound(to: MIDIPacketList.self)
        let firstPacket = MIDIPacketListInit(packetList)
        _ = MIDIPacketListAdd(packetList, byteCount, firstPacket, 0, bytes.count, bytes)

        // MIDIReceived, not MIDISend: this publishes the bytes as if a
        // (virtual) device had generated them on `source`, for whichever
        // app - MainStage - has connected an input to it.
        let result = MIDIReceived(source, packetList)
        if result != noErr {
            onLog?("MainStage bridge: MIDIReceived failed: \(result)")
        }
    }

    // MARK: - Inbound (ring buffer drain + F0...F7 reassembly)

    /// Runs on CoreMIDI's real-time thread via `mainStageBridgeReadProc`:
    /// only copies bytes into the ring buffer. No allocation, no ARC
    /// traffic, no logging, no dispatch - identical discipline to
    /// `SLLinkTransport.handleIncoming`.
    fileprivate func handleIncoming(_ packetList: UnsafePointer<MIDIPacketList>) {
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            withUnsafeBytes(of: packet.data) { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ringBuffer.write(base, count: Int(packet.length))
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    /// Reassembles `F0...F7` frames from the ring buffer. Runs on
    /// `serialQueue` only.
    private func drainInbound() {
        ringBuffer.drain { [self] byte in
            if byte == MainStageHeader.sysexStart {
                frame = [byte]
                inFrame = true
            } else if inFrame {
                frame.append(byte)
                if byte == MainStageHeader.sysexEnd {
                    handleFrame(frame)
                    frame = []
                    inFrame = false
                }
            }
            // Stray non-SysEx bytes (there shouldn't be any - MainStage
            // only ever sends us the dialect's own SysEx) are ignored.
        }
    }

    private func handleFrame(_ bytes: [UInt8]) {
        guard let message = MainStageProtocol.decode(bytes) else {
            onLog?("MainStage bridge: unrecognized/malformed frame (\(bytes.count) bytes)")
            return
        }
        deliver(message)
    }

    /// Common landing point for a decoded frame regardless of which
    /// transport produced it (CoreMIDI destination or file poll below) -
    /// liveness tracking and `onInbound` don't care which one it was.
    private func deliver(_ message: MainStageInbound) {
        switch message {
        case .hello, .heartbeat, .patchList:
            markLive()
        case .goodbye:
            markDown()
        }

        onInbound?(message)
    }

    // MARK: - File-poll transport
    //
    // The path that actually carries data today - see this file's
    // type-level doc comment and the TRANSPORT note in config.lua. Runs on
    // `serialQueue` via its own timer, same discipline as `startTick`/
    // `startLivenessTimer` below.

    private func startFilePolling() {
        let timer = DispatchSource.makeTimerSource(queue: serialQueue)
        timer.schedule(deadline: .now(), repeating: Self.filePollInterval)
        timer.setEventHandler { [weak self] in self?.pollBridgeFiles() }
        timer.resume()
        filePollTimer = timer
    }

    private func pollBridgeFiles() {
        pollBridgeFile(path: Self.statusFilePath, lastContents: &lastStatusFileContents)
        pollBridgeFile(path: Self.patchlistFilePath, lastContents: &lastPatchlistFileContents)
    }

    /// Reads `path`, and if its bytes differ from `lastContents` (including
    /// the first time the file is seen), decodes and delivers it. Missing
    /// files (script hasn't run yet, or nothing's been written since app
    /// launch) are silently skipped, not logged - that's the expected state
    /// until MainStage actually invokes the script.
    private func pollBridgeFile(path: String, lastContents: inout Data?) {
        guard let data = FileManager.default.contents(atPath: path), data != lastContents else { return }
        lastContents = data
        guard let message = MainStageProtocol.decode([UInt8](data)) else {
            onLog?("MainStage bridge: unrecognized/malformed bridge file at \(path) (\(data.count) bytes)")
            return
        }
        deliver(message)
    }

    // MARK: - Liveness
    //
    // Bridge liveness is the real "is MainStage bound to us" signal (see
    // docs/mainstage-integration.md's "Connection status" section): hello
    // arrives from `controller_initialize`, a heartbeat every
    // `heartbeatInterval` from `controller_timer_trigger`, and goodbye from
    // `controller_finalize`. Anything arriving at all - including a patch
    // list dump - also counts as proof of life.

    private func markLive() {
        lastLiveAt = Date()
        if !isLive {
            isLive = true
            onLiveChanged?(true)
        }
    }

    private func markDown() {
        lastLiveAt = nil
        if isLive {
            isLive = false
            onLiveChanged?(false)
        }
    }

    private func startLivenessTimer() {
        let timer = DispatchSource.makeTimerSource(queue: serialQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.checkLiveness() }
        timer.resume()
        livenessTimer = timer
    }

    private func checkLiveness() {
        guard isLive, let lastLiveAt else { return }
        if Date().timeIntervalSince(lastLiveAt) > Self.heartbeatTimeout {
            isLive = false
            self.lastLiveAt = nil
            onLiveChanged?(false)
            onLog?("MainStage bridge: heartbeat timed out; marking bridge down.")
        }
    }
}

// MARK: - CoreMIDI callback trampoline
//
// Runs on CoreMIDI's own real-time thread. Forwards straight into
// `handleIncoming`, which only touches the lock-free ring buffer - see
// `SLLinkTransport`'s matching trampoline for the same discipline.
//
// Explicitly `nonisolated`: under `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor`, a module-scope `let` can otherwise be inferred main-actor-
// isolated, which would make referencing it from `start()` below (a
// nonisolated context, since `MainStageEndpoint` itself is `nonisolated`)
// an isolation error/warning - a `MIDIReadProc` is a bare C function
// pointer with no captured state, so it can never actually touch actor-
// isolated state regardless.

nonisolated private let mainStageBridgeReadProc: MIDIReadProc = { packetList, refCon, _ in
    guard let refCon else { return }
    Unmanaged<MainStageEndpoint>.fromOpaque(refCon).takeUnretainedValue().handleIncoming(packetList)
}
