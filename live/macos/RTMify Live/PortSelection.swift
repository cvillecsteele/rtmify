import Foundation

enum PortSelection {
    static let preferredRange = 8000...8010

    static func firstAvailable(
        in range: ClosedRange<Int> = preferredRange,
        isAvailable: (Int) -> Bool
    ) -> Int {
        for port in range {
            if isAvailable(port) {
                return port
            }
        }
        return range.lowerBound
    }
}

struct StatusPayload {
    let lastSyncAt: String?
    let lastScanAt: String?

    static func from(json: [String: Any]) -> StatusPayload {
        let lastSyncAt: String?
        if let ts = json["last_sync_at"] as? NSNumber {
            lastSyncAt = String(ts.int64Value)
        } else if let ts = json["last_sync_at"] as? String {
            lastSyncAt = ts
        } else {
            lastSyncAt = nil
        }

        let lastScanAt: String?
        if let sc = json["last_scan_at"] as? String, sc != "never" {
            lastScanAt = sc
        } else {
            lastScanAt = nil
        }

        return StatusPayload(lastSyncAt: lastSyncAt, lastScanAt: lastScanAt)
    }
}

struct LicenseStatusPayload: Equatable {
    let permitsUse: Bool
    let expectedKeyFingerprint: String?
    let licenseSigningKeyFingerprint: String?

    static func from(data: Data) -> LicenseStatusPayload? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        guard let permitsUse = json["permits_use"] as? Bool else { return nil }
        return LicenseStatusPayload(
            permitsUse: permitsUse,
            expectedKeyFingerprint: json["expected_key_fingerprint"] as? String,
            licenseSigningKeyFingerprint: json["license_signing_key_fingerprint"] as? String
        )
    }
}

struct MenuBarPresentation {
    static func stoppedLabel(permitsUse: Bool) -> String {
        permitsUse ? "Server stopped" : "Preview mode"
    }

    static func startingLabel(permitsUse: Bool) -> String {
        permitsUse ? "Starting…" : "Starting preview…"
    }

    static func restartingLabel(attempt: Int, maxAttempts: Int, permitsUse: Bool) -> String {
        let prefix = permitsUse ? "Restarting server" : "Restarting preview"
        return "\(prefix) (attempt \(attempt)/\(maxAttempts))…"
    }

    static func runningLabel(port: Int, permitsUse: Bool) -> String {
        let prefix = permitsUse ? "Running" : "Preview running"
        return "\(prefix) on :\(port)"
    }

    static func startActionLabel(permitsUse: Bool) -> String {
        permitsUse ? "Start Server" : "Start Preview"
    }

    static func licenseActionLabel(permitsUse: Bool) -> String {
        permitsUse ? "Manage License…" : "Install License File…"
    }
}
