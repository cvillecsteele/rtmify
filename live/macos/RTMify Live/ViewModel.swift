import Foundation
import SwiftUI
import ServiceManagement
import Darwin

enum AppState {
    case licenseGate
    case stopped
    case starting
    case restarting(port: Int, attempt: Int, maxAttempts: Int, nextDelaySeconds: Int, reason: String)
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
    private var restartPolicy = RestartPolicy(maxRetries: 3, delaysSeconds: [2, 4, 8])
    private var restartAttempt = 0
    private var intentionalStopInProgress = false
    private var outputBuffer = OutputRingBuffer()
    private var lastKnownDashboardURL: String? = nil
    private var scheduledRestartTask: Task<Void, Never>? = nil

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
        restartAttempt = 0
        intentionalStopInProgress = false
        outputBuffer.reset()
        scheduledRestartTask?.cancel()
        scheduledRestartTask = nil
        launchServer(openDashboardOnLaunch: openDashboardOnLaunch, isRestart: false)
    }

    private func launchServer(openDashboardOnLaunch: Bool, isRestart: Bool) {
        guard let binary = binaryPath() else {
            state = .error(message: "rtmify-live binary not found in Resources.")
            return
        }

        state = .starting
        port = findAvailablePort()
        intentionalStopInProgress = false

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--port", "\(port)", "--no-browser"]
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dataDir = appSupport.appendingPathComponent("RTMify Live")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        process.currentDirectoryURL = dataDir
        var environment = ProcessInfo.processInfo.environment
        environment["RTMIFY_TRAY_APP_VERSION"] = trayAppVersionString()
        environment["RTMIFY_LOG_PATH"] = serverLogURL().path
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let logURL = serverLogURL()
        writeLogHeader(logURL, port: port, binary: binary)
        let pidPlaceholder = Int32(process.processIdentifier)

        process.terminationHandler = { [weak self] proc in
            appendLogLine("server terminated with code \(proc.terminationStatus)", to: logURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let priorState = self.lifecycleStateForCurrentAppState()
                let disposition = CrashSupervisor.classifyTermination(
                    priorState: priorState,
                    wasIntentionalStop: self.intentionalStopInProgress,
                    terminationStatus: proc.terminationStatus
                )
                let snapshot = CrashSnapshot(
                    port: self.port,
                    pid: proc.processIdentifier == 0 ? pidPlaceholder : proc.processIdentifier,
                    priorState: priorState,
                    terminationStatus: proc.terminationStatus,
                    attempt: self.restartAttempt,
                    maxAttempts: self.restartPolicy.maxRetries,
                    recentOutput: self.outputBuffer.snapshot(),
                    lastSyncAt: self.lastSyncAt,
                    lastScanAt: self.lastScanAt,
                    lastKnownURL: self.lastKnownDashboardURL
                )
                appendCrashSnapshot(snapshot, to: logURL)
                self.stopStatusPolling()
                self.serverProcess = nil
                self.scheduledRestartTask?.cancel()
                self.scheduledRestartTask = nil

                let decision = CrashSupervisor.decideRestart(
                    priorState: priorState,
                    disposition: disposition,
                    currentAttempt: self.restartAttempt,
                    policy: self.restartPolicy
                )

                switch decision {
                case .noRestart(let finalMessage):
                    self.intentionalStopInProgress = false
                    self.outputBuffer.reset()
                    if case .intentionalStop = disposition {
                        self.restartAttempt = 0
                        self.state = .stopped
                    } else {
                        self.state = .error(message: finalMessage)
                    }
                case .restart(let delay, let nextAttempt, let message):
                    self.restartAttempt = nextAttempt
                    self.state = .restarting(
                        port: self.port,
                        attempt: nextAttempt,
                        maxAttempts: self.restartPolicy.maxRetries,
                        nextDelaySeconds: delay,
                        reason: "exited with code \(proc.terminationStatus)"
                    )
                    self.scheduledRestartTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        appendLogLine(message, to: logURL)
                        self.launchServer(openDashboardOnLaunch: false, isRestart: true)
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
        if !isRestart {
            outputBuffer.reset()
        }

        // Watch combined output for the server listen log to confirm startup.
        let handle = pipe.fileHandleForReading
        Task {
            var buf = Data()
            for try await chunk in handle.bytes {
                buf.append(chunk)
                let data = Data([chunk])
                appendLogData(data, to: logURL)
                await MainActor.run { [weak self] in
                    self?.outputBuffer.append(data)
                }
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
                    return
                }
                self.serverDidStart(openDashboardOnLaunch: openDashboardOnLaunch)
            }
        }
    }

    func stop() {
        intentionalStopInProgress = true
        restartAttempt = 0
        scheduledRestartTask?.cancel()
        scheduledRestartTask = nil
        if let process = serverProcess {
            appendLogLine("stopping server pid=\(process.processIdentifier)", to: serverLogURL())
            terminateProcessTree(process)
        }
        serverProcess = nil
        stopStatusPolling()
        outputBuffer.reset()
        if case .running = state { state = .stopped }
        if case .starting = state { state = .stopped }
        if case .restarting = state { state = .stopped }
    }

    func quitApp() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    func openDashboard() {
        if case .running(let p) = state {
            let url = "http://localhost:\(p)"
            lastKnownDashboardURL = url
            NSWorkspace.shared.open(URL(string: url)!)
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
        intentionalStopInProgress = false
        state = .running(port: port)
        lastKnownDashboardURL = "http://localhost:\(port)"
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

    private func lifecycleStateForCurrentAppState() -> ServerLifecycleState {
        switch state {
        case .licenseGate, .stopped:
            return .stopped
        case .starting:
            return .starting
        case .restarting(let port, let attempt, let maxAttempts, let nextDelaySeconds, let reason):
            return .restarting(port: port, attempt: attempt, maxAttempts: maxAttempts, nextDelaySeconds: nextDelaySeconds, reason: reason)
        case .running(let port):
            return .running(port: port)
        case .error(let message):
            return .error(message: message)
        }
    }
}

private func trayAppVersionString() -> String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    switch (short, build) {
    case let (s?, b?) where !s.isEmpty && !b.isEmpty:
        return "\(s) (\(b))"
    case let (s?, _):
        return s
    case let (_, b?):
        return b
    default:
        return "not available"
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

private func appendCrashSnapshot(_ snapshot: CrashSnapshot, to url: URL) {
    var lines: [String] = []
    lines.append("[shim] crash detected")
    lines.append("[shim] prior_state=\(snapshot.priorState)")
    lines.append("[shim] pid=\(snapshot.pid.map(String.init) ?? "unknown") termination_status=\(snapshot.terminationStatus)")
    lines.append("[shim] restart_attempt=\(snapshot.attempt)/\(snapshot.maxAttempts)")
    lines.append("[shim] last_sync_at=\(snapshot.lastSyncAt ?? "unknown")")
    lines.append("[shim] last_scan_at=\(snapshot.lastScanAt ?? "unknown")")
    lines.append("[shim] last_dashboard_url=\(snapshot.lastKnownURL ?? "unknown")")
    lines.append("[shim] recent_output_begin")
    let output = snapshot.recentOutput.isEmpty ? "<empty>" : snapshot.recentOutput
    lines.append(output)
    lines.append("[shim] recent_output_end")
    appendLogString(lines.joined(separator: "\n") + "\n", to: url)
}
