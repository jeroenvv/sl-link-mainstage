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
}

#Preview {
    ContentView(controller: SLLinkController())
}
