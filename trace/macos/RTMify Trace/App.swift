import SwiftUI

@main
struct RTMifyTraceApp: App {
    @StateObject var vm = ViewModel()
    @State private var showClearLicenseConfirm = false

    var body: some Scene {
        Window("RTMify Trace", id: "main") {
            ContentView()
                .environmentObject(vm)
                .frame(width: 480, height: 520)
                .onAppear { vm.checkLicense() }
                .alert("Clear Installed License", isPresented: $showClearLicenseConfirm) {
                    Button("Clear License", role: .destructive) { vm.clearLicense() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the installed RTMify Trace license file from this Mac. If your free run has already been used, the app will return to the license gate.")
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Clear Installed License...") {
                    showClearLicenseConfirm = true
                }
            }
        }
    }
}
