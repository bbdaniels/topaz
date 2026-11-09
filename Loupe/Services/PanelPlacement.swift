import CoreGraphics

/// Where the HUD panel opens (Ben, 2026-11-08): the full right third of the
/// screen, beside Topaz, which takes the left two thirds. Never narrower than
/// the panel's minimum width.
enum PanelPlacement {
    static func rightThird(of visibleFrame: CGRect, minWidth: CGFloat) -> CGRect {
        let width = max((visibleFrame.width / 3).rounded(), minWidth)
        return CGRect(x: visibleFrame.maxX - width, y: visibleFrame.minY,
                      width: width, height: visibleFrame.height)
    }
}
