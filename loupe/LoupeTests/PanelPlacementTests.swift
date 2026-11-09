import XCTest

final class PanelPlacementTests: XCTestCase {
    func testThePanelTakesTheFullRightThirdOfTheScreen() {
        // Ben's MacBook screen, 2026-11-08: visible frame 1470 by 923.
        let frame = PanelPlacement.rightThird(of: CGRect(x: 0, y: 0, width: 1470, height: 923), minWidth: 380)
        XCTAssertEqual(frame, CGRect(x: 980, y: 0, width: 490, height: 923))
    }

    func testTheThirdIsOfTheScreenThePanelIsOn() {
        let frame = PanelPlacement.rightThird(of: CGRect(x: 1470, y: 40, width: 1920, height: 1040), minWidth: 380)
        XCTAssertEqual(frame, CGRect(x: 2750, y: 40, width: 640, height: 1040))
    }

    func testANarrowScreenStillGetsThePanelAtItsMinimumWidth() {
        let frame = PanelPlacement.rightThird(of: CGRect(x: 0, y: 0, width: 1024, height: 700), minWidth: 380)
        XCTAssertEqual(frame, CGRect(x: 644, y: 0, width: 380, height: 700))
    }
}
