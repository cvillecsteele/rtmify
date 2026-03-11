import Foundation

struct OutputRingBuffer: Equatable {
    private let maxLines: Int
    private let maxBytes: Int
    private var lines: [String] = []
    private var pending = ""
    private var byteCount = 0

    init(maxLines: Int = 200, maxBytes: Int = 32 * 1024) {
        self.maxLines = maxLines
        self.maxBytes = maxBytes
    }

    mutating func append(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .utf8), !text.isEmpty else { return }
        pending += text
        while let idx = pending.firstIndex(of: "\n") {
            let line = String(pending[..<idx])
            pending.removeSubrange(...idx)
            appendLine(line)
        }
        trimIfNeeded()
    }

    mutating func reset() {
        lines.removeAll(keepingCapacity: false)
        pending.removeAll(keepingCapacity: false)
        byteCount = 0
    }

    func snapshot() -> String {
        if pending.isEmpty {
            return lines.joined(separator: "\n")
        }
        if lines.isEmpty {
            return pending
        }
        return lines.joined(separator: "\n") + "\n" + pending
    }

    private mutating func appendLine(_ line: String) {
        lines.append(line)
        byteCount += line.utf8.count + 1
        trimIfNeeded()
    }

    private mutating func trimIfNeeded() {
        while lines.count > maxLines {
            let removed = lines.removeFirst()
            byteCount -= removed.utf8.count + 1
        }
        while (byteCount + pending.utf8.count) > maxBytes && !lines.isEmpty {
            let removed = lines.removeFirst()
            byteCount -= removed.utf8.count + 1
        }
        if pending.utf8.count > maxBytes {
            let chars = Array(pending)
            var bytes = 0
            var start = chars.count
            while start > 0 {
                let scalarBytes = String(chars[start - 1]).utf8.count
                if bytes + scalarBytes > maxBytes { break }
                bytes += scalarBytes
                start -= 1
            }
            pending = String(chars[start...])
        }
    }
}
