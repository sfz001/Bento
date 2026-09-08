import Foundation

/// 只有窗口本身发生位移才属于窗口拖动，标签页/工具栏拖拽不算。
enum TilingGeometry {
    static func negativeCacheKey(_ point: CGPoint) -> String {
        guard point.x.isFinite, point.y.isFinite else { return "nonfinite" }
        // 远大于真实桌面范围，同时精确落在 Int 可表示区间，避免 CGFloat(Int.max) 舍入溢出。
        func cell(_ value: CGFloat) -> Int { Int(min(1_000_000_000, max(-1_000_000_000, value / 8))) }
        return "\(cell(point.x)):\(cell(point.y))"
    }

    static func windowMoved(from origin: CGPoint, to current: CGPoint?) -> Bool {
        guard let current, origin.x.isFinite, origin.y.isFinite,
              current.x.isFinite, current.y.isFinite else { return false }
        return hypot(current.x - origin.x, current.y - origin.y) > 3
    }
}
