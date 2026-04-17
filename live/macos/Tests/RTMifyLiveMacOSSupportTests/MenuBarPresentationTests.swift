import XCTest
@testable import RTMifyLiveMacOSSupport

final class MenuBarPresentationTests: XCTestCase {
    func testPreviewLabelsUsePreviewLanguage() {
        XCTAssertEqual(MenuBarPresentation.stoppedLabel(permitsUse: false), "Preview mode")
        XCTAssertEqual(MenuBarPresentation.startingLabel(permitsUse: false), "Starting preview…")
        XCTAssertEqual(MenuBarPresentation.runningLabel(port: 8000, permitsUse: false), "Preview running on :8000")
        XCTAssertEqual(MenuBarPresentation.startActionLabel(permitsUse: false), "Start Preview")
        XCTAssertEqual(MenuBarPresentation.licenseActionLabel(permitsUse: false), "Install License File…")
    }

    func testLicensedLabelsUseServerLanguage() {
        XCTAssertEqual(MenuBarPresentation.stoppedLabel(permitsUse: true), "Server stopped")
        XCTAssertEqual(MenuBarPresentation.restartingLabel(attempt: 2, maxAttempts: 3, permitsUse: true), "Restarting server (attempt 2/3)…")
        XCTAssertEqual(MenuBarPresentation.runningLabel(port: 8001, permitsUse: true), "Running on :8001")
        XCTAssertEqual(MenuBarPresentation.startActionLabel(permitsUse: true), "Start Server")
        XCTAssertEqual(MenuBarPresentation.licenseActionLabel(permitsUse: true), "Manage License…")
    }
}
