import XCTest
import ApplicationServices

final class WindowMoverTests: XCTestCase {
    final class Recorder: FrameSettable {
        var calls: [String] = []
        var refuseFirstSize = false
        func setSize(_ size: CGSize) -> Bool {
            calls.append("size \(Int(size.width))x\(Int(size.height))")
            if refuseFirstSize && calls.count == 1 { return false }
            return true
        }
        func setPosition(_ point: CGPoint) -> Bool {
            calls.append("position \(Int(point.x)),\(Int(point.y))")
            return true
        }
    }

    func testSizeThenPositionThenSizeAgain() {
        let w = Recorder()
        XCTAssertTrue(WindowMover.apply(CGRect(x: 490, y: 33, width: 490, height: 923), to: w))
        XCTAssertEqual(w.calls, ["size 490x923", "position 490,33", "size 490x923"])
    }

    func testTheSecondSizeCountsWhenTheFirstIsRefused() {
        let w = Recorder()
        w.refuseFirstSize = true
        XCTAssertTrue(WindowMover.apply(CGRect(x: 0, y: 33, width: 735, height: 923), to: w))
        XCTAssertEqual(w.calls.count, 3)
    }

    /// Through the real AXValue calls.
    func testAccessibilityValuesRoundTrip() {
        let p = CGPoint(x: 245, y: -99), s = CGSize(width: 980, height: 923)
        XCTAssertEqual(WindowMover.value(p).flatMap(WindowMover.point), p)
        XCTAssertEqual(WindowMover.value(s).flatMap(WindowMover.size), s)
        // A size is never read as a point.
        XCTAssertNil(WindowMover.value(s).flatMap(WindowMover.point))
    }
}
