import Cocoa
import SwiftUI
import os

private let logger = Logger(subsystem: "com.bbdaniels.topaz.loupe", category: "Panel")

class HUDPanelController {
    private var panel: NSPanel?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            // No .hudWindow: HUD-style panels suppress AppKit tooltips
            // (NSView.toolTip / SwiftUI .help) entirely. The titlebar is
            // already hidden via titleVisibility/titlebarAppearsTransparent
            // and the SwiftUI content draws its own translucent background,
            // so dropping .hudWindow is visually ~identical but restores
            // tooltips.
            // .fullSizeContentView (Ben, 2026-11-08): with the window buttons
            // gone, the header row moves up into the empty title-bar strip;
            // its empty space moves the window (WindowDragArea).
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.level = .normal
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        // THE tooltip fix. The panel is usually shown from a
        // status-item click or the hotkey, so the app is usually NOT
        // the active app while the user mouses over the panel. macOS suppresses
        // NSView.toolTip (which SwiftUI `.help()` uses) for windows of an
        // inactive app unless this is set — which is why NO tooltip ever
        // appeared, regardless of the host view or .hudWindow.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.isReleasedWhenClosed = false
        // Space-following. This is a menubar-SUMMONED panel, not a persistent
        // overlay, so the right model is "come to the desktop I'm on when I
        // call it," i.e. `.moveToActiveSpace` — it relocates the window to the
        // active Space whenever the app activates, which `show()` triggers via
        // NSApp.activate(...). `.canJoinAllSpaces` (the old value) is passive
        // omnipresence — it's meant to keep the window live on ALL Spaces at
        // once, but for a `.level = .normal` toggled panel it did not hold: the
        // window stayed pinned to its origin Space and never appeared on a
        // second regular desktop. `.moveToActiveSpace` has a concrete trigger
        // (activation) and doesn't change stacking, so the panel can still go
        // behind other windows. Pairs with the isOnActiveSpace check in
        // toggle() below. (canJoinAllSpaces and moveToActiveSpace are mutually
        // exclusive — you get one.)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = true
        panel.backgroundColor = .hudBackground
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // No close, minimize or zoom buttons (Ben, 2026-11-08): the panel opens and closes
        // from the menu-bar icon and the hotkey.
        // Hidden rather than dropped from the style mask, so .closable keeps
        // Cmd-W and .titled keeps the drag strip at the top.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        // Was true ("drag anywhere to move the window"), but AppKit's
        // move-by-background tracking consumes mouse-drag sequences over the
        // SwiftUI content before any in-content gesture or system drag sees them
        // — clicks still land (tab switching works) but NO drag does (tab
        // reordering, etc.). Off here; the window is still movable by its
        // (hidden, transparent) title-bar strip at the very top. See
        // HUDContentView.TabBar drag-to-reorder.
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 380, height: 420)

        let contentView = HUDContentView()
            .environmentObject(appState)
            .environmentObject(appState.terminalService)
            .environmentObject(appState.sessionHistoryService)
            .environmentObject(appState.vaultManager)
            .environmentObject(appState.usageService)
            .environmentObject(appState.skillsService)
            .environmentObject(appState.remoteControlServer)

        // Host SwiftUI via an NSHostingController set as contentViewController,
        // NOT a bare NSHostingView assigned to contentView. SwiftUI `.help()`
        // tooltips are delivered through the hosting *controller*'s
        // participation in the responder chain; with a raw NSHostingView there
        // is no controller, so every `.help(...)` in the app silently no-ops
        // and no tooltip ever appears. StripHosting lets the header in the
        // title-bar strip take its clicks.
        let controller = StripHosting.controller(contentView)
        // The window's frame is ours, not the content's: left to size the
        // window, the controller shrank it to the content's minimum on every
        // launch (380 by 452).
        controller.sizingOptions = []
        panel.contentViewController = controller
        // Every launch opens the panel in the full right third of the screen,
        // beside Topaz (PanelPlacement). No frame autosave: the saved frame
        // was the one the controller had shrunk.
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrame(PanelPlacement.rightThird(of: screen.visibleFrame, minWidth: panel.minSize.width),
                           display: false)
        }

        self.panel = panel
    }

    func show() {
        if panel == nil { createPanel() }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() {
        // `isVisible` is global (true if the panel is on-screen on ANY Space),
        // so a bare isVisible check would HIDE the panel when you summon it
        // from a different desktop than the one it's open on — the opposite of
        // "bring it here." Only treat the toggle as a hide when the panel is
        // actually on the desktop you're looking at; otherwise show() (which
        // activates the app and, via .moveToActiveSpace, pulls the panel to the
        // current Space).
        // A panel wholly buried under another app's window is brought
        // forward; any panel that can be seen is hidden (`PanelToggle`).
        let visible = panel?.isVisible ?? false
        let onSpace = panel?.isOnActiveSpace ?? false
        let uncovered = panel?.occlusionState.contains(.visible) ?? false
        let action = PanelToggle.action(isVisible: visible, isOnActiveSpace: onSpace, isUncovered: uncovered)
        logger.info("panel toggle: visible \(visible, privacy: .public), on this desktop \(onSpace, privacy: .public), uncovered \(uncovered, privacy: .public), key \(self.panel?.isKeyWindow ?? false, privacy: .public): \(action == .hide ? "hide" : "show", privacy: .public)")
        if action == .hide { hide() } else { show() }
    }
}

extension NSColor {
    /// The panel's background (Ben, 2026-11-08: "don't let the match drift, fix it at the same
    /// color as the main hud background"). A fixed color, not windowBackgroundColor, which macOS
    /// tints from the desktop behind the window. Topaz's tab bar uses the same two values
    /// (bbdaniels/personal deploy/mac/wezterm/wezterm.lua, HUD_BG); change both together.
    static let hudBackground = NSColor(name: "hudBackground") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x28 / 255.0, green: 0x25 / 255.0, blue: 0x24 / 255.0, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }
}
