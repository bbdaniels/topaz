import Cocoa
import TopazKit
import os

private let logger = Logger(subsystem: "com.bbdaniels.topaz.launcher", category: "App")

/// Topaz Launcher: Topaz's application launcher (Option-Space) and Magnet's
/// window snapping, as a helper Topaz starts from
/// `Topaz.app/Contents/Helpers` and supervises (wezterm-gui `helpers.rs`).
/// It has no Dock icon or menu; it quits when Topaz does.
@MainActor
final class LauncherDelegate: NSObject, NSApplicationDelegate {
    /// Option-Space. Raycast keeps Command-Space until the cutover.
    static let chord = SnapLayout.Chord(keyCode: 49, modifiers: SnapLayout.option)

    private let hotKeys = HotKeyCenter()
    private let index = AppIndex()
    private var controller: LauncherController?
    private var snapper: Snapper?
    private var parentWatch: DispatchSourceProcess?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let pid = ParentWatch.parentPid(ProcessInfo.processInfo.environment) {
            parentWatch = ParentWatch.watch(pid) {
                logger.info("Topaz (\(pid, privacy: .public)) exited: quitting")
                NSApp.terminate(nil)
            }
        }
        let controller = LauncherController(index: index)
        self.controller = controller
        var iconsLoaded = false
        index.onChange = {
            if !iconsLoaded, !self.index.candidates.isEmpty { iconsLoaded = true; controller.preloadIcons() }
        }
        index.start()
        let chord = Self.chord
        switch hotKeys.register(keyCode: chord.keyCode, modifiers: chord.modifiers, { controller.toggle() }) {
        case .success: logger.info("Option-Space bound")
        case .failure(let e): logger.error("Option-Space refused: \(e.status, privacy: .public)")
        }
        snapper = Snapper(hotKeys: hotKeys)
    }
}

@main
enum TopazLauncherMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { LauncherDelegate() }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
