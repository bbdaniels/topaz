import Cocoa
import os

private let logger = Logger(subsystem: "com.bbdaniels.topaz.launcher", category: "Snap")

/// Magnet's keyboard snapping (`SnapLayout`), bound only while Magnet is not
/// running: every chord Ben uses is Magnet's, and Magnet stays in charge
/// until he quits it at the cutover. When Magnet quits the chords are bound;
/// when it launches they are released, so the two never fight for a key.
///
/// Accessibility is never asked for at launch. A snap chord pressed without
/// the grant opens the system's prompt once, and that cannot happen while
/// Magnet runs, since the chords are not bound then.
@MainActor
final class Snapper: NSObject {
    static let magnet = "com.crowdcafe.windowmagnet"

    private let hotKeys: HotKeyCenter
    private var bound: [UInt32] = []
    private var prompted = false

    init(hotKeys: HotKeyCenter) {
        self.hotKeys = hotKeys
        super.init()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        appsChanged()
    }

    static func magnetRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: magnet).isEmpty
    }

    @objc private func appsChanged() {
        let want = !Self.magnetRunning()
        if want && bound.isEmpty { bind() } else if !want && !bound.isEmpty { release() }
    }

    private func bind() {
        for chord in SnapLayout.chords {
            switch hotKeys.register(keyCode: chord.keyCode, modifiers: chord.modifiers, { [weak self] in self?.snap(chord) }) {
            case .success(let id): bound.append(id)
            case .failure(let e): logger.error("chord \(chord.keyCode, privacy: .public)/\(chord.modifiers, privacy: .public) refused: \(e.status, privacy: .public)")
            }
        }
        logger.info("Magnet is not running: bound \(self.bound.count, privacy: .public) snapping chords")
    }

    private func release() {
        bound.forEach(hotKeys.unregister)
        bound = []
        logger.info("Magnet is running: snapping chords released")
    }

    private func snap(_ chord: SnapLayout.Chord) {
        guard AXIsProcessTrusted() else {
            if !prompted {
                prompted = true
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            logger.error("no Accessibility grant: cannot move windows")
            return
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = WindowMover.focusedWindow(of: pid), let now = window.frame else { return }
        let screens = NSScreen.screens.map { (frame: $0.frame, visible: $0.visibleFrame) }
        guard let target = SnapLayout.target(for: chord, window: now, screens: screens) else { return }
        if !WindowMover.apply(target, to: window) {
            logger.error("the window did not take \(NSStringFromRect(target), privacy: .public)")
        }
    }
}
