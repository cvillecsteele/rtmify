import Foundation

enum ServerLifecycleState: Equatable {
    case stopped
    case starting
    case running(port: Int)
    case restarting(port: Int, attempt: Int, maxAttempts: Int, nextDelaySeconds: Int, reason: String)
    case error(message: String)
}

enum ExitDisposition: Equatable {
    case intentionalStop
    case unexpectedExit(status: Int32)
}

struct RestartPolicy: Equatable {
    let maxRetries: Int
    let delaysSeconds: [Int]
}

struct CrashSnapshot: Equatable {
    let port: Int
    let pid: Int32?
    let priorState: ServerLifecycleState
    let terminationStatus: Int32
    let attempt: Int
    let maxAttempts: Int
    let recentOutput: String
    let lastSyncAt: String?
    let lastScanAt: String?
    let lastKnownURL: String?
}

enum RestartDecision: Equatable {
    case noRestart(finalMessage: String)
    case restart(afterSeconds: Int, nextAttempt: Int, message: String)
}

enum CrashSupervisor {
    static func classifyTermination(
        priorState: ServerLifecycleState,
        wasIntentionalStop: Bool,
        terminationStatus: Int32
    ) -> ExitDisposition {
        if wasIntentionalStop {
            return .intentionalStop
        }
        return .unexpectedExit(status: terminationStatus)
    }

    static func decideRestart(
        priorState: ServerLifecycleState,
        disposition: ExitDisposition,
        currentAttempt: Int,
        policy: RestartPolicy
    ) -> RestartDecision {
        switch disposition {
        case .intentionalStop:
            return .noRestart(finalMessage: "Stopped")
        case .unexpectedExit(let status):
            switch priorState {
            case .starting, .running, .restarting:
                guard currentAttempt < policy.maxRetries else {
                    return .noRestart(finalMessage: "Server crashed repeatedly (code \(status))")
                }
                let delay = policy.delaysSeconds.indices.contains(currentAttempt)
                    ? policy.delaysSeconds[currentAttempt]
                    : (policy.delaysSeconds.last ?? 2)
                let nextAttempt = currentAttempt + 1
                return .restart(
                    afterSeconds: delay,
                    nextAttempt: nextAttempt,
                    message: "Server exited with code \(status). Restarting (attempt \(nextAttempt)/\(policy.maxRetries))…"
                )
            case .stopped, .error:
                return .noRestart(finalMessage: "Server exited with code \(status)")
            }
        }
    }
}
