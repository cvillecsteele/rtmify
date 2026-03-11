import XCTest
@testable import RTMifyLiveMacOSSupport

final class CrashSupervisorTests: XCTestCase {
    func testIntentionalStopDoesNotRestart() {
        let disposition = CrashSupervisor.classifyTermination(
            priorState: .running(port: 8000),
            wasIntentionalStop: true,
            terminationStatus: 15
        )
        XCTAssertEqual(disposition, .intentionalStop)
    }

    func testStartupCrashIsUnexpected() {
        let disposition = CrashSupervisor.classifyTermination(
            priorState: .starting,
            wasIntentionalStop: false,
            terminationStatus: 6
        )
        XCTAssertEqual(disposition, .unexpectedExit(status: 6))
    }

    func testRunningCrashIsUnexpected() {
        let disposition = CrashSupervisor.classifyTermination(
            priorState: .running(port: 8000),
            wasIntentionalStop: false,
            terminationStatus: 6
        )
        XCTAssertEqual(disposition, .unexpectedExit(status: 6))
    }

    func testStartingCrashSchedulesFirstRetry() {
        let decision = CrashSupervisor.decideRestart(
            priorState: .starting,
            disposition: .unexpectedExit(status: 6),
            currentAttempt: 0,
            policy: RestartPolicy(maxRetries: 3, delaysSeconds: [2, 4, 8])
        )
        XCTAssertEqual(decision, .restart(afterSeconds: 2, nextAttempt: 1, message: "Server exited with code 6. Restarting (attempt 1/3)…"))
    }

    func testRunningCrashSchedulesSecondRetry() {
        let decision = CrashSupervisor.decideRestart(
            priorState: .running(port: 8000),
            disposition: .unexpectedExit(status: 6),
            currentAttempt: 1,
            policy: RestartPolicy(maxRetries: 3, delaysSeconds: [2, 4, 8])
        )
        XCTAssertEqual(decision, .restart(afterSeconds: 4, nextAttempt: 2, message: "Server exited with code 6. Restarting (attempt 2/3)…"))
    }

    func testRetryBudgetExhaustionBecomesError() {
        let decision = CrashSupervisor.decideRestart(
            priorState: .running(port: 8000),
            disposition: .unexpectedExit(status: 6),
            currentAttempt: 3,
            policy: RestartPolicy(maxRetries: 3, delaysSeconds: [2, 4, 8])
        )
        XCTAssertEqual(decision, .noRestart(finalMessage: "Server crashed repeatedly (code 6)"))
    }

    func testStoppedStateDoesNotRestart() {
        let decision = CrashSupervisor.decideRestart(
            priorState: .stopped,
            disposition: .unexpectedExit(status: 6),
            currentAttempt: 0,
            policy: RestartPolicy(maxRetries: 3, delaysSeconds: [2, 4, 8])
        )
        XCTAssertEqual(decision, .noRestart(finalMessage: "Server exited with code 6"))
    }

    func testOutputRingBufferKeepsRecentLinesOnly() {
        var buffer = OutputRingBuffer(maxLines: 3, maxBytes: 1024)
        buffer.append(Data("a\nb\nc\nd\n".utf8))
        XCTAssertEqual(buffer.snapshot(), "b\nc\nd")
    }

    func testOutputRingBufferTruncatesOversizedOutput() {
        var buffer = OutputRingBuffer(maxLines: 200, maxBytes: 10)
        buffer.append(Data("12345\n67890\nabcde\n".utf8))
        let snapshot = buffer.snapshot()
        XCTAssertTrue(snapshot.hasSuffix("abcde"))
        XCTAssertLessThanOrEqual(snapshot.utf8.count, 10)
    }

    func testOutputRingBufferPreservesLatestCrashContext() {
        var buffer = OutputRingBuffer(maxLines: 2, maxBytes: 1024)
        buffer.append(Data("line1\nline2\n".utf8))
        buffer.append(Data("panic here".utf8))
        XCTAssertEqual(buffer.snapshot(), "line1\nline2\npanic here")
    }
}
