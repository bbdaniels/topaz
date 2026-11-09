import XCTest

/// Topaz Launcher's snapping geometry: Magnet's bindings as Ben had them on
/// 2026-11-08, on Magnet's grid, in Accessibility's top-left coordinates.
final class SnapLayoutTests: XCTestCase {
    /// The Mac's screen: 1470 by 956 points, a 33 point menu bar, no Dock.
    let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let visibleAppKit = CGRect(x: 0, y: 0, width: 1470, height: 923)
    var visible: CGRect { SnapLayout.flipped(visibleAppKit, primaryHeight: 956) }

    private func frame(_ name: String, _ list: [SnapLayout.Command] = SnapLayout.landscape, in v: CGRect? = nil) -> CGRect {
        let v = v ?? visible
        let c = list.first { $0.name == name }!
        return SnapLayout.frame(c.cells, SnapLayout.orientation(of: v), in: v)
    }

    func testTheFlipPutsTheVisibleFrameBelowTheMenuBar() {
        XCTAssertEqual(visible, CGRect(x: 0, y: 33, width: 1470, height: 923))
        // A screen above the primary has negative top-left y.
        XCTAssertEqual(SnapLayout.flipped(CGRect(x: 0, y: 956, width: 1920, height: 1080), primaryHeight: 956),
                       CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    func testHalvesTileTheScreen() {
        let l = frame("Left half"), r = frame("Right half")
        XCTAssertEqual(l.minX, 0); XCTAssertEqual(l.maxX, r.minX); XCTAssertEqual(r.maxX, 1470)
        XCTAssertEqual(l.minY, 33); XCTAssertEqual(l.height, 923); XCTAssertEqual(r.height, 923)
    }

    func testThirdsTileWithNoGapOrOverlap() {
        let a = frame("Left third"), b = frame("Center third"), c = frame("Right third")
        XCTAssertEqual(a.minX, 0); XCTAssertEqual(a.maxX, b.minX); XCTAssertEqual(b.maxX, c.minX); XCTAssertEqual(c.maxX, 1470)
        XCTAssertEqual(a.width, 490); XCTAssertEqual(b.width, 490); XCTAssertEqual(c.width, 490)
        for f in [a, b, c] { XCTAssertEqual(f.origin.x, f.origin.x.rounded()) }
    }

    func testTwoThirdsMeetTheThirds() {
        XCTAssertEqual(frame("Left two thirds").maxX, frame("Right third").minX)
        let center = frame("Center two thirds")
        XCTAssertEqual(center.minX, 245); XCTAssertEqual(center.maxX, 1225)
        XCTAssertEqual(frame("Maximize"), visible)
    }

    func testEdgesAreWholePointsOnAnOddWidth() {
        let v = CGRect(x: 0, y: 25, width: 1001, height: 700)
        let a = frame("Left third", in: v), b = frame("Center third", in: v), c = frame("Right third", in: v)
        XCTAssertEqual(a.maxX, b.minX); XCTAssertEqual(b.maxX, c.minX); XCTAssertEqual(c.maxX, 1001)
        for f in [a, b, c] { XCTAssertEqual(f.width, f.width.rounded()) }
    }

    func testPortraitUsesItsOwnList() {
        let v = CGRect(x: 0, y: 25, width: 1080, height: 1895)
        XCTAssertEqual(SnapLayout.orientation(of: v), .portrait)
        let bottom = frame("Bottom third", SnapLayout.portrait, in: v)
        XCTAssertEqual(bottom.maxY, v.maxY); XCTAssertEqual(bottom.width, 1080)
        XCTAssertEqual(frame("Top two thirds", SnapLayout.portrait, in: v).maxY, bottom.minY)
        // Command-Down is the center third only on a landscape screen.
        XCTAssertNil(SnapLayout.command(for: .init(keyCode: SnapLayout.down, modifiers: SnapLayout.cmd), .portrait))
    }

    func testMagnetsChordsAreAllBoundOnce() {
        XCTAssertEqual(SnapLayout.chords.count, 8)
        XCTAssertEqual(SnapLayout.command(for: .init(keyCode: SnapLayout.right, modifiers: SnapLayout.cmd), .landscape)?.name, "Right third")
        XCTAssertEqual(SnapLayout.command(for: .init(keyCode: SnapLayout.keyR, modifiers: SnapLayout.control | SnapLayout.option), .landscape)?.name, "Center two thirds")
    }

    func testTheWindowsScreenIsTheOneItOverlapsMost() {
        let primary = (frame: screen, visible: visibleAppKit)
        let right = (frame: CGRect(x: 1470, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1470, y: 0, width: 1920, height: 1055))
        let chord = SnapLayout.Chord(keyCode: SnapLayout.up, modifiers: SnapLayout.cmd)
        let onRight = SnapLayout.target(for: chord, window: CGRect(x: 1400, y: 100, width: 800, height: 600), screens: [primary, right])
        XCTAssertEqual(onRight, CGRect(x: 1470, y: -99, width: 1920, height: 1055))
        let onPrimary = SnapLayout.target(for: chord, window: CGRect(x: 100, y: 100, width: 800, height: 600), screens: [primary, right])
        XCTAssertEqual(onPrimary, visible)
        // A window off every screen goes to the primary.
        XCTAssertEqual(SnapLayout.target(for: chord, window: CGRect(x: -5000, y: 0, width: 10, height: 10), screens: [primary, right]), visible)
    }
}
