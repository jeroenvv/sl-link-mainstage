import Foundation
import Combine

/// `ObservableObject` façade for SwiftUI. Owns the whole SL Link stack
/// (transport -> session -> display -> demo screen) and replaces the old
/// `MIDIManager.swift`.
///
/// Deliberately not `@MainActor` (matching `SLLinkTransport`): the session
/// and demo screen run on their own serial queue, and every `@Published`
/// mutation here hops to main explicitly, mirroring the discipline already
/// established for `addLog`/`refreshEndpoints` in the original code (see
/// CLAUDE.md's Threading section).
///
/// Bug 7 fix: this object is owned for the app's entire lifetime by
/// `SL_Link_MainstageApp`/its `AppDelegate` (not by a view's
/// `@StateObject`, which could deallocate mid-callback), and `shutdown()` is
/// called explicitly from `applicationWillTerminate` rather than relying on
/// `deinit` ordering against in-flight CoreMIDI callbacks.
final class SLLinkController: ObservableObject {

    @Published private(set) var sources: [String] = []
    @Published private(set) var destinations: [String] = []
    @Published private(set) var log: [String] = []
    @Published private(set) var state: SLLinkSessionState = .idle
    @Published private(set) var hostID: UInt8 = 0
    @Published private(set) var deviceInstanceID: UInt8 = 0
    /// Best-known firmware/model, populated as soon as *any* message that
    /// carries them arrives (in practice Identification Approved on real
    /// hardware - see CLAUDE.md). `nil` until then; may stay `nil` forever
    /// against a strictly spec-conforming device that never sends either.
    @Published private(set) var firmwareVersion: (UInt8, UInt8, UInt8)?
    @Published private(set) var model: SLModel?

    @Published var useNameInKeepalive = false {
        didSet { session.setUseNameInKeepalive(useNameInKeepalive) }
    }

    private let transport = SLLinkTransport()
    private let session: SLLinkSession
    // `nonisolated` because they're driven from `handle(_:)`, which runs on
    // `session.queue` (not the main actor) - see the note above `handle`.
    // A stored property's isolation comes from where it's declared, not
    // from the type it holds, so these need the annotation even though
    // `SLLinkDisplay`/`SLLinkDemoScreen` are themselves `nonisolated` types.
    nonisolated private let display: SLLinkDisplay
    nonisolated private let demoScreen: SLLinkDemoScreen

    init() {
        session = SLLinkSession(transport: transport)
        display = SLLinkDisplay(session: session)
        demoScreen = SLLinkDemoScreen(display: display)

        transport.onLog = { [weak self] message in self?.appendLog(message) }
        transport.onEndpointsChanged = { [weak self] sources, destinations in
            self?.updateEndpoints(sources: sources, destinations: destinations)
        }
        transport.onDisconnected = { [weak self] in self?.appendLog("SL LINK endpoint disappeared.") }

        session.onEvent = { [weak self] event in self?.handle(event) }

        transport.start()

        let pair = session.currentIDPair()
        DispatchQueue.main.async { [weak self] in
            self?.hostID = pair.id1
            self?.deviceInstanceID = pair.id2
        }
    }

    /// Explicit teardown - see the bug-7 note above. Call from
    /// `applicationWillTerminate`, not `deinit`.
    func shutdown() {
        session.shutdown()
        transport.shutdown()
    }

    // MARK: - User actions

    func refreshEndpoints() {
        _ = transport.refreshEndpoints()
    }

    func connect() {
        session.connectAndIdentify()
    }

    func forceIdentify() {
        session.forceIdentify()
    }

    func forceLogout() {
        session.requestLogout()
    }

    func forceRepaint() {
        session.perform { [weak self] in
            self?.display.invalidateAll()
            self?.demoScreen.redrawAll()
        }
    }

    func setIDPair(id1: UInt8, id2: UInt8) {
        session.setIDPair(id1: id1, id2: id2)
        DispatchQueue.main.async { [weak self] in
            self?.hostID = id1
            self?.deviceInstanceID = id2
        }
    }

    // MARK: - Event handling
    //
    // `handle(_:)` is invoked by `SLLinkSession.onEvent`, i.e. on
    // `session.queue`. Driving `demoScreen`/`display` directly from here is
    // correct (that's the queue they require); every `@Published` write
    // goes through a small helper that hops to main.

    // These run on `session.queue` / `transport.serialQueue` (both
    // `nonisolated`, never the main actor), so they're marked `nonisolated`
    // too - otherwise the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION =
    // MainActor` default would make them implicitly main-actor-isolated,
    // which is wrong for code invoked directly from those queues. Each one
    // still hops to main explicitly before touching a `@Published` property.
    nonisolated private func handle(_ event: SLLinkSessionEvent) {
        switch event {
        case .stateChanged(let newState):
            setState(newState)
            appendLog("Session state -> \(Self.describe(newState))")
            if case .active = newState {
                display.invalidateAll()
                demoScreen.redrawAll()
            }

        case .log(let message):
            appendLog(message)

        case .decoded(let message):
            appendLog("<- \(message.inbound)")
            switch message.inbound {
            case .identificationApproved(let firmware, let model),
                 .loginConfirmed(let firmware, let model),
                 .loginRecall(let firmware, let model):
                if firmware != nil || model != nil {
                    setFirmwareInfo(firmware: firmware, model: model)
                }
            default:
                break
            }

        case .idMismatch(let mismatchedID1, let mismatchedID2):
            appendLog("<- frame for unrecognized DeviceID (\(mismatchedID1),\(mismatchedID2)); ignored")

        case .button(let id, let evt):
            appendLog("<- Button \(id) \(evt)")
            demoScreen.handleButton(id: id, event: evt)

        case .encoder(let id, let delta):
            appendLog("<- Encoder \(id) delta \(delta)")
            demoScreen.handleEncoder(id: id, delta: delta)

        case .restartRequiresRepaint:
            appendLog("Restart: repainting (SL88 retains no screen state across Standby).")
            display.invalidateAll()
            demoScreen.redrawAll()
        }
    }

    nonisolated private func setState(_ newState: SLLinkSessionState) {
        DispatchQueue.main.async { [weak self] in self?.state = newState }
    }

    nonisolated private func setFirmwareInfo(firmware: (UInt8, UInt8, UInt8)?, model: SLModel?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let firmware { self.firmwareVersion = firmware }
            if let model { self.model = model }
        }
    }

    nonisolated private func appendLog(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.log.append(message)
            if self.log.count > 500 {
                self.log.removeFirst(self.log.count - 500)
            }
        }
    }

    nonisolated private func updateEndpoints(sources: [String], destinations: [String]) {
        DispatchQueue.main.async { [weak self] in
            self?.sources = sources
            self?.destinations = destinations
        }
    }

    /// Real hardware doesn't always tell us; render "unknown" rather than
    /// crashing or printing `Optional(...)` when it hasn't (yet).
    nonisolated private static func describe(model: SLModel?, firmware: (UInt8, UInt8, UInt8)?) -> String {
        let modelText = model.map { "\($0)" } ?? "unknown model"
        let firmwareText = firmware.map { "\($0.0).\($0.1).\($0.2)" } ?? "unknown firmware"
        return "\(modelText), firmware \(firmwareText)"
    }

    nonisolated private static func describe(_ state: SLLinkSessionState) -> String {
        switch state {
        case .idle: return "idle"
        case .identifying: return "identifying"
        case .listed: return "listed (waiting for login on the keyboard)"
        case .active(let model, let fw): return "active (\(describe(model: model, firmware: fw)))"
        case .standby(let model, let fw): return "standby (\(describe(model: model, firmware: fw)))"
        }
    }
}
