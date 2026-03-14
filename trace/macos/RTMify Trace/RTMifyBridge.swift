import Foundation

struct BridgeError: Error {
    let message: String
}

private func lastError() -> String {
    String(cString: rtmify_last_error())
}

struct LicenseStatus {
    let state: Int32
    let permitsUse: Bool
    let usingFreeRun: Bool
    let detailCode: Int32
    let expectedKeyFingerprint: String?
    let licenseSigningKeyFingerprint: String?
}

private func stringFromTupleCString<T>(_ value: inout T) -> String? {
    withUnsafePointer(to: &value) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cString in
            guard cString[0] != 0 else { return nil }
            return String(cString: cString)
        }
    }
}

func rtmifyLoad(path: String) async throws -> OpaquePointer {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            var graph: OpaquePointer?
            let rc = path.withCString { cPath in
                rtmify_load(cPath, &graph)
            }
            if rc == RTMIFY_OK, let g = graph {
                continuation.resume(returning: g)
            } else {
                continuation.resume(throwing: BridgeError(message: lastError()))
            }
        }
    }
}

func rtmifyGenerate(graph: OpaquePointer, format: String,
                    outputPath: String, projectName: String) async throws {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = format.withCString { cFormat in
                outputPath.withCString { cOutput in
                    projectName.withCString { cProject in
                        rtmify_generate(graph, cFormat, cOutput, cProject)
                    }
                }
            }
            if rc == RTMIFY_OK {
                continuation.resume()
            } else {
                continuation.resume(throwing: BridgeError(message: lastError()))
            }
        }
    }
}

func rtmifyLicenseStatus() throws -> LicenseStatus {
    var status = RtmifyLicenseStatus()
    let rc = rtmify_trace_license_get_status(&status)
    if rc == 0 {
        return LicenseStatus(
            state: status.state,
            permitsUse: status.permits_use != 0,
            usingFreeRun: status.using_free_run != 0,
            detailCode: status.detail_code,
            expectedKeyFingerprint: stringFromTupleCString(&status.expected_key_fingerprint),
            licenseSigningKeyFingerprint: stringFromTupleCString(&status.license_signing_key_fingerprint)
        )
    }
    throw BridgeError(message: lastError())
}

func rtmifyInstallLicense(path: String) async throws -> LicenseStatus {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            var status = RtmifyLicenseStatus()
            let rc = path.withCString { rtmify_trace_license_install($0, &status) }
            if rc == 0 {
                continuation.resume(returning: LicenseStatus(
                    state: status.state,
                    permitsUse: status.permits_use != 0,
                    usingFreeRun: status.using_free_run != 0,
                    detailCode: status.detail_code,
                    expectedKeyFingerprint: stringFromTupleCString(&status.expected_key_fingerprint),
                    licenseSigningKeyFingerprint: stringFromTupleCString(&status.license_signing_key_fingerprint)
                ))
            } else {
                continuation.resume(throwing: BridgeError(message: lastError()))
            }
        }
    }
}

func rtmifyClearLicense() async throws -> LicenseStatus {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            var status = RtmifyLicenseStatus()
            let rc = rtmify_trace_license_clear(&status)
            if rc == 0 {
                continuation.resume(returning: LicenseStatus(
                    state: status.state,
                    permitsUse: status.permits_use != 0,
                    usingFreeRun: status.using_free_run != 0,
                    detailCode: status.detail_code,
                    expectedKeyFingerprint: stringFromTupleCString(&status.expected_key_fingerprint),
                    licenseSigningKeyFingerprint: stringFromTupleCString(&status.license_signing_key_fingerprint)
                ))
            } else {
                continuation.resume(throwing: BridgeError(message: lastError()))
            }
        }
    }
}

func rtmifyRecordSuccessfulUse() async throws {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = rtmify_trace_license_record_successful_use()
            if rc == 0 {
                continuation.resume()
            } else {
                continuation.resume(throwing: BridgeError(message: lastError()))
            }
        }
    }
}
