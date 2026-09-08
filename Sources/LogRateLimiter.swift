import Foundation

/// 由调用方串行化访问。保留首次、状态变化及重复计数，限制缓存大小。
struct LogRateLimiter {
    private struct Entry {
        var message: String
        var began: TimeInterval
        var repeats = 0
    }
    let interval: TimeInterval
    let capacity: Int
    private var entries: [String: Entry] = [:]
    init(interval: TimeInterval = 60, capacity: Int = 128) {
        self.interval = interval
        self.capacity = max(1, capacity)
    }
    var hasPendingRepeats: Bool { entries.values.contains { $0.repeats > 0 } }
    private func summary(_ entry: Entry) -> [String] {
        entry.repeats > 0 ? ["重复 \(entry.repeats) 次：\(entry.message)"] : []
    }
    mutating func record(_ message: String, key: String? = nil, now: TimeInterval) -> [String] {
        let key = key ?? message
        var output: [String] = []
        if var entry = entries[key] {
            if entry.message == message && now - entry.began < interval {
                entry.repeats += 1
                entries[key] = entry
                return []
            }
            output += summary(entry)
        } else if entries.count >= capacity, let oldest = entries.min(by: { $0.value.began < $1.value.began }) {
            output += summary(oldest.value)
            entries.removeValue(forKey: oldest.key)
        }
        entries[key] = Entry(message: message, began: now)
        return output + [message]
    }
    mutating func flush(now: TimeInterval) -> [String] {
        var output: [String] = []
        for key in Array(entries.keys).sorted() {
            guard let entry = entries[key], now - entry.began >= interval else { continue }
            output += summary(entry)
            entries.removeValue(forKey: key)
        }
        return output
    }
}
