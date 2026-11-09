import AppKit
import SwiftUI

/// Hosting for SwiftUI content that runs up into a titled window's title-bar
/// strip (`.fullSizeContentView`), as the HUD panel's header and the note
/// windows' headers do.
///
/// The hosting view is told about no safe area (`safeAreaRegions = []`), so
/// its content starts at the window's top edge by itself. Left at the default,
/// SwiftUI knows the title bar as a top safe-area inset, and a row of controls
/// lying wholly inside that inset (the HUD header at 29 points, in a 32-point
/// title bar) gets no clicks: the hosting view keeps every mouse-down for
/// itself and AppKit moves the window instead (Ben, 2026-11-08: tabs, info and
/// lock dead since the header shrank to Topaz's tab-bar height). With no safe
/// area, the header's controls take their clicks and its empty space reaches
/// `WindowDragArea`, which moves the window.
enum StripHosting {
    static func controller<Content: View>(_ rootView: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: rootView)
        controller.safeAreaRegions = []
        return controller
    }

    static func view<Content: View>(_ rootView: Content) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: rootView)
        view.safeAreaRegions = []
        return view
    }
}
