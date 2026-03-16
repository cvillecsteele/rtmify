import Foundation
import SwiftUI
import AppKit

enum TraceProfile: Int32, CaseIterable, Identifiable {
    case generic = 0
    case medical = 1
    case aerospace = 2
    case automotive = 3

    var id: Int32 { rawValue }

    var displayName: String {
        switch self {
        case .generic: return "Generic"
        case .medical: return "Medical"
        case .aerospace: return "Aerospace"
        case .automotive: return "Automotive"
        }
    }
}

struct AnalysisSummary {
    let profile: TraceProfile
    let shortName: String
    let displayName: String
    let standards: String
    let warningCount: Int
    let genericGapCount: Int
    let profileGapCount: Int
    let totalGapCount: Int
}

struct LoadedGraph {
    let graph: OpaquePointer
    let summary: AnalysisSummary
}

#if SWIFT_PACKAGE
struct BridgeError: Error {
    let message: String
}

struct LicenseStatus {
    let state: Int32
    let permitsUse: Bool
    let usingFreeRun: Bool
    let detailCode: Int32
    let expectedKeyFingerprint: String? = nil
    let licenseSigningKeyFingerprint: String? = nil
}

func rtmifyLoad(path: String, profile: TraceProfile) async throws -> LoadedGraph {
    throw BridgeError(message: "not available in tests")
}
func rtmifyGenerate(graph: OpaquePointer, format: String, outputPath: String, projectName: String) async throws {}
func rtmifyLicenseStatus() throws -> LicenseStatus { throw BridgeError(message: "not available in tests") }
func rtmifyInstallLicense(path: String) async throws -> LicenseStatus { throw BridgeError(message: "not available in tests") }
func rtmifyClearLicense() async throws -> LicenseStatus { throw BridgeError(message: "not available in tests") }
func rtmifyRecordSuccessfulUse() async throws {}
func rtmify_free(_ graph: OpaquePointer) {}
#endif

struct FileSummary {
    let path: String
    let displayName: String
    let analysis: AnalysisSummary
}

struct GenerateResult {
    let outputPaths: [String]
    let analysis: AnalysisSummary
}

enum AppState {
    case licenseGate
    case dropZone
    case loading(message: String)
    case fileLoaded(summary: FileSummary)
    case generating(message: String)
    case done(result: GenerateResult)
}

@MainActor
final class ViewModel: ObservableObject {
    typealias WorkbookLoader = (String, TraceProfile) async throws -> LoadedGraph
    typealias ReportGenerator = (OpaquePointer, String, String, String) async throws -> Void
    typealias LicenseStatusFetcher = () throws -> LicenseStatus
    typealias LicenseInstaller = (String) async throws -> LicenseStatus
    typealias LicenseClearer = () async throws -> LicenseStatus
    typealias SuccessfulUseRecorder = () async throws -> Void

    @Published var state: AppState = .dropZone
    @Published var selectedProfile: TraceProfile = .generic
    @Published var errorMessage: String? = nil
    @Published var licenseError: String? = nil
    @Published var licenseStatusMessage: String? = nil
    @Published var isInstallingLicense: Bool = false
    @Published var expectedKeyFingerprint: String? = nil

    private var graph: OpaquePointer? = nil
    private var loadedPath: String? = nil
    private let loadWorkbook: WorkbookLoader
    private let generateReport: ReportGenerator
    private let fetchLicenseStatus: LicenseStatusFetcher
    private let installLicenseAtPath: LicenseInstaller
    private let clearInstalledLicense: LicenseClearer
    private let recordSuccessfulUse: SuccessfulUseRecorder

    init(
        loadWorkbook: @escaping WorkbookLoader = rtmifyLoad,
        generateReport: @escaping ReportGenerator = rtmifyGenerate,
        fetchLicenseStatus: @escaping LicenseStatusFetcher = rtmifyLicenseStatus,
        installLicenseAtPath: @escaping LicenseInstaller = rtmifyInstallLicense,
        clearInstalledLicense: @escaping LicenseClearer = rtmifyClearLicense,
        recordSuccessfulUse: @escaping SuccessfulUseRecorder = rtmifyRecordSuccessfulUse
    ) {
        self.loadWorkbook = loadWorkbook
        self.generateReport = generateReport
        self.fetchLicenseStatus = fetchLicenseStatus
        self.installLicenseAtPath = installLicenseAtPath
        self.clearInstalledLicense = clearInstalledLicense
        self.recordSuccessfulUse = recordSuccessfulUse
    }

    // MARK: - License

    func checkLicense() {
        do {
            let status = try fetchLicenseStatus()
            expectedKeyFingerprint = status.expectedKeyFingerprint
            licenseStatusMessage = message(for: status)
            state = status.permitsUse ? .dropZone : .licenseGate
        } catch {
            expectedKeyFingerprint = nil
            licenseStatusMessage = "Install a signed RTMify Trace license file to unlock future runs."
            state = .licenseGate
        }
    }

    func importLicense() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a signed RTMify Trace license file."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        importLicense(atPath: url.path)
    }

    func importLicense(atPath path: String) {
        isInstallingLicense = true
        licenseError = nil
        Task {
            do {
                let status = try await installLicenseAtPath(path)
                isInstallingLicense = false
                expectedKeyFingerprint = status.expectedKeyFingerprint
                licenseStatusMessage = message(for: status)
                state = status.permitsUse ? .dropZone : .licenseGate
            } catch let e as BridgeError {
                isInstallingLicense = false
                licenseError = e.message
            } catch {
                isInstallingLicense = false
                licenseError = error.localizedDescription
            }
        }
    }

    func clearLicense() {
        Task {
            do {
                let status = try await clearInstalledLicense()
                expectedKeyFingerprint = status.expectedKeyFingerprint
                licenseStatusMessage = message(for: status)
                freeGraph()
                state = status.permitsUse ? .dropZone : .licenseGate
            } catch let e as BridgeError {
                errorMessage = e.message
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - File loading

    func load(path: String) {
        freeGraph()
        state = .loading(message: "Analyzing workbook for \(selectedProfile.displayName) profile...")
        Task {
            do {
                let loaded = try await loadWorkbook(path, selectedProfile)
                graph = loaded.graph
                loadedPath = path
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                let summary = FileSummary(path: path, displayName: name, analysis: loaded.summary)
                state = .fileLoaded(summary: summary)
            } catch let e as BridgeError {
                state = .dropZone
                errorMessage = e.message
            } catch {
                state = .dropZone
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateSelectedProfile(_ profile: TraceProfile) {
        guard selectedProfile != profile else { return }
        selectedProfile = profile
        if let path = loadedPath {
            load(path: path)
        }
    }

    func clear() {
        freeGraph()
        state = .dropZone
    }

    // MARK: - Generation

    func generate(format: String) {
        guard let g = graph, let inputPath = loadedPath else { return }
        guard case .fileLoaded(let summary) = state else { return }
        let projectName = URL(fileURLWithPath: inputPath)
            .deletingPathExtension().lastPathComponent

        state = .generating(message: "Generating \(selectedProfile.displayName) report...")

        Task {
            do {
                if format == "all" {
                    var paths: [String] = []
                    for fmt in ["pdf", "docx", "md"] {
                        let out = outputPath(forInput: inputPath, format: fmt)
                        try await generateReport(g, fmt, out, projectName)
                        paths.append(out)
                    }
                    try? await recordSuccessfulUse()
                    state = .done(result: GenerateResult(outputPaths: paths, analysis: summary.analysis))
                } else {
                    let out = outputPath(forInput: inputPath, format: format)
                    try await generateReport(g, format, out, projectName)
                    try? await recordSuccessfulUse()
                    state = .done(result: GenerateResult(outputPaths: [out], analysis: summary.analysis))
                }
            } catch let e as BridgeError {
                state = .fileLoaded(summary: summary)
                errorMessage = e.message
            } catch {
                state = .fileLoaded(summary: summary)
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Private helpers

    private func freeGraph() {
        if let g = graph {
            rtmify_free(g)
            graph = nil
            loadedPath = nil
        }
    }

    private func outputPath(forInput input: String, format: String, suffix: Int = 0) -> String {
        let base = URL(fileURLWithPath: input).deletingPathExtension().path + "-rtm"
        let ext = format == "docx" ? "docx" : format == "pdf" ? "pdf" : "md"
        let candidate = suffix == 0 ? "\(base).\(ext)" : "\(base)-\(suffix).\(ext)"
        return FileManager.default.fileExists(atPath: candidate)
            ? outputPath(forInput: input, format: format, suffix: suffix + 1)
            : candidate
    }

    deinit {
        if let g = graph {
            rtmify_free(g)
        }
    }

    private func message(for status: LicenseStatus) -> String {
        switch status.detailCode {
        case 1:
            return "You can use RTMify Trace once without a license. The first successful report will consume that free run."
        case 2:
            return "Your one free RTMify Trace run has been used. Import a signed license file or place it at ~/.rtmify/license.json."
        case 3:
            return "No installed license file was found. Place license.json at ~/.rtmify/license.json or import it here."
        case 8:
            return "The installed license file has expired."
        case 5:
            if let file = status.licenseSigningKeyFingerprint,
               let expected = status.expectedKeyFingerprint {
                return "This license was signed with key \(shortFingerprint(file)), but this build expects \(shortFingerprint(expected))."
            }
            if let expected = status.expectedKeyFingerprint {
                return "This build expects licenses signed with key \(shortFingerprint(expected))."
            }
            return "The license file signature does not match this build."
        case 6:
            return "This license file is for a different RTMify product."
        case 4, 7:
            return "The license file is not a valid RTMify Trace license."
        default:
            if status.permitsUse && status.usingFreeRun {
                return "Free run available."
            }
            if status.permitsUse {
                return "Valid license installed."
            }
            return "Install a signed RTMify Trace license file to continue."
        }
    }

    private func shortFingerprint(_ fingerprint: String) -> String {
        String(fingerprint.prefix(12))
    }
}
