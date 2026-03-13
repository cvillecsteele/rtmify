import SwiftUI

struct LicenseGateView: View {
    @EnvironmentObject var vm: ViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 6) {
                Text("RTMify")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Live")
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("License File")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Import a signed RTMify Live license file, or place it manually at ~/.rtmify/license.json.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let err = vm.activationError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 40)

            Button(action: { vm.importLicense() }) {
                if vm.isActivating {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text("Importing...")
                    }
                } else {
                    Text("Import License File")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Clear Installed License") {
                vm.clearLicense()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Link("Need a license?", destination: URL(string: "https://store.rtmify.io")!)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
