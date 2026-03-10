import SwiftUI
import ServiceManagement

@main
struct RTMifyLiveApp: App {
    @StateObject var vm = ViewModel()

    var body: some Scene {
        MenuBarExtra("RTMify Live", systemImage: "link.badge.plus") {
            MenuBarView()
                .environmentObject(vm)
        }
        .menuBarExtraStyle(.menu)

        Window("License", id: "license") {
            LicenseGateView()
                .environmentObject(vm)
                .frame(width: 400, height: 320)
        }
        .windowResizability(.contentSize)
    }
}
