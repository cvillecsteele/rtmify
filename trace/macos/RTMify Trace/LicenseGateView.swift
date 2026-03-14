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
                Text("Trace")
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("License")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(vm.licenseStatusMessage ?? "Import a signed RTMify Trace license file or place it at ~/.rtmify/license.json.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Manual path: ~/.rtmify/license.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let err = vm.licenseError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let fingerprint = vm.expectedKeyFingerprint {
                    Text("Build fingerprint: \(fingerprint.prefix(12))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 40)

            Button(action: { vm.importLicense() }) {
                if vm.isInstallingLicense {
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

            Link("Need a license?", destination: URL(string: "https://rtmify.io/pricing/")!)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
