import Foundation

/// 只有窗口本身发生位移才属于窗口拖动，标签页/工具栏拖拽不算。
enum TilingGeometry {
    static func windowMoved(from origin: CGPoint, to current: CGPoint?) -> Bool {
        guard let current, origin.x.isFinite, origin.y.isFinite,
              current.x.isFinite, current.y.isFinite else { return false }
        return hypot(current.x - origin.x, current.y - origin.y) > 3
    }
}
