import Foundation
import CoreMIDI
import Synchronization

/// A single-producer/single-consumer lock-free byte ring buffer.
///
/// The producer is the CoreMIDI `MIDIReadProc` trampoline, which runs on a
/// high-priority real-time thread: `write` must never allocate, touch ARC,
/// log, or dispatch. The consumer is `SLLinkTransport`'s serial drain queue.
/// Overflow is dropped silently (no allocation-triggering resize, no
/// logging from the RT side) - large enough capacity makes this a
/// non-issue in practice for a SysEx-only, LCD-paced protocol.
nonisolated final class SLLinkRingBuffer {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<UInt8>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    init(capacity: Int = 1 << 16) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Producer-only. Returns `false` (and drops the write) if the buffer is full.
    @discardableResult
    func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard count > 0 else { return true }
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let used = h - t
        guard count <= capacity - used else { return false }
        var idx = h
        for i in 0..<count {
            storage[idx % capacity] = bytes[i]
            idx += 1
        }
        head.store(h + count, ordering: .releasing)
        return true
    }

    /// Consumer-only. Calls `body` once per available byte, in order.
    func drain(_ body: (UInt8) -> Void) {
        let h = head.load(ordering: .acquiring)
        var t = tail.load(ordering: .relaxed)
        while t < h {
            body(storage[t % capacity])
            t += 1
        }
        tail.store(t, ordering: .releasing)
    }
}

/// CoreMIDI transport for the SL Link protocol. Knows nothing about message
/// meaning: it moves bytes in (reassembled into complete `F0...F7` frames)
/// and bytes out (paced at ~1 message/ms, as both official reference
/// implementations do, since the spec repeatedly warns the LCD is
/// expensive). All protocol interpretation happens above this layer.
///
/// Threading contract: the only code that runs on CoreMIDI's real-time
/// thread is `midiReadProc`, and it does nothing but copy bytes into
/// `SLLinkRingBuffer`. Everything else - reassembly, decoding hooks,
/// `@Published`-adjacent callbacks - happens on `serialQueue`, which itself
/// hops to main before touching any UI-facing state. This class is
/// deliberately not `@MainActor`, despite the project-wide
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting - see CLAUDE.md.
/// It's marked `nonisolated` explicitly because that project setting makes
/// *every* unannotated declaration implicitly main-actor-isolated by
/// default; without this, the compiler treats calls made from the
/// CoreMIDI/GCD callback trampolines below (which run on arbitrary threads,
/// never the main actor) as cross-isolation calls.
///
/// `@unchecked Sendable`: all mutable state is confined to `serialQueue`
/// (the `Locked`-suffixed methods assume they're already running on it; the
/// public entry points hop onto it via `sync`/`async`), which the compiler
/// can't verify but which this file maintains by hand. Needed so the
/// `queue.async`/`.sync` closures used throughout can capture `self`.
nonisolated final class SLLinkTransport: @unchecked Sendable {

    /// Endpoint matching: case-insensitive *contains* "LINK" on the display
    /// name (`kMIDIPropertyDisplayName`). The macOS SL Link port is named
    /// "SL LINK", not "LINK" - an exact-equality match (the bug in the
    /// original MIDIManager.swift) never finds it.
    static func matchesSLLink(_ name: String) -> Bool {
        name.range(of: "link", options: .caseInsensitive) != nil
    }

    // MARK: - Callbacks (all invoked on `serialQueue`, never on the CoreMIDI RT thread)

    /// A fully reassembled `F0 ... F7` byte frame received from the SL88.
    var onFrame: (([UInt8]) -> Void)?
    /// Non-realtime informational/connection-status logging.
    var onLog: ((String) -> Void)?
    /// Fired whenever the source/destination endpoint lists change.
    var onEndpointsChanged: ((_ sources: [String], _ destinations: [String]) -> Void)?
    /// Fired when the connected LINK source and/or destination disappear.
    var onDisconnected: (() -> Void)?

    let serialQueue = DispatchQueue(label: "com.sllink.transport.serial")

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var connectedSource = MIDIEndpointRef()
    private(set) var destination = MIDIEndpointRef()

    private let ringBuffer = SLLinkRingBuffer()
    private var tick: DispatchSourceTimer?

    // Reassembly state - serialQueue only.
    private var frame: [UInt8] = []
    private var inFrame = false

    // Outbound pacing state - serialQueue only.
    private var outbox: [[UInt8]] = []

    private(set) var isConnected = false

    init() {}

    // MARK: - Lifecycle

    /// Stays on the CoreMIDI 1.0 byte-oriented API deliberately (see
    /// CLAUDE.md): `MIDIClientCreate` + `MIDINotifyProc` and
    /// `MIDIInputPortCreate` + `MIDIReadProc`, both taking a `refCon`
    /// resolved via `Unmanaged.passUnretained(self)`. That pointer is only
    /// ever safe because `SLLinkTransport` is owned for the app's entire
    /// lifetime (by `SLLinkController`, itself owned at the `App` level) and
    /// torn down explicitly via `shutdown()` rather than relying on
    /// `deinit` ordering - see bug 7 in the project plan.
    func start() {
        serialQueue.sync {
            var status = MIDIClientCreate(
                "SL Link MainStage" as CFString,
                slLinkMIDINotifyProc,
                Unmanaged.passUnretained(self).toOpaque(),
                &client
            )
            guard status == noErr else {
                onLog?("MIDIClientCreate failed: \(status)")
                return
            }

            status = MIDIInputPortCreate(
                client,
                "SL Link Input" as CFString,
                slLinkMIDIReadProc,
                Unmanaged.passUnretained(self).toOpaque(),
                &inputPort
            )
            guard status == noErr else {
                onLog?("MIDIInputPortCreate failed: \(status)")
                return
            }

            status = MIDIOutputPortCreate(client, "SL Link Output" as CFString, &outputPort)
            guard status == noErr else {
                onLog?("MIDIOutputPortCreate failed: \(status)")
                return
            }

            startTick()
            _ = refreshEndpointsLocked()
        }
    }

    func shutdown() {
        serialQueue.sync {
            tick?.cancel()
            tick = nil

            if connectedSource != 0 {
                MIDIPortDisconnectSource(inputPort, connectedSource)
            }
            if inputPort != 0 {
                MIDIPortDispose(inputPort)
            }
            if outputPort != 0 {
                MIDIPortDispose(outputPort)
            }
            if client != 0 {
                MIDIClientDispose(client)
            }

            client = MIDIClientRef()
            inputPort = MIDIPortRef()
            outputPort = MIDIPortRef()
            connectedSource = MIDIEndpointRef()
            destination = MIDIEndpointRef()
            isConnected = false
        }
    }

    // MARK: - Endpoint discovery
    //
    // All mutable transport state (`isConnected`, `connectedSource`,
    // `destination`, the CoreMIDI refs, the outbox, the reassembly buffer)
    // is only ever touched on `serialQueue`. Public entry points that are
    // expected to be called from other threads (e.g. the main-thread
    // controller reacting to a UI button) hop onto `serialQueue` via `sync`;
    // internal callers that are already running on `serialQueue` (like the
    // hot-plug notification handler) call the `Locked` variant directly to
    // avoid a same-queue `sync` deadlock.

    @discardableResult
    func refreshEndpoints() -> (sources: [String], destinations: [String]) {
        serialQueue.sync { refreshEndpointsLocked() }
    }

    private func refreshEndpointsLocked() -> (sources: [String], destinations: [String]) {
        var sources: [String] = []
        var destinations: [String] = []

        for index in 0..<MIDIGetNumberOfSources() {
            sources.append(Self.endpointDisplayName(MIDIGetSource(index)))
        }
        for index in 0..<MIDIGetNumberOfDestinations() {
            destinations.append(Self.endpointDisplayName(MIDIGetDestination(index)))
        }

        onEndpointsChanged?(sources, destinations)
        return (sources, destinations)
    }

    private static func endpointDisplayName(_ endpoint: MIDIEndpointRef) -> String {
        var property: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &property)
        guard status == noErr, let property else { return "<Unknown>" }
        return property.takeRetainedValue() as String
    }

    /// Finds and connects to the first source/destination pair whose display
    /// name contains "LINK". Requires both to be present. Returns `true` on
    /// success.
    @discardableResult
    func connect() -> Bool {
        serialQueue.sync {
            var foundSource = MIDIEndpointRef()
            for index in 0..<MIDIGetNumberOfSources() {
                let source = MIDIGetSource(index)
                if Self.matchesSLLink(Self.endpointDisplayName(source)) {
                    foundSource = source
                    break
                }
            }

            var foundDestination = MIDIEndpointRef()
            for index in 0..<MIDIGetNumberOfDestinations() {
                let dest = MIDIGetDestination(index)
                if Self.matchesSLLink(Self.endpointDisplayName(dest)) {
                    foundDestination = dest
                    break
                }
            }

            guard foundSource != 0, foundDestination != 0 else {
                onLog?("SL LINK MIDI port not found (need both a source and a destination named \"...LINK...\").")
                return false
            }

            let status = MIDIPortConnectSource(inputPort, foundSource, nil)
            guard status == noErr else {
                onLog?("Could not connect SL LINK input: \(status)")
                return false
            }

            connectedSource = foundSource
            destination = foundDestination
            isConnected = true
            onLog?("SL LINK connected (source + destination found).")
            return true
        }
    }

    // MARK: - Outbound (paced ~1 message/ms)

    /// Enqueues a complete `F0 ... F7` message for paced delivery. Safe to
    /// call from any thread/queue.
    func send(_ bytes: [UInt8]) {
        serialQueue.async { [weak self] in
            self?.outbox.append(bytes)
        }
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
        guard isConnected, destination != 0, !outbox.isEmpty else { return }
        let bytes = outbox.removeFirst()
        sendImmediately(bytes)
    }

    private func sendImmediately(_ bytes: [UInt8]) {
        guard destination != 0 else {
            onLog?("No SL LINK destination available; dropped \(bytes.count)-byte message.")
            return
        }

        // Correctly sized MIDIPacketList allocation - the original code
        // allocated `MIDIPacketList()` (256 data bytes) on the stack but
        // told MIDIPacketListAdd the buffer was 1024 bytes, corrupting the
        // stack for any message over ~247 bytes. Allocate exactly what the
        // header plus payload require instead.
        let byteCount = MemoryLayout<MIDIPacketList>.size + bytes.count
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { raw.deallocate() }

        let packetList = raw.assumingMemoryBound(to: MIDIPacketList.self)
        let firstPacket = MIDIPacketListInit(packetList)
        // Returns non-optional on this SDK; failure can't happen here since
        // `byteCount` above always allocates exactly what this one packet
        // needs.
        _ = MIDIPacketListAdd(packetList, byteCount, firstPacket, 0, bytes.count, bytes)

        let result = MIDISend(outputPort, destination, packetList)
        if result != noErr {
            onLog?("MIDISend failed: \(result)")
        }
    }

    // MARK: - Inbound (ring buffer drain + F0...F7 reassembly)

    /// CoreMIDI's `MIDIReadProc`-equivalent block. Runs on CoreMIDI's
    /// real-time thread: only copies bytes into the ring buffer. No
    /// allocation, no ARC traffic beyond capturing `self` for the block's
    /// own dispatch (done once, at port-creation time, not per packet), no
    /// logging, no dispatch here.
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

    /// Reassembles `F0 ... F7` frames from the ring buffer. Runs on
    /// `serialQueue` only.
    private func drainInbound() {
        ringBuffer.drain { [self] byte in
            if byte == SLLinkHeader.sysexStart {
                frame = [byte]
                inFrame = true
            } else if inFrame {
                frame.append(byte)
                if byte == SLLinkHeader.sysexEnd {
                    onFrame?(frame)
                    frame = []
                    inFrame = false
                }
            }
            // Stray bytes outside of an F0...F7 frame are ignored, not
            // logged (this still runs on the drain queue, not the RT
            // thread, but per-byte logging here would still be wasteful
            // under encoder traffic).
        }
    }

    // MARK: - Hot-plug

    /// Takes a plain `MIDINotificationMessageID` rather than the raw
    /// `UnsafePointer<MIDINotification>` CoreMIDI hands the trampoline: that
    /// pointer is only valid for the duration of the C callback, so the
    /// trampoline copies the one field we need out of it *before* hopping
    /// onto `serialQueue` (see `slLinkMIDINotifyProc` below).
    fileprivate func handleNotification(_ messageID: MIDINotificationMessageID) {
        guard messageID == .msgObjectAdded || messageID == .msgObjectRemoved else {
            return
        }

        let (sources, destinations) = refreshEndpointsLocked()

        if isConnected {
            let stillPresent = sources.contains(where: Self.matchesSLLink)
                && destinations.contains(where: Self.matchesSLLink)
            if !stillPresent {
                isConnected = false
                connectedSource = MIDIEndpointRef()
                destination = MIDIEndpointRef()
                onLog?("SL LINK endpoint disappeared.")
                onDisconnected?()
            }
        }
    }
}

// MARK: - CoreMIDI callback trampolines
//
// These run on CoreMIDI's own threads. `slLinkMIDIReadProc` is the
// real-time one and must stay allocation-free; it forwards straight into
// `handleIncoming`, which only touches the lock-free ring buffer.
// `slLinkMIDINotifyProc` is not real-time (device add/remove is rare) so it
// hops to the serial queue before doing any work.

private let slLinkMIDIReadProc: MIDIReadProc = { packetList, refCon, _ in
    guard let refCon else { return }
    Unmanaged<SLLinkTransport>.fromOpaque(refCon).takeUnretainedValue().handleIncoming(packetList)
}

private let slLinkMIDINotifyProc: MIDINotifyProc = { message, refCon in
    guard let refCon else { return }
    // Copy the field we need out of `message` synchronously - the pointer
    // itself is only valid for the duration of this call.
    let messageID = message.pointee.messageID
    let transport = Unmanaged<SLLinkTransport>.fromOpaque(refCon).takeUnretainedValue()
    transport.serialQueue.async {
        transport.handleNotification(messageID)
    }
}
