import SwiftUI

/// Developer console: endpoint lists, session state, a hex-annotated
/// bidirectional log, and controls to force identify/logout/repaint and to
/// flip the two protocol variants from the project plan's "Two
/// discrepancies" section - since none of this can be verified against
/// hardware in this environment, everything here is meant to be exercised
/// (and, if needed, toggled) by whoever runs it against a real SL88 MK2.
struct ContentView: View {
    @ObservedObject var controller: SLLinkController

    @State private var hostIDText: String = ""
    @State private var deviceIDText: String = ""
    @State private var testPatchIndexText: String = "0"
    @State private var testSetIndexText: String = "0"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack {
                Text("SL Link MainStage")
                    .font(.title)

                Spacer()

                Button("Refresh MIDI") { controller.refreshEndpoints() }
                Button("Connect + Identify") { controller.connect() }
                Button("Force Identify") { controller.forceIdentify() }
                Button("Force Logout") { controller.forceLogout() }
                Button("Force Repaint") { controller.forceRepaint() }
            }

            HStack {
                Text("Session: \(sessionDescription)")
                    .font(.system(.body, design: .monospaced))
                Text("(\(Self.describe(model: controller.model, firmware: controller.firmwareVersion)))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Append name to keepalive (reference-impl variant)", isOn: $controller.useNameInKeepalive)
                Divider().frame(height: 20)
                Text("HostID")
                TextField("HostID", text: $hostIDText)
                    .frame(width: 50)
                    .onSubmit(commitIDPair)
                Text("DeviceID")
                TextField("DeviceID", text: $deviceIDText)
                    .frame(width: 50)
                    .onSubmit(commitIDPair)
                Button("Set") { commitIDPair() }
            }

            Divider()

            GroupBox("MIDI Sources") {
                List(controller.sources, id: \.self) { source in
                    Text(source).font(.system(.body, design: .monospaced))
                }
                .frame(height: 100)
            }

            GroupBox("MIDI Destinations") {
                List(controller.destinations, id: \.self) { destination in
                    Text(destination).font(.system(.body, design: .monospaced))
                }
                .frame(height: 100)
            }

            GroupBox("MainStage Bridge") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Endpoint: \(controller.mainStageEndpointPublished ? "published" : "NOT published")")
                        Divider().frame(height: 14)
                        Text("Bridge: \(controller.mainStageBridgeLive ? "LIVE" : "down")")
                            .foregroundStyle(controller.mainStageBridgeLive ? .green : .secondary)
                        Divider().frame(height: 14)
                        Text("MainStage process: \(mainStageProcessText)")
                        Divider().frame(height: 14)
                        Text("Device: \(controller.mainStageDeviceRegistered ? "registered" : "NOT registered")")
                            .foregroundStyle(controller.mainStageDeviceRegistered ? .green : .secondary)
                        Spacer()
                        Button("Check Now") { controller.refreshMainStageProcessRunning() }
                        Button("Remove Device") { controller.removeMainStageDevice() }
                    }
                    .font(.system(.caption, design: .monospaced))

                    Text("Device registration: \(controller.mainStageDeviceRegistrationSummary) (spike - see docs/mainstage-integration.md; bare endpoint above is the working path regardless)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("Last heartbeat: \(lastHeartbeatText)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("Patch list: \(patchListSummary)")
                        .font(.system(.caption, design: .monospaced))

                    HStack {
                        Text("Test selection - PatchIndex")
                        TextField("PatchIndex", text: $testPatchIndexText).frame(width: 40)
                        Text("SetIndex")
                        TextField("SetIndex", text: $testSetIndexText).frame(width: 40)
                        Button("Send Selection") { sendTestSelection() }
                        Spacer()
                        Text("Last sent: \(controller.mainStageLastSelectionSent ?? "none")")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }

            GroupBox("MIDI Log") {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(Array(controller.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .frame(minWidth: 900, minHeight: 650)
        .onAppear {
            hostIDText = String(controller.hostID)
            deviceIDText = String(controller.deviceInstanceID)
        }
    }

    private var sessionDescription: String {
        switch controller.state {
        case .idle: return "idle"
        case .identifying: return "identifying..."
        case .listed: return "listed - waiting for login on keyboard"
        case .active(let model, let fw): return "ACTIVE (\(Self.describe(model: model, firmware: fw)))"
        case .standby(let model, let fw): return "standby (\(Self.describe(model: model, firmware: fw)))"
        }
    }

    /// Real hardware doesn't always report firmware/model (see CLAUDE.md);
    /// render "unknown" rather than "Optional(...)" when it hasn't.
    private static func describe(model: SLModel?, firmware: (UInt8, UInt8, UInt8)?) -> String {
        let modelText = model.map { "\($0)" } ?? "unknown model"
        let firmwareText = firmware.map { "\($0.0).\($0.1).\($0.2)" } ?? "unknown firmware"
        return "\(modelText), fw \(firmwareText)"
    }

    private func commitIDPair() {
        guard let id1 = UInt8(hostIDText), let id2 = UInt8(deviceIDText) else { return }
        controller.setIDPair(id1: id1, id2: id2)
    }

    // MARK: - MainStage bridge dev-console helpers

    private var mainStageProcessText: String {
        switch controller.mainStageProcessRunning {
        case .some(true): return "running"
        case .some(false): return "not running"
        case .none: return "unknown"
        }
    }

    private var lastHeartbeatText: String {
        guard let at = controller.mainStageLastHeartbeatAt else { return "none yet" }
        let seq = controller.mainStageLastHeartbeatSeq.map { " (seq \($0))" } ?? ""
        let secondsAgo = Int(Date().timeIntervalSince(at))
        return "\(secondsAgo)s ago\(seq)"
    }

    private var patchListSummary: String {
        guard let list = controller.mainStagePatchList else { return "none (waiting for MainStage)" }
        let songCount = list.entries.filter { !$0.isPatch }.count
        let patchCount = list.entries.filter(\.isPatch).count
        return "\"\(list.concertName)\" - \(songCount) song(s), \(patchCount) patch(es)"
    }

    /// Manual verification aid for the virtual-endpoint gate (see the
    /// project plan): with MainStage running and the device script
    /// selected, this should make MainStage jump to the given patch.
    private func sendTestSelection() {
        let patchIndex = UInt8(testPatchIndexText)
        let setIndex = UInt8(testSetIndexText)
        controller.sendMainStageTestSelection(patchIndex: patchIndex, setIndex: setIndex)
    }
}

#Preview {
    ContentView(controller: SLLinkController())
}
