import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var vm: ViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            statusLabel
            Divider()
            mainActions
            Divider()
            settingsActions
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch vm.state {
        case .licenseGate:
            Label("License required", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        case .stopped:
            Label("Server stopped", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        case .starting:
            Label("Starting…", systemImage: "arrow.clockwise.circle")
                .foregroundStyle(.secondary)
        case .restarting(_, let attempt, let maxAttempts, let nextDelaySeconds, let reason):
            VStack(alignment: .leading) {
                Label("Restarting server (attempt \(attempt)/\(maxAttempts))…", systemImage: "arrow.triangle.2.circlepath.circle")
                    .foregroundStyle(.orange)
                Text("Retrying in \(nextDelaySeconds)s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Reason: \(reason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .running(let port):
            VStack(alignment: .leading) {
                Label("Running on :\(String(port))", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                if let ts = vm.lastSyncAt {
                    Text("Last sync: \(ts)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let sc = vm.lastScanAt {
                    Text("Last scan: \(sc)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var mainActions: some View {
        switch vm.state {
        case .licenseGate:
            Button("Enter License Key…") {
                openWindow(id: "license")
            }
        case .stopped, .error:
            Button("Start Server") { vm.start() }
        case .starting:
            Button("Starting…") {}.disabled(true)
        case .restarting:
            Button("Stop Server") { vm.stop() }
        case .running:
            Button("Open Dashboard") { vm.openDashboard() }
            Button("Stop Server") { vm.stop() }
        }
    }

    private var settingsActions: some View {
        Group {
            Toggle("Launch at Login", isOn: Binding(
                get: { vm.launchAtLogin },
                set: { _ in vm.toggleLaunchAtLogin() }
            ))
            Divider()
            Button("Quit RTMify Live") { vm.quitApp() }
        }
    }
}
