import XCTest
@testable import RTMifyTraceMacOSSupport

@MainActor
final class ViewModelLicenseTests: XCTestCase {
    func testDefaultSelectedProfileIsGeneric() {
        let vm = ViewModel()
        XCTAssertEqual(vm.selectedProfile, .generic)
    }

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

    func testUpdateSelectedProfileReloadsLoadedWorkbook() async {
        let firstSummary = AnalysisSummary(
            profile: .generic,
            shortName: "generic",
            displayName: "Generic",
            standards: "Generic",
            warningCount: 0,
            genericGapCount: 1,
            profileGapCount: 0,
            totalGapCount: 1
        )
        let medicalSummary = AnalysisSummary(
            profile: .medical,
            shortName: "med",
            displayName: "Medical",
            standards: "ISO 13485 / IEC 62304 / FDA",
            warningCount: 1,
            genericGapCount: 1,
            profileGapCount: 2,
            totalGapCount: 3
        )
        var seenProfiles: [TraceProfile] = []
        let vm = ViewModel(
            loadWorkbook: { _, profile in
                seenProfiles.append(profile)
                let summary = profile == .medical ? medicalSummary : firstSummary
                return LoadedGraph(graph: OpaquePointer(bitPattern: 0x1)!, summary: summary)
            }
        )

        vm.load(path: "/tmp/example.xlsx")
        await Task.yield()
        vm.updateSelectedProfile(.medical)
        await Task.yield()

        XCTAssertEqual(seenProfiles, [.generic, .medical])
        XCTAssertEqual(vm.selectedProfile, .medical)
        guard case .fileLoaded(let summary) = vm.state else {
            return XCTFail("expected fileLoaded, got \(vm.state)")
        }
        XCTAssertEqual(summary.analysis.displayName, "Medical")
        XCTAssertEqual(summary.analysis.totalGapCount, 3)
    }
}
