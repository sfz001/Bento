import Foundation
import CoreGraphics

// MARK: 分屏：布局模型（递归二叉分割树）

/// 分割方向：V = 左右分割（一条竖线，a=左 b=右）；H = 上下分割（一条横线，a=上 b=下）
enum SplitDir: String, Codable {
    case v = "V"
    case h = "H"
}

/// 布局树节点：叶子为格子；split 为二叉分割。
/// JSON 结构：{"type":"cell"} 或 {"type":"split","dir":"V"|"H","ratio":0.5,"a":…,"b":…}
indirect enum LayoutNode {
    case cell
    case split(dir: SplitDir, ratio: CGFloat, a: LayoutNode, b: LayoutNode)
}

extension LayoutNode {
    static let minRatio: CGFloat = 0.08
    static let maxRatio: CGFloat = 0.92

    /// 把 rect 按 dir/ratio 切成 (a, b) 两块（AppKit 几何，y 轴向上）
    static func splitRect(_ r: CGRect, dir: SplitDir, ratio: CGFloat) -> (CGRect, CGRect) {
        switch dir {
        case .v:
            let w = r.width * ratio
            return (CGRect(x: r.minX, y: r.minY, width: w, height: r.height),
                    CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height))
        case .h:
            // a 取上半部分（AppKit y 向上，上半部分 y 更大）
            let h = r.height * ratio
            return (CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h),
                    CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - h))
        }
    }

    /// 递归求所有叶格子矩形。path 元素 0=a 1=b，标识格子在树中的位置（编辑器操作用）
    func cellRects(in rect: CGRect, path: [Int] = []) -> [(path: [Int], rect: CGRect)] {
        switch self {
        case .cell:
            return [(path, rect)]
        case .split(let dir, let ratio, let a, let b):
            let (ra, rb) = LayoutNode.splitRect(rect, dir: dir, ratio: ratio)
            return a.cellRects(in: ra, path: path + [0]) + b.cellRects(in: rb, path: path + [1])
        }
    }

    /// 一条可拖动的分隔线：所在分割节点 path、线本身、父矩形、方向
    struct SplitLine {
        let path: [Int]
        let line: CGRect
        let parentRect: CGRect
        let dir: SplitDir
    }

    /// 递归求所有分隔线（编辑器拖拽调比例用）
    func splitLines(in rect: CGRect, path: [Int] = []) -> [SplitLine] {
        guard case .split(let dir, let ratio, let a, let b) = self else { return [] }
        let (ra, rb) = LayoutNode.splitRect(rect, dir: dir, ratio: ratio)
        let line: CGRect
        switch dir {
        case .v: line = CGRect(x: ra.maxX, y: rect.minY, width: 0, height: rect.height)
        case .h: line = CGRect(x: rect.minX, y: ra.minY, width: rect.width, height: 0)
        }
        return [SplitLine(path: path, line: line, parentRect: rect, dir: dir)]
            + a.splitLines(in: ra, path: path + [0])
            + b.splitLines(in: rb, path: path + [1])
    }

    /// 取 path 处的子树
    func subtree(at path: [Int]) -> LayoutNode? {
        guard let head = path.first else { return self }
        guard case .split(_, _, let a, let b) = self else { return nil }
        return (head == 0 ? a : b).subtree(at: Array(path.dropFirst()))
    }

    /// 用 node 替换 path 处的子树
    func replacing(at path: [Int], with node: LayoutNode) -> LayoutNode {
        guard let head = path.first else { return node }
        guard case .split(let dir, let ratio, let a, let b) = self else { return self }
        let rest = Array(path.dropFirst())
        return head == 0
            ? .split(dir: dir, ratio: ratio, a: a.replacing(at: rest, with: node), b: b)
            : .split(dir: dir, ratio: ratio, a: a, b: b.replacing(at: rest, with: node))
    }

    /// 调整 path 处分割节点的比例
    func settingRatio(at path: [Int], to newRatio: CGFloat) -> LayoutNode {
        guard let head = path.first else {
            guard case .split(let dir, _, let a, let b) = self else { return self }
            return .split(dir: dir, ratio: newRatio, a: a, b: b)
        }
        guard case .split(let dir, let ratio, let a, let b) = self else { return self }
        let rest = Array(path.dropFirst())
        return head == 0
            ? .split(dir: dir, ratio: ratio, a: a.settingRatio(at: rest, to: newRatio), b: b)
            : .split(dir: dir, ratio: ratio, a: a, b: b.settingRatio(at: rest, to: newRatio))
    }
}

extension LayoutNode: Codable {
    private enum CodingKeys: String, CodingKey { case type, dir, ratio, a, b }

    /// 防御式解析：字段缺失/损坏一律回退安全值，绝不让整棵树解析失败
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // type 也得用 try?：这是根节点唯一会抛的字段，而 TilingConfig 对 layouts 是
        // 整体 try? 兜底 —— 单个显示器条目的 type 坏掉会让**所有**显示器的布局
        // 一起静默清空（且吞掉错误不写日志）。坏字段回退成普通格子，只影响它自己
        let type = (try? c.decode(String.self, forKey: .type)) ?? "cell"
        switch type {
        case "cell":
            self = .cell
        case "split":
            let dir = SplitDir(rawValue: (try? c.decode(String.self, forKey: .dir)) ?? "") ?? .v
            let rawRatio = (try? c.decode(CGFloat.self, forKey: .ratio)) ?? 0.5
            // ratio 非有限值/越界 → 0.5
            let ratio = rawRatio.isFinite
                && (LayoutNode.minRatio...LayoutNode.maxRatio).contains(rawRatio) ? rawRatio : 0.5
            // 子节点缺失/损坏 → 回退普通格子
            let a = (try? c.decode(LayoutNode.self, forKey: .a)) ?? .cell
            let b = (try? c.decode(LayoutNode.self, forKey: .b)) ?? .cell
            self = .split(dir: dir, ratio: ratio, a: a, b: b)
        default:
            self = .cell
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cell:
            try c.encode("cell", forKey: .type)
        case .split(let dir, let ratio, let a, let b):
            try c.encode("split", forKey: .type)
            try c.encode(dir.rawValue, forKey: .dir)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(a, forKey: .a)
            try c.encode(b, forKey: .b)
        }
    }
}

