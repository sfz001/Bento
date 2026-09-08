import Foundation
@main
struct TilingGeometryTests {
    static func main() {
        let origin = CGPoint(x: 100, y: 200)
        precondition(!TilingGeometry.windowMoved(from: origin, to: origin), "Tab drag leaves source window stationary")
        precondition(!TilingGeometry.windowMoved(from: origin, to: CGPoint(x: 101, y: 201)))
        precondition(TilingGeometry.windowMoved(from: origin, to: CGPoint(x: 100, y: 180)))
        precondition(!TilingGeometry.windowMoved(from: origin, to: nil))
        precondition(!TilingGeometry.windowMoved(from: origin, to: CGPoint(x: CGFloat.nan, y: 200)))
        let path = [CGPoint(x: 130, y: 200), origin]
        precondition(path.contains { TilingGeometry.windowMoved(from: origin, to: $0) }, "Wiggle returning to its origin still moved")
        precondition(TilingGeometry.negativeCacheKey(CGPoint(x: 16, y: -24)) == "2:-3")
        precondition(TilingGeometry.negativeCacheKey(CGPoint(x: CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude)) == "1000000000:-1000000000")
        precondition(TilingGeometry.negativeCacheKey(CGPoint(x: CGFloat.infinity, y: 0)) == "nonfinite")
        precondition(TilingGeometry.negativeCacheKey(CGPoint(x: CGFloat.nan, y: 0)) == "nonfinite")
        let start = Date(timeIntervalSince1970: 0)
        func points(_ values: [CGPoint]) -> [(p: CGPoint, t: Date)] {
            values.enumerated().map { ($0.element, start.addingTimeInterval(Double($0.offset) * 0.1)) }
        }
        precondition(TilingGeometry.isUpwardFlick(points([CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 70), CGPoint(x: 0, y: 30)])))
        precondition(!TilingGeometry.isUpwardFlick(points([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 70)])))
        precondition(!TilingGeometry.isUpwardFlick([]))
        precondition(TilingGeometry.isWiggle(points([.zero, CGPoint(x: 30, y: 0), .zero, CGPoint(x: 30, y: 0)])))
        precondition(!TilingGeometry.isWiggle(points([.zero, CGPoint(x: 3, y: 0), .zero, CGPoint(x: 3, y: 0)])))
        print("PASS: window displacement vs tab drag, micro-movement, missing window and return-to-origin")
    }
}
