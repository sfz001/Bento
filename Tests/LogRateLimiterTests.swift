import Foundation
@main
struct LogRateLimiterTests {
    static func main() {
        var limiter = LogRateLimiter(interval: 60, capacity: 2)
        precondition(limiter.record("failed", key: "probe", now: 0) == ["failed"])
        for _ in 0..<100 { precondition(limiter.record("failed", key: "probe", now: 1).isEmpty) }
        precondition(limiter.hasPendingRepeats)
        precondition(limiter.record("recovered", key: "probe", now: 2) == ["重复 100 次：failed", "recovered"])
        precondition(limiter.record("recovered", key: "probe", now: 3).isEmpty)
        precondition(limiter.flush(now: 61).isEmpty)
        precondition(limiter.flush(now: 62) == ["重复 1 次：recovered"])
        precondition(!limiter.hasPendingRepeats)
        precondition(limiter.record("A", now: 63) == ["A"])
        precondition(limiter.record("A", now: 64).isEmpty)
        precondition(limiter.record("B", now: 65) == ["B"])
        precondition(limiter.record("C", now: 66) == ["重复 1 次：A", "C"])
        print("PASS: first error, 100 repeats, immediate recovery, timed flush and bounded cache")
    }
}
