import Cocoa
import os

private let logger = Logger(subsystem: "com.claudehud", category: "Hotkey")

// MARK: - Hotkey Service

/// Loupe's global shortcuts: Cmd+Shift+Space toggles the panel, and
/// Ctrl+Opt+Cmd+B shows or hides the other menu bar items (Ben, 2026-11-08).
///
/// Uses NSEvent monitors: a global monitor for when the app is in the background,
/// and a local monitor for when the app is in the foreground. The global one
/// needs Loupe's Accessibility permission.
@MainActor
class HotkeyService: ObservableObject {
    @Published var isRegistered = false

    struct Shortcut {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let name: String

        /// Cmd+Shift+Space (keyCode 49 = Space): the panel.
        static let panel = Shortcut(keyCode: 49, modifiers: [.command, .shift], name: "Cmd+Shift+Space")
        /// Ctrl+Opt+Cmd+B (keyCode 11 = B): the hidden menu bar items. No
        /// system or common app shortcut uses it.
        static let menuBarItems = Shortcut(keyCode: 11, modifiers: [.control, .option, .command],
                                           name: "Ctrl+Opt+Cmd+B")
        /// As the menu shows it.
        static let menuBarItemsSymbols = "⌃⌥⌘B"

        /// The required modifiers are held (others, such as Caps Lock, are ignored).
        func matches(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return event.keyCode == keyCode && flags.contains(modifiers)
        }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var bindings: [(shortcut: Shortcut, action: () -> Void)] = []

    // MARK: - Register

    /// Register the panel's hotkey. The `onToggle` closure is called on the main thread
    /// whenever the hotkey combination is pressed.
    func register(onToggle: @escaping () -> Void) {
        register(.panel, action: onToggle)
    }

    /// Register a global shortcut; `action` runs on the main thread.
    func register(_ shortcut: Shortcut, action: @escaping () -> Void) {
        bindings.append((shortcut, action))
        installMonitors()
        logger.info("Global hotkey registered: \(shortcut.name, privacy: .public)")
    }

    private func installMonitors() {
        guard !isRegistered else { return }

        // Global monitor: fires when the app is NOT the key window / frontmost
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.fire(event) }
        }

        // Local monitor: fires when the app IS the key window
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let fired = MainActor.assumeIsolated { self?.fire(event) ?? false }
            return fired ? nil : event // a shortcut is consumed, anything else passes through
        }

        isRegistered = true
    }

    /// Runs the first matching shortcut's action, after this event; true if one matched.
    private func fire(_ event: NSEvent) -> Bool {
        guard let action = bindings.first(where: { $0.shortcut.matches(event) })?.action else { return false }
        DispatchQueue.main.async { action() }
        return true
    }

    // MARK: - Unregister

    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        bindings = []
        isRegistered = false
        logger.info("Global hotkeys unregistered")
    }

    deinit {
        // Clean up monitors. Since deinit is nonisolated and NSEvent.removeMonitor
        // is thread-safe, this is fine.
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }
}
