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
        print("PASS: window displacement vs tab drag, micro-movement, missing window and return-to-origin")
    }
}
