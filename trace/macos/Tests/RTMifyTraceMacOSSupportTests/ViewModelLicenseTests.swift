import XCTest
@testable import RTMifyTraceMacOSSupport

@MainActor
final class ViewModelLicenseTests: XCTestCase {
    func testCheckLicenseLeavesDropZoneWhenPermitted() {
        let vm = ViewModel(
            fetchLicenseStatus: { LicenseStatus(state: 0, permitsUse: true, usingFreeRun: true, detailCode: 1) }
        )

        vm.checkLicense()

        guard case .dropZone = vm.state else {
            return XCTFail("expected dropZone, got \(vm.state)")
        }
        XCTAssertEqual(vm.licenseStatusMessage, "You can use RTMify Trace once without a license. The first successful report will consume that free run.")
    }

    func testCheckLicenseShowsGateWhenTrialExhausted() {
        let vm = ViewModel(
            fetchLicenseStatus: { LicenseStatus(state: 0, permitsUse: false, usingFreeRun: false, detailCode: 2) }
        )

        vm.checkLicense()

        guard case .licenseGate = vm.state else {
            return XCTFail("expected licenseGate, got \(vm.state)")
        }
        XCTAssertEqual(vm.licenseStatusMessage, "Your one free RTMify Trace run has been used. Import a signed license file or place it at ~/.rtmify/license.json.")
    }

    func testImportLicenseAtPathUnlocksApp() async {
        let vm = ViewModel(
            fetchLicenseStatus: { LicenseStatus(state: 0, permitsUse: false, usingFreeRun: false, detailCode: 3) },
            installLicenseAtPath: { _ in LicenseStatus(state: 0, permitsUse: true, usingFreeRun: false, detailCode: 0) }
        )

        vm.importLicense(atPath: "/tmp/license.json")
        await Task.yield()

        guard case .dropZone = vm.state else {
            return XCTFail("expected dropZone, got \(vm.state)")
        }
        XCTAssertEqual(vm.licenseStatusMessage, "Valid license installed.")
        XCTAssertNil(vm.licenseError)
    }

    func testImportLicenseAtPathSurfacesBridgeError() async {
        let vm = ViewModel(
            fetchLicenseStatus: { LicenseStatus(state: 0, permitsUse: false, usingFreeRun: false, detailCode: 3) },
            installLicenseAtPath: { _ in throw BridgeError(message: "wrong product") }
        )

        vm.importLicense(atPath: "/tmp/license.json")
        await Task.yield()

        XCTAssertEqual(vm.licenseError, "wrong product")
        guard case .dropZone = vm.state else {
            return XCTFail("expected state to remain unchanged, got \(vm.state)")
        }
    }

    func testClearLicenseReturnsToGate() async {
        let vm = ViewModel(
            fetchLicenseStatus: { LicenseStatus(state: 0, permitsUse: true, usingFreeRun: false, detailCode: 0) },
            clearInstalledLicense: { LicenseStatus(state: 0, permitsUse: false, usingFreeRun: false, detailCode: 3) }
        )

        vm.clearLicense()
        await Task.yield()

        guard case .licenseGate = vm.state else {
            return XCTFail("expected licenseGate, got \(vm.state)")
        }
        XCTAssertEqual(vm.licenseStatusMessage, "No installed license file was found. Place license.json at ~/.rtmify/license.json or import it here.")
    }
}
