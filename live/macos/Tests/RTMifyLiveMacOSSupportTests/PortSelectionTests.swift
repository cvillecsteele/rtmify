import XCTest
@testable import RTMifyLiveMacOSSupport

final class PortSelectionTests: XCTestCase {
    func testChoosesLowestAvailablePort() {
        let selected = PortSelection.firstAvailable { port in
            port != 8000 ? false : true
        }
        XCTAssertEqual(selected, 8000)
    }

    func testFallsThroughToNextFreePort() {
        let selected = PortSelection.firstAvailable { port in
            port >= 8003
        }
        XCTAssertEqual(selected, 8003)
    }

    func testAlwaysPrefersLowerPortWhenItBecomesFreeAgain() {
        let selected = PortSelection.firstAvailable { port in
            switch port {
            case 8000: return true
            case 8001...8010: return true
            default: return false
            }
        }
        XCTAssertEqual(selected, 8000)
    }

    func testFallsBackToRangeLowerBoundIfAllPortsBusy() {
        let selected = PortSelection.firstAvailable { _ in false }
        XCTAssertEqual(selected, 8000)
    }

    func testStatusPayloadParsesNumericLastSyncAt() {
        let payload = StatusPayload.from(json: [
            "last_sync_at": NSNumber(value: 1773175875),
            "last_scan_at": "never",
        ])
        XCTAssertEqual(payload.lastSyncAt, "1773175875")
        XCTAssertNil(payload.lastScanAt)
    }

    func testStatusPayloadParsesStringLastSyncAt() {
        let payload = StatusPayload.from(json: [
            "last_sync_at": "1773175875",
            "last_scan_at": "2026-03-10T20:00:00Z",
        ])
        XCTAssertEqual(payload.lastSyncAt, "1773175875")
        XCTAssertEqual(payload.lastScanAt, "2026-03-10T20:00:00Z")
    }

    func testLicenseStatusPayloadParsesPermitsUseTrue() {
        let json = Data(#"{"permits_use":true}"#.utf8)
        XCTAssertEqual(LicenseStatusPayload.from(data: json), LicenseStatusPayload(permitsUse: true))
    }

    func testLicenseStatusPayloadRejectsInvalidJson() {
        let json = Data("not-json".utf8)
        XCTAssertNil(LicenseStatusPayload.from(data: json))
    }

    func testLicenseStatusPayloadRejectsMissingPermitsUse() {
        let json = Data(#"{"detail_code":3}"#.utf8)
        XCTAssertNil(LicenseStatusPayload.from(data: json))
    }
}
