import SwiftUI
import AppKit

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
        case .stopped:
            Label(MenuBarPresentation.stoppedLabel(permitsUse: vm.permitsUse), systemImage: vm.permitsUse ? "stop.circle" : "eye.circle")
                .foregroundStyle(.secondary)
        case .starting:
            Label(MenuBarPresentation.startingLabel(permitsUse: vm.permitsUse), systemImage: "arrow.clockwise.circle")
                .foregroundStyle(.secondary)
        case .restarting(_, let attempt, let maxAttempts, let nextDelaySeconds, let reason):
            VStack(alignment: .leading) {
                Label(MenuBarPresentation.restartingLabel(attempt: attempt, maxAttempts: maxAttempts, permitsUse: vm.permitsUse), systemImage: "arrow.triangle.2.circlepath.circle")
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
                Label(MenuBarPresentation.runningLabel(port: port, permitsUse: vm.permitsUse), systemImage: vm.permitsUse ? "checkmark.circle" : "eye.circle")
                    .foregroundStyle(vm.permitsUse ? .green : .orange)
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
        case .stopped, .error:
            Button(MenuBarPresentation.startActionLabel(permitsUse: vm.permitsUse)) { vm.start() }
        case .starting:
            Button(MenuBarPresentation.startingLabel(permitsUse: vm.permitsUse)) {}.disabled(true)
        case .restarting:
            Button("Stop Server") { vm.stop() }
        case .running:
            Button("Open Dashboard") { vm.openDashboard() }
            Button("Stop Server") { vm.stop() }
        }
    }

    private var settingsActions: some View {
        Group {
            Button(MenuBarPresentation.licenseActionLabel(permitsUse: vm.permitsUse)) {
                openWindow(id: "license")
                NSApp.activate(ignoringOtherApps: true)
            }
            Toggle("Launch at Login", isOn: Binding(
                get: { vm.launchAtLogin },
                set: { _ in vm.toggleLaunchAtLogin() }
            ))
            Divider()
            Button("Quit RTMify Live") { vm.quitApp() }
        }
    }
}
