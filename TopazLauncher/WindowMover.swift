import ApplicationServices
import CoreGraphics

/// Something whose size and position can be set: a window through
/// Accessibility, or a recorder in the tests.
protocol FrameSettable {
    func setSize(_ size: CGSize) -> Bool
    func setPosition(_ point: CGPoint) -> Bool
}

/// Moves the front window through Accessibility (`kAXSizeAttribute` and
/// `kAXPositionAttribute`), which needs this helper's own Accessibility
/// grant. The size is set, then the position, then the size again: an app
/// that clamps a window to its screen shrinks it on the first size when the
/// old position leaves no room, and takes the full size once it has moved.
enum WindowMover {
    @discardableResult
    static func apply(_ frame: CGRect, to window: FrameSettable) -> Bool {
        let first = window.setSize(frame.size)
        let moved = window.setPosition(frame.origin)
        let again = window.setSize(frame.size)
        return moved && (first || again)
    }

    // MARK: Accessibility values

    static func value(_ point: CGPoint) -> AXValue? {
        var p = point
        return AXValueCreate(.cgPoint, &p)
    }

    static func value(_ size: CGSize) -> AXValue? {
        var s = size
        return AXValueCreate(.cgSize, &s)
    }

    static func point(_ value: AXValue) -> CGPoint? {
        var p = CGPoint.zero
        return AXValueGetType(value) == .cgPoint && AXValueGetValue(value, .cgPoint, &p) ? p : nil
    }

    static func size(_ value: AXValue) -> CGSize? {
        var s = CGSize.zero
        return AXValueGetType(value) == .cgSize && AXValueGetValue(value, .cgSize, &s) ? s : nil
    }

    // MARK: The front window

    /// The focused window of the frontmost app `pid`.
    static func focusedWindow(of pid: pid_t) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return AXWindow(element: window as! AXUIElement)
    }
}

/// A window as Accessibility reaches it.
struct AXWindow: FrameSettable {
    let element: AXUIElement

    var frame: CGRect? {
        guard let p = copy(kAXPositionAttribute).flatMap(WindowMover.point),
              let s = copy(kAXSizeAttribute).flatMap(WindowMover.size) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private func copy(_ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    func setSize(_ size: CGSize) -> Bool {
        guard let v = WindowMover.value(size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) == .success
    }

    func setPosition(_ point: CGPoint) -> Bool {
        guard let v = WindowMover.value(point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .success
    }
}
