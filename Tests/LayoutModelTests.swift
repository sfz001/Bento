import Foundation
import CoreGraphics
@main
struct LayoutModelTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let broken = try decoder.decode(LayoutNode.self, from: Data("{\"type\":\"split\",\"dir\":\"bad\",\"ratio\":99,\"a\":null}".utf8))
        let frame = CGRect(x: -100, y: 50, width: 200, height: 100)
        let cells = broken.cellRects(in: frame)
        precondition(cells.count == 2 && cells[0].rect.width == 100 && cells[1].rect.maxX == frame.maxX)
        let split = broken.replacing(at: [0], with: .split(dir: .h, ratio: 0.25, a: .cell, b: .cell))
        let nested = split.cellRects(in: frame)
        precondition(nested.count == 3 && nested[0].rect.height == 25 && nested[0].rect.maxY == frame.maxY)
        precondition(abs(nested.reduce(0) { $0 + $1.rect.width * $1.rect.height } - frame.width * frame.height) < 0.01)
        let roundTrip = try decoder.decode(LayoutNode.self, from: JSONEncoder().encode(split))
        precondition(roundTrip.cellRects(in: frame).map(\.rect) == nested.map(\.rect))
        precondition(split.replacing(at: [], with: .cell).cellRects(in: frame).count == 1)
        precondition(split.settingRatio(at: [], to: 0.75).cellRects(in: frame)[0].rect.width == 150)
        let badType = try decoder.decode(LayoutNode.self, from: Data("{\"type\":123}".utf8))
        precondition(badType.cellRects(in: frame).count == 1)
        print("PASS: tolerant layout decoding, nested split geometry, replacement, ratio and serialization")
    }
}
