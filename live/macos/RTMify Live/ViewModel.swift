import Foundation
import SwiftUI
import ServiceManagement

enum AppState {
    case licenseGate
    case stopped
    case starting
    case running(port: Int)
    case error(message: String)
}

@MainActor
final class ViewModel: ObservableObject {
    @Published var state: AppState = .stopped
    @Published var lastSyncAt: String? = nil
    @Published var lastScanAt: String? = nil
    @Published var activationError: String? = nil
    @Published var isActivating: Bool = false
    @Published var launchAtLogin: Bool = false

    private var serverProcess: Process? = nil
    private var statusTimer: Timer? = nil
    private var port: Int = 8000
    private var restartCount = 0

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        checkLicense()
    }

    // MARK: - License

    func checkLicense() {
        Task {
            let ok = await runLicenseCheck()
            state = ok ? .stopped : .licenseGate
        }
    }

    private func runLicenseCheck() async -> Bool {
        guard let binary = binaryPath() else { return false }
        let result = await runCommand(binary, args: ["--version"])
        return result.exitCode == 0
    }

    func activate(key: String) {
        guard !key.isEmpty else {
            activationError = "Please enter a license key."
            return
        }
        isActivating = true
        activationError = nil
        Task {
            guard let binary = binaryPath() else {
                isActivating = false
                activationError = "rtmify-live binary not found."
                return
            }
            let result = await runCommand(binary, args: ["--activate", key])
            isActivating = false
            if result.exitCode == 0 {
                state = .stopped
            } else {
                activationError = result.stderr.isEmpty ? "Activation failed. Check your key and internet connection." : result.stderr
            }
        }
    }

    func deactivate() {
        guard let binary = binaryPath() else { return }
        Task {
            _ = await runCommand(binary, args: ["--deactivate"])
            stop()
            state = .licenseGate
        }
    }

    // MARK: - Server control

    func start() {
        guard case .stopped = state else { return }
        guard let binary = binaryPath() else {
            state = .error(message: "rtmify-live binary not found in Resources.")
            return
        }

        state = .starting
        port = findAvailablePort()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--port", "\(port)", "--no-browser"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopStatusPolling()
                if case .running = self.state {
                    if self.restartCount < 3 {
                        self.restartCount += 1
                        self.state = .stopped
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        self.start()
                    } else {
                        self.state = .error(message: "Server crashed repeatedly (code \(proc.terminationStatus))")
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            state = .error(message: "Failed to start: \(error.localizedDescription)")
            return
        }

        serverProcess = process

        // Watch stdout for "Listening" to confirm startup
        let handle = pipe.fileHandleForReading
        Task {
            var buf = Data()
            for try await chunk in handle.bytes {
                buf.append(chunk)
                if let str = String(data: buf, encoding: .utf8), str.contains("Listening") {
                    await MainActor.run { [weak self] in
                        self?.state = .running(port: self?.port ?? 8000)
                        self?.startStatusPolling()
                    }
                    return
                }
                // Give up waiting after 8 seconds and assume running
                if buf.count > 65536 { break }
            }
            // Fallback: assume running after brief delay
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if case .starting = self.state {
                self.state = .running(port: self.port)
                self.startStatusPolling()
            }
        }
    }

    func stop() {
        restartCount = 0
        serverProcess?.terminate()
        serverProcess = nil
        stopStatusPolling()
        if case .running = state { state = .stopped }
        if case .starting = state { state = .stopped }
    }

    func openDashboard() {
        if case .running(let p) = state {
            NSWorkspace.shared.open(URL(string: "http://localhost:\(p)")!)
        }
    }

    // MARK: - Launch at login

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            // Silently ignore
        }
    }

    // MARK: - Status polling

    private func startStatusPolling() {
        stopStatusPolling()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollStatus() }
        }
        pollStatus()
    }

    private func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func pollStatus() {
        guard case .running(let p) = state else { return }
        Task {
            guard let url = URL(string: "http://localhost:\(p)/api/status") else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let ts = json["last_sync_at"] as? String {
                        lastSyncAt = ts
                    }
                    if let sc = json["last_scan_at"] as? String, sc != "never" {
                        lastScanAt = sc
                    }
                }
            } catch {}
        }
    }

    // MARK: - Helpers

    private func binaryPath() -> String? {
        // When running from app bundle, binary is in Resources/
        if let bundled = Bundle.main.path(forResource: "rtmify-live", ofType: nil) {
            return bundled
        }
        // Dev fallback: look next to the app
        let devPath = Bundle.main.bundlePath + "/../rtmify-live"
        if FileManager.default.fileExists(atPath: devPath) { return devPath }
        return nil
    }

    private func findAvailablePort() -> Int {
        let stored = UserDefaults.standard.integer(forKey: "server_port")
        let start = stored > 0 ? stored : 8000
        for p in start...(start + 10) {
            if portAvailable(p) {
                UserDefaults.standard.set(p, forKey: "server_port")
                return p
            }
        }
        return start
    }

    private func portAvailable(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        return withUnsafeBytes(of: &addr) { ptr in
            bind(sock, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }

    private struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runCommand(_ path: String, args: [String]) async -> CommandResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                } catch {}
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: CommandResult(exitCode: proc.terminationStatus, stdout: out, stderr: err.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}
