import XCTest

final class PanelToggleTests: XCTestCase {
    func testAPanelBesideTopazIsHiddenThoughNotKey() {
        // 2026-11-08: with the close button gone, a click on the gem is how the
        // panel's part of the screen comes back, whichever window has focus.
        XCTAssertEqual(PanelToggle.action(isVisible: true, isOnActiveSpace: true, isUncovered: true), .hide)
    }

    func testAPanelBuriedUnderAnotherAppIsBroughtForward() {
        // 2026-11-06: closing a Ghostty window brought Arc forward over the panel;
        // the panel was still visible on this desktop, so the old rule hid it.
        XCTAssertEqual(PanelToggle.action(isVisible: true, isOnActiveSpace: true, isUncovered: false), .show)
    }

    func testAPanelOnAnotherDesktopOrClosedIsShown() {
        XCTAssertEqual(PanelToggle.action(isVisible: true, isOnActiveSpace: false, isUncovered: true), .show)
        XCTAssertEqual(PanelToggle.action(isVisible: false, isOnActiveSpace: false, isUncovered: false), .show)
    }
}
