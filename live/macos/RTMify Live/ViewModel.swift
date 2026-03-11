import Foundation
import SwiftUI
import ServiceManagement
import Darwin

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

    func start(openDashboardOnLaunch: Bool = true) {
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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dataDir = appSupport.appendingPathComponent("RTMify Live")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        process.currentDirectoryURL = dataDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let logURL = serverLogURL()
        writeLogHeader(logURL, port: port, binary: binary)

        process.terminationHandler = { [weak self] proc in
            appendLogLine("server terminated with code \(proc.terminationStatus)", to: logURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopStatusPolling()
                if case .running = self.state {
                    if self.restartCount < 3 {
                        self.restartCount += 1
                        self.state = .stopped
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        self.start(openDashboardOnLaunch: false)
                    } else {
                        self.state = .error(message: "Server crashed repeatedly (code \(proc.terminationStatus))")
                    }
                }
            }
        }

        do {
            try process.run()
            appendLogLine("started server pid=\(process.processIdentifier) port=\(port)", to: logURL)
        } catch {
            appendLogLine("failed to start server: \(error.localizedDescription)", to: logURL)
            state = .error(message: "Failed to start: \(error.localizedDescription)")
            return
        }

        serverProcess = process

        // Watch combined output for the server listen log to confirm startup.
        let handle = pipe.fileHandleForReading
        Task {
            var buf = Data()
            for try await chunk in handle.bytes {
                buf.append(chunk)
                appendLogData(Data([chunk]), to: logURL)
                if let str = String(data: buf, encoding: .utf8),
                   str.localizedCaseInsensitiveContains("listening")
                {
                    await MainActor.run { [weak self] in
                        self?.serverDidStart(openDashboardOnLaunch: openDashboardOnLaunch)
                    }
                    return
                }
            }
        }

        // Fallback: if the process is still alive after a short delay, mark it running
        // even if no listen log line has been observed yet.
        Task { [weak self, weak process] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                guard let self else { return }
                guard case .starting = self.state else { return }
                guard let process, process.isRunning else {
                    appendLogLine("server exited before startup completed", to: logURL)
                    self.state = .error(message: "Server exited during startup.")
                    return
                }
                self.serverDidStart(openDashboardOnLaunch: openDashboardOnLaunch)
            }
        }
    }

    func stop() {
        restartCount = 0
        if let process = serverProcess {
            appendLogLine("stopping server pid=\(process.processIdentifier)", to: serverLogURL())
            terminateProcessTree(process)
        }
        serverProcess = nil
        stopStatusPolling()
        if case .running = state { state = .stopped }
        if case .starting = state { state = .stopped }
    }

    func quitApp() {
        stop()
        NSApplication.shared.terminate(nil)
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
                    let payload = StatusPayload.from(json: json)
                    lastSyncAt = payload.lastSyncAt
                    lastScanAt = payload.lastScanAt
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

    private func serverDidStart(openDashboardOnLaunch: Bool) {
        state = .running(port: port)
        startStatusPolling()
        if openDashboardOnLaunch {
            openDashboard()
        }
    }

    private func terminateProcessTree(_ process: Process) {
        let pid = process.processIdentifier
        process.terminate()
        let deadline = Date().addingTimeInterval(0.75)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            appendLogLine("forcing server pid=\(pid) down with SIGKILL", to: serverLogURL())
            kill(pid, SIGKILL)
        }
    }

    private func findAvailablePort() -> Int {
        let selected = PortSelection.firstAvailable { [self] candidate in
            portAvailable(candidate)
        }
        UserDefaults.standard.set(selected, forKey: "server_port")
        return selected
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

private func serverLogURL() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dir = home.appendingPathComponent(".rtmify", isDirectory: true)
        .appendingPathComponent("log", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("server.log")
}

private func writeLogHeader(_ url: URL, port: Int, binary: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let header = "\n=== RTMify Live session \(timestamp) port=\(port) binary=\(binary) ===\n"
    appendLogString(header, to: url)
}

private func appendLogLine(_ line: String, to url: URL) {
    appendLogString("[shim] \(line)\n", to: url)
}

private func appendLogString(_ string: String, to url: URL) {
    guard let data = string.data(using: .utf8) else { return }
    appendLogData(data, to: url)
}

private func appendLogData(_ data: Data, to url: URL) {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}
