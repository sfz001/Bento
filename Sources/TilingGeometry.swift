import Foundation
import CoreGraphics

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
    /// 上甩判定：拖拽最后 ≤0.3s 内净向上位移 ≥60pt 且速度 ≥200pt/s（快速一甩）
    static func isUpwardFlick(_ points: [(p: CGPoint, t: Date)]) -> Bool {
        guard let last = points.last else { return false }
        let start = last.t.addingTimeInterval(-0.3)
        guard let first = points.first(where: { $0.t >= start }),
              last.t.timeIntervalSince(first.t) > 0.03
        else { return false }
        let dy = first.p.y - last.p.y // CG 坐标 y 向下：向上为正
        let dt = last.t.timeIntervalSince(first.t)
        return dy >= 60 && dy / dt >= 200
    }

    /// 来回甩判定：1.2s 的轨迹里出现 ≥2 次折返、总行程 ≥60pt。
    /// 相邻段夹角 ≥120°（cos < -0.5）记一次折返；段长 <12pt 的微抖并入下一段，不算方向。
    /// 轨迹点本身已按 1.2s 剪枝，所以这里直接吃整条 points
    static func isWiggle(_ points: [(p: CGPoint, t: Date)]) -> Bool {
        var lastDirUnit = CGVector.zero
        var reversals = 0
        var travel: CGFloat = 0
        var anchor: CGPoint? = nil
        for (p, _) in points {
            guard let a = anchor else { anchor = p; continue }
            let seg = hypot(p.x - a.x, p.y - a.y)
            guard seg >= 12 else { continue } // 微抖：不推进 anchor，等它累积成一整段
            travel += seg
            let u = CGVector(dx: (p.x - a.x) / seg, dy: (p.y - a.y) / seg)
            if lastDirUnit != .zero, u.dx * lastDirUnit.dx + u.dy * lastDirUnit.dy < -0.5 {
                reversals += 1
            }
            lastDirUnit = u
            anchor = p
        }
        return reversals >= 2 && travel >= 60
    }

}
