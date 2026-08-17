import Foundation
import Combine
import AppKit

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

    // MARK: - MainStage bridge
    //
    // See docs/mainstage-integration.md's "Connection status" section.
    // `mainStageBridgeLive` is the authoritative signal (heartbeat/hello/
    // goodbye from config.lua via MainStageEndpoint's own timeout logic).
    // `mainStageProcessRunning` is the secondary, weaker signal from
    // `NSWorkspace` - see `refreshMainStageProcessRunning` below for the
    // App Sandbox finding.

    @Published private(set) var mainStageEndpointPublished = false
    @Published private(set) var mainStageBridgeLive = false
    /// Outcome of the `MainStageDeviceRegistration` spike - see that file
    /// and `docs/mainstage-integration.md`'s "Virtual device registration"
    /// section. Expected to stay `false` with a `paramErr` summary on
    /// current macOS; the bare endpoint above (`mainStageEndpointPublished`)
    /// is unaffected either way.
    @Published private(set) var mainStageDeviceRegistered = false
    @Published private(set) var mainStageDeviceRegistrationSummary = "not attempted"
    @Published private(set) var mainStageLastHeartbeatAt: Date?
    @Published private(set) var mainStageLastHeartbeatSeq: Int?
    @Published private(set) var mainStagePatchList: MainStagePatchList?
    @Published private(set) var mainStageLastSelectionSent: String?
    /// `nil` until the first check runs; see `refreshMainStageProcessRunning`.
    @Published private(set) var mainStageProcessRunning: Bool?

    private let mainStageEndpoint = MainStageEndpoint()
    private var mainStageProcessCheckTimer: Timer?

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

        mainStageEndpoint.onLog = { [weak self] message in self?.appendLog(message) }
        mainStageEndpoint.onInbound = { [weak self] inbound in self?.handleMainStage(inbound) }
        mainStageEndpoint.onLiveChanged = { [weak self] live in self?.setMainStageLive(live) }
        mainStageEndpoint.onDeviceRegistrationChanged = { [weak self] registered, summary in
            self?.setMainStageDeviceRegistration(registered: registered, summary: summary)
        }
        setMainStageEndpointPublished(mainStageEndpoint.start())

        refreshMainStageProcessRunning()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshMainStageProcessRunning()
        }
        RunLoop.main.add(timer, forMode: .common)
        mainStageProcessCheckTimer = timer
    }

    /// Explicit teardown - see the bug-7 note above. Call from
    /// `applicationWillTerminate`, not `deinit`.
    func shutdown() {
        session.shutdown()
        transport.shutdown()
        mainStageEndpoint.shutdown()
        mainStageProcessCheckTimer?.invalidate()
        mainStageProcessCheckTimer = nil
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

    // MARK: - MainStage bridge (dev-console verification only - see the
    // project plan; the real SL88 patch browser is Phase 3)

    /// Manual escape hatch for the virtual-endpoint verification gate
    /// (docs/mainstage-integration.md / the project plan): with MainStage
    /// running and the device script selected, send an arbitrary selection
    /// and confirm MainStage jumps to the corresponding patch. `nil`
    /// indices send the `0x7F` "n/a" sentinel.
    /// Dev-console "Remove Device" button (project plan constraint 2): lets
    /// the user clean up the MIDI setup by hand regardless of what state
    /// `MainStageEndpoint` thinks it's in. Safe to press even when
    /// `mainStageDeviceRegistered` is already `false` - see
    /// `MainStageEndpoint.removeDeviceManually()`.
    func removeMainStageDevice() {
        mainStageEndpoint.removeDeviceManually()
    }

    func sendMainStageTestSelection(patchIndex: UInt8?, setIndex: UInt8?) {
        mainStageEndpoint.sendSelection(patchIndex: patchIndex, setIndex: setIndex)
        let patchText = patchIndex.map(String.init) ?? "n/a"
        let setText = setIndex.map(String.init) ?? "n/a"
        let description = "patchIndex \(patchText), setIndex \(setText)"
        DispatchQueue.main.async { [weak self] in
            self?.mainStageLastSelectionSent = description
        }
        appendLog("-> MainStage selection: \(description)")
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

    // MARK: - MainStage bridge event handling
    //
    // `handleMainStage`/`setMainStageLive` are invoked by
    // `MainStageEndpoint`'s callbacks, i.e. on `mainStageEndpoint.serialQueue`
    // - `nonisolated` for the same reason as `handle(_:)` above.

    nonisolated private func handleMainStage(_ inbound: MainStageInbound) {
        switch inbound {
        case .hello(let version, let appName):
            appendLog("<- MainStage bridge: Hello (protocol v\(version), app \"\(appName)\")")
        case .goodbye:
            appendLog("<- MainStage bridge: Goodbye")
            setMainStagePatchList(nil)
        case .heartbeat(let sequence):
            setMainStageHeartbeat(sequence: sequence)
        case .patchList(let patchList):
            appendLog("<- MainStage bridge: Patch List Dump (\(patchList.entries.count) entries, concert \"\(patchList.concertName)\")")
            setMainStagePatchList(patchList)
        }
    }

    nonisolated private func setMainStageLive(_ live: Bool) {
        DispatchQueue.main.async { [weak self] in self?.mainStageBridgeLive = live }
        appendLog("MainStage bridge \(live ? "live" : "down").")
    }

    nonisolated private func setMainStageEndpointPublished(_ published: Bool) {
        DispatchQueue.main.async { [weak self] in self?.mainStageEndpointPublished = published }
    }

    nonisolated private func setMainStageDeviceRegistration(registered: Bool, summary: String) {
        DispatchQueue.main.async { [weak self] in
            self?.mainStageDeviceRegistered = registered
            self?.mainStageDeviceRegistrationSummary = summary
        }
    }

    nonisolated private func setMainStageHeartbeat(sequence: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mainStageLastHeartbeatAt = Date()
            self.mainStageLastHeartbeatSeq = sequence
        }
    }

    nonisolated private func setMainStagePatchList(_ patchList: MainStagePatchList?) {
        DispatchQueue.main.async { [weak self] in self?.mainStagePatchList = patchList }
    }

    /// The plan's "is MainStage running" check
    /// (docs/mainstage-integration.md's "Connection status" section, step
    /// 2). **Finding, confirmed by running the actual sandboxed, signed
    /// Debug build**: `NSWorkspace.shared.runningApplications` works fine
    /// under App Sandbox (`ENABLE_APP_SANDBOX = YES`, confirmed via
    /// `codesign -d --entitlements`) with no extra entitlement - a direct
    /// run of the built `.app` logged `NSWorkspace reports 98 running
    /// app(s)` (a real, non-empty list, with MainStage correctly reported
    /// not running since it wasn't launched for that check) - so no
    /// fallback to a combined state was needed here. Process enumeration
    /// simply isn't one of the operations App Sandbox restricts (unlike
    /// file/network/device access). This only distinguishes "MainStage not
    /// running" from "running" though - it says nothing about whether the
    /// device script actually bound; that's `mainStageBridgeLive`, driven
    /// by `MainStageEndpoint`'s own heartbeat-timeout logic. `nonisolated`
    /// so it's safe to call both directly from `init()` and from the
    /// `Timer` closure `init()` schedules (which isn't main-actor-isolated
    /// by its own type).

    /// MainStage's real bundle identifier is version-suffixed:
    /// `com.apple.mainstage3` for MainStage 3.x, verified against both
    /// `/Applications/MainStage.app` and the running process on this
    /// machine. An earlier revision compared against a bare
    /// `com.apple.mainstage`, which matches nothing and made the app report
    /// "MainStage not running" while it was plainly running.
    ///
    /// Prefix-matching rather than hardcoding `3` so a future MainStage 4
    /// doesn't silently reintroduce the same bug. If Apple ever ships an
    /// unrelated `com.apple.mainstageSomethingElse` this would over-match,
    /// which is the harmless direction to fail in - it only drives a status
    /// label, never behaviour.
    nonisolated static func isMainStageBundleID(_ identifier: String?) -> Bool {
        identifier?.hasPrefix("com.apple.mainstage") ?? false
    }

    nonisolated func refreshMainStageProcessRunning() {
        let apps = NSWorkspace.shared.runningApplications
        let running = apps.contains { Self.isMainStageBundleID($0.bundleIdentifier) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.mainStageProcessRunning == nil {
                // First check: prove the sandboxed call actually works by
                // logging the total count too, not just the boolean - an
                // empty/zero list here would be the tell that App Sandbox
                // silently restricted this.
                let message = "MainStage process check: NSWorkspace reports \(apps.count) running app(s); MainStage running = \(running)."
                self.appendLog(message)
            }
            self.mainStageProcessRunning = running
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
