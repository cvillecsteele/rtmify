import Foundation
import SwiftUI
import AppKit

struct FileSummary {
    let path: String
    let displayName: String
    let gapCount: Int
    let warningCount: Int
}

struct GenerateResult {
    let outputPaths: [String]
    let gapCount: Int
}

enum AppState {
    case licenseGate
    case dropZone
    case fileLoaded(summary: FileSummary)
    case generating
    case done(result: GenerateResult)
}

@MainActor
final class ViewModel: ObservableObject {
    @Published var state: AppState = .dropZone
    @Published var errorMessage: String? = nil
    @Published var licenseError: String? = nil
    @Published var licenseStatusMessage: String? = nil
    @Published var isInstallingLicense: Bool = false

    private var graph: OpaquePointer? = nil
    private var loadedPath: String? = nil

    // MARK: - License

    func checkLicense() {
        do {
            let status = try rtmifyLicenseStatus()
            licenseStatusMessage = message(for: status)
            state = status.permitsUse ? .dropZone : .licenseGate
        } catch {
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

        isInstallingLicense = true
        licenseError = nil
        Task {
            do {
                let status = try await rtmifyInstallLicense(path: url.path)
                isInstallingLicense = false
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
                let status = try await rtmifyClearLicense()
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
        Task {
            do {
                let g = try await rtmifyLoad(path: path)
                graph = g
                loadedPath = path
                let gaps = Int(rtmify_gap_count(g))
                let warnings = Int(rtmify_warning_count())
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                let summary = FileSummary(path: path, displayName: name,
                                         gapCount: gaps, warningCount: warnings)
                state = .fileLoaded(summary: summary)
            } catch let e as BridgeError {
                errorMessage = e.message
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clear() {
        freeGraph()
        state = .dropZone
    }

    // MARK: - Generation

    func generate(format: String) {
        guard let g = graph, let inputPath = loadedPath else { return }
        let gapCount = Int(rtmify_gap_count(g))
        let projectName = URL(fileURLWithPath: inputPath)
            .deletingPathExtension().lastPathComponent

        state = .generating

        Task {
            do {
                if format == "all" {
                    var paths: [String] = []
                    for fmt in ["pdf", "docx", "md"] {
                        let out = outputPath(forInput: inputPath, format: fmt)
                        try await rtmifyGenerate(graph: g, format: fmt,
                                                 outputPath: out, projectName: projectName)
                        paths.append(out)
                    }
                    try? await rtmifyRecordSuccessfulUse()
                    state = .done(result: GenerateResult(outputPaths: paths, gapCount: gapCount))
                } else {
                    let out = outputPath(forInput: inputPath, format: format)
                    try await rtmifyGenerate(graph: g, format: format,
                                             outputPath: out, projectName: projectName)
                    try? await rtmifyRecordSuccessfulUse()
                    state = .done(result: GenerateResult(outputPaths: [out], gapCount: gapCount))
                }
            } catch let e as BridgeError {
                // Restore file-loaded state on error
                let warnings = Int(rtmify_warning_count())
                let name = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent
                let summary = FileSummary(path: inputPath, displayName: name,
                                         gapCount: gapCount, warningCount: warnings)
                state = .fileLoaded(summary: summary)
                errorMessage = e.message
            } catch {
                state = .dropZone
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
            return "The license file signature is invalid or the file was modified."
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
}
