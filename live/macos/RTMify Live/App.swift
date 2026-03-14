import SwiftUI
import ServiceManagement
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: ViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        viewModel?.stop()
        return .terminateNow
    }
}

@main
struct RTMifyLiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject var vm = ViewModel()

    init() {
        appDelegate.viewModel = vm
    }

    var body: some Scene {
        MenuBarExtra("RTMify Live", systemImage: "link.badge.plus") {
            MenuBarView()
                .environmentObject(vm)
        }
        .menuBarExtraStyle(.menu)

        Window("License", id: "license") {
            LicenseGateView()
                .environmentObject(vm)
                .frame(width: 460, height: 420)
        }
        .windowResizability(.contentSize)
    }
}
