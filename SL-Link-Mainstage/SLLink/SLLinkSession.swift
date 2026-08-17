import Foundation

/// `.idle -> .identifying -> .listed -> .active -> .standby -> .active -> ...`
/// mirrors the identification/session lifecycle described in
/// identification-messages.md and system-messages.md.
nonisolated enum SLLinkSessionState {
    case idle
    case identifying
    case listed
    /// `model`/`firmware` are optional because real SL88 MK2 hardware can
    /// send a bare Login Confirmation/Recall with no payload at all - see
    /// `SLLinkInbound` and CLAUDE.md's "SL Link protocol (as implemented)"
    /// section. In practice the values are populated from whichever message
    /// carried them (normally Identification Approved) and threaded through
    /// by `SLLinkSession`.
    case active(model: SLModel?, firmware: (UInt8, UInt8, UInt8)?)
    case standby(model: SLModel?, firmware: (UInt8, UInt8, UInt8)?)
}

nonisolated extension SLLinkSessionState: Equatable {
    /// Tuple types can't conform to `Equatable`, so `Optional<(UInt8, UInt8,
    /// UInt8)>` can't use the synthesized `==` even though the bare tuple
    /// can. Compare by hand instead.
    private static func firmwareEqual(_ a: (UInt8, UInt8, UInt8)?, _ b: (UInt8, UInt8, UInt8)?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return a == b
        default:
            return false
        }
    }

    static func == (lhs: SLLinkSessionState, rhs: SLLinkSessionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.identifying, .identifying), (.listed, .listed):
            return true
        case let (.active(modelA, fwA), .active(modelB, fwB)):
            return modelA == modelB && firmwareEqual(fwA, fwB)
        case let (.standby(modelA, fwA), .standby(modelB, fwB)):
            return modelA == modelB && firmwareEqual(fwA, fwB)
        default:
            return false
        }
    }
}

/// High-level events the session hands up to whatever owns it (normally
/// `SLLinkController`). Always delivered on `SLLinkSession.queue`.
nonisolated enum SLLinkSessionEvent {
    case stateChanged(SLLinkSessionState)
    case log(String)
    case decoded(SLLinkMessage)
    case idMismatch(id1: UInt8, id2: UInt8)
    case button(id: SLButtonID, event: SLButtonEvent)
    case encoder(id: SLEncoderID, delta: Int)
    /// The keyboard forgot everything it displayed (see system-messages.md's
    /// Standby/Restart section: "the keyboard does not store any information
    /// about the status of the Device ... this concerns also the Screen").
    /// The owner must fully repaint.
    case restartRequiresRepaint
}

/// The SL Link session state machine: identification, the keepalive
/// heartbeat, login/logout, standby/restart, and DeviceID persistence
/// (fixing bugs 5 and 6 from the project plan - random ID every connect
/// discarding Login Recall, and silently dropping mismatched-ID traffic).
///
/// Runs entirely on its own serial `queue`, distinct from
/// `SLLinkTransport.serialQueue`, so that calling into `transport.connect()`
/// (which synchronously locks the transport's queue) never risks a
/// same-queue deadlock against the transport's own inbound-frame callback.
/// `@unchecked Sendable`: every mutable stored property is only ever
/// touched on `queue` (see the property-level comments below), which is the
/// invariant the compiler can't verify automatically but that this file
/// maintains by hand. Needed so that `queue.async`/`.sync` closures (which
/// require `@Sendable`) can capture `self`.
nonisolated final class SLLinkSession: @unchecked Sendable {

    private enum DefaultsKey {
        static let id1 = "SLLink.deviceID1"
        static let id2 = "SLLink.deviceID2"
    }

    let queue = DispatchQueue(label: "com.sllink.session.serial")

    private let transport: SLLinkTransport
    private let defaults: UserDefaults

    // Only ever read/written on `queue`. External callers (e.g. the
    // dev-console UI, on the main thread) must go through `currentIDPair()`
    // / `setIDPair(id1:id2:)` rather than touching these directly.
    private var id1: UInt8
    private var id2: UInt8

    // `appName` / `useNameInKeepalive` are only read on `queue` (from
    // `identify()` / `sendKeepalive()`); external writers (dev console, on
    // the main thread) must go through the setters below rather than
    // assigning directly, to avoid a data race with those reads.
    private var appName = "SL MainStage"

    /// Discrepancy #2 from the project plan: the spec puts the app name in
    /// the Identification Request only; both official reference
    /// implementations instead (or additionally) append it to every
    /// keepalive. Default to the spec path; flip this from the dev console
    /// if the app never appears in the SL88's APP list.
    private var useNameInKeepalive = false

    func setAppName(_ name: String) {
        queue.async { [self] in appName = name }
    }

    func setUseNameInKeepalive(_ value: Bool) {
        queue.async { [self] in useNameInKeepalive = value }
    }

    private(set) var state: SLLinkSessionState = .idle {
        didSet {
            if oldValue != state {
                onEvent?(.stateChanged(state))
            }
        }
    }

    var onEvent: ((SLLinkSessionEvent) -> Void)?

    private var keepaliveTimer: DispatchSourceTimer?

    // Populated from whichever inbound message actually carries a
    // firmware/model payload (in practice Identification Approved on real
    // hardware; the spec says Login Confirmation). Once known, they're
    // threaded through to `.active`/`.standby` even if a later message in
    // the same session (e.g. a bare Login Confirmation) carries no payload
    // of its own. Only ever read/written on `queue`.
    private var knownFirmware: (UInt8, UInt8, UInt8)?
    private var knownModel: SLModel?

    /// Best-known firmware/model for display (e.g. the dev console), even
    /// before the session reaches `.active`. `nil` until something has told
    /// us.
    var firmwareInfo: (model: SLModel?, firmware: (UInt8, UInt8, UInt8)?) {
        queue.sync { (knownModel, knownFirmware) }
    }

    init(transport: SLLinkTransport, defaults: UserDefaults = .standard) {
        self.transport = transport
        self.defaults = defaults

        if defaults.object(forKey: DefaultsKey.id1) != nil, defaults.object(forKey: DefaultsKey.id2) != nil {
            let storedID1 = UInt8(clamping: defaults.integer(forKey: DefaultsKey.id1))
            let storedID2 = UInt8(clamping: defaults.integer(forKey: DefaultsKey.id2))
            if SLLinkHeader.isReservedIDPair(storedID1, storedID2) {
                (id1, id2) = Self.randomNonReservedIDPair()
            } else {
                (id1, id2) = (storedID1, storedID2)
            }
        } else {
            (id1, id2) = Self.randomNonReservedIDPair(hostID: SLLinkHeader.defaultHostID)
        }

        transport.onFrame = { [weak self] bytes in
            guard let self else { return }
            self.queue.async { self.handleFrame(bytes) }
        }
    }

    // MARK: - DeviceID

    private static func randomNonReservedIDPair(hostID: UInt8? = nil) -> (UInt8, UInt8) {
        var id1 = hostID ?? UInt8.random(in: 0...127)
        var id2 = UInt8.random(in: 1...127) // avoid 0x00 to dodge both reserved pairs regardless of id1
        while SLLinkHeader.isReservedIDPair(id1, id2) {
            id1 = hostID ?? UInt8.random(in: 0...127)
            id2 = UInt8.random(in: 1...127)
        }
        return (id1, id2)
    }

    /// Sets the DeviceID pair explicitly (dev-console override for the
    /// HostID/DeviceID discrepancy - see the project plan) and persists it
    /// so a Login Recall (rather than a fresh Login Confirmation) is
    /// possible across relaunches.
    func currentIDPair() -> (id1: UInt8, id2: UInt8) {
        queue.sync { (id1, id2) }
    }

    func setIDPair(id1 newID1: UInt8, id2 newID2: UInt8) {
        queue.async { [self] in
            id1 = newID1
            id2 = newID2
            persistIDPair()
        }
    }

    private func regenerateInstanceID() {
        (id1, id2) = Self.randomNonReservedIDPair(hostID: id1)
        persistIDPair()
    }

    private func persistIDPair() {
        defaults.set(Int(id1), forKey: DefaultsKey.id1)
        defaults.set(Int(id2), forKey: DefaultsKey.id2)
    }

    // MARK: - Identification / lifecycle

    /// Finds and connects to the SL LINK MIDI ports, then sends an
    /// Identification Request. Must be called from a thread other than
    /// `transport.serialQueue` (normally the main thread, e.g. from a dev
    /// console button) since it blocks briefly on `transport.connect()`.
    func connectAndIdentify() {
        guard transport.connect() else {
            onEvent?(.log("SL LINK MIDI port not found."))
            return
        }
        queue.async { [self] in identify() }
    }

    private func identify() {
        state = .identifying
        transport.send(SLLinkEncoder.identificationRequest(id1: id1, id2: id2, name: appName))
        onEvent?(.log("-> Identification Request (id \(id1),\(id2), name \"\(appName)\")"))
    }

    /// Dev-console escape hatch to force a fresh Identification Request
    /// without re-running endpoint discovery.
    func forceIdentify() {
        queue.async { [self] in identify() }
    }

    /// Runs `builder` with the current DeviceID pair and forwards the
    /// result to the transport. Lets `SLLinkDisplay` and hardware-output
    /// helpers (LEDs) build and send messages without ever touching
    /// `id1`/`id2` directly or worrying about which queue they're called
    /// from.
    func send(_ builder: @escaping (_ id1: UInt8, _ id2: UInt8) -> [UInt8]) {
        queue.async { [self] in
            transport.send(builder(id1, id2))
        }
    }

    func requestLogout() {
        queue.async { [self] in
            transport.send(SLLinkEncoder.systemLogoutRequest(id1: id1, id2: id2))
            onEvent?(.log("-> Logout Request"))
        }
    }

    /// Runs arbitrary work on `queue`. Used by the controller to safely
    /// drive `SLLinkDisplay`/`SLLinkDemoScreen` (e.g. a dev-console "Force
    /// Repaint" button) from the main thread.
    func perform(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Called from the app/controller at teardown. Best-effort: tells the
    /// SL88 we're leaving if we were ever listed, then stops the heartbeat.
    func shutdown() {
        queue.sync {
            stopKeepalive()
            if state != .idle {
                transport.send(SLLinkEncoder.systemLogoutRequest(id1: id1, id2: id2))
            }
            state = .idle
        }
    }

    // MARK: - Keepalive (System Device Notification, every 3s; SL88 times out at 5s)

    private func startKeepalive() {
        stopKeepalive()
        sendKeepalive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3.0)
        timer.setEventHandler { [weak self] in self?.sendKeepalive() }
        timer.resume()
        keepaliveTimer = timer
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    private func sendKeepalive() {
        let message = useNameInKeepalive
            ? SLLinkEncoder.systemDeviceNotification(id1: id1, id2: id2, name: appName)
            : SLLinkEncoder.systemDeviceNotification(id1: id1, id2: id2)
        transport.send(message)
    }

    // MARK: - Inbound frame handling (runs on `queue`)

    private func handleFrame(_ bytes: [UInt8]) {
        guard let message = SLLinkDecoder.decode(bytes) else {
            onEvent?(.log("<- unrecognized/malformed frame: \(Self.hex(bytes))"))
            return
        }

        // Bug 6 fix: log a mismatched DeviceID instead of silently dropping
        // it - we can't yet be sure the keyboard always echoes our exact
        // pair, and silent drops here previously masked reassembly bugs.
        guard message.id1 == id1, message.id2 == id2 else {
            onEvent?(.idMismatch(id1: message.id1, id2: message.id2))
            return
        }

        onEvent?(.decoded(message))

        switch message.inbound {
        case .identificationApproved(let firmware, let model):
            // On real hardware this is where firmware/model actually
            // arrive; on a spec-conforming device they wouldn't, hence both
            // being optional. Remember whichever bits show up.
            if let firmware { knownFirmware = firmware }
            if let model { knownModel = model }
            state = .listed
            startKeepalive()

        case .identificationRejected(let reason):
            switch reason {
            case .deviceIDTakenOrReserved:
                regenerateInstanceID()
                identify()
            case .noSpaceInList:
                onEvent?(.log("SL88 APP list is full; retry later."))
                state = .idle
            }

        case .identificationQueryResult:
            break // Dev-console diagnostic only; no state transition.

        case .loginConfirmed(let firmware, let model), .loginRecall(let firmware, let model):
            // Real hardware's Login Confirmation carries no payload at all;
            // fall back to whatever Identification Approved already told us
            // rather than losing the model/firmware we already know.
            if let firmware { knownFirmware = firmware }
            if let model { knownModel = model }
            state = .active(model: knownModel, firmware: knownFirmware)

        case .logoutRequest:
            transport.send(SLLinkEncoder.systemLogoutConfirmation(id1: id1, id2: id2))
            onEvent?(.log("-> Logout Confirmation"))
            stopKeepalive()
            state = .idle

        case .logoutConfirmation:
            stopKeepalive()
            state = .idle

        case .standby:
            if case let .active(model, firmware) = state {
                state = .standby(model: model, firmware: firmware)
            }

        case .restart:
            if case let .standby(model, firmware) = state {
                state = .active(model: model, firmware: firmware)
                onEvent?(.restartRequiresRepaint)
            }

        case .button(let id, let event):
            onEvent?(.button(id: id, event: event))

        case .encoder(let id, let delta):
            onEvent?(.encoder(id: id, delta: delta))
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
