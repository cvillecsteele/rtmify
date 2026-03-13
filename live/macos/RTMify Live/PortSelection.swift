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

    static func from(data: Data) -> LicenseStatusPayload? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let permitsUse = json["permits_use"] as? Bool
        else {
            return nil
        }
        return LicenseStatusPayload(permitsUse: permitsUse)
    }
}
