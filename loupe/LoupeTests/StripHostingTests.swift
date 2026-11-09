import AppKit
import SwiftUI
import XCTest

/// A header row inside a titled, full-size-content window's title-bar strip
/// must get its clicks (Ben, 2026-11-08: the HUD header's tabs, info and lock
/// did nothing once the header was 29 points, inside the 32-point strip).
@MainActor
final class StripHostingTests: XCTestCase {
    private struct Header: View {
        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: {}) { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .frame(width: 25, height: 25)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
                Spacer()
            }
            .frame(width: 380, height: 420)
        }
    }

    private func panel(_ content: NSViewController) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.contentViewController = content
        panel.setFrame(NSRect(x: 0, y: 0, width: 380, height: 452), display: true)
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return panel
    }

    /// The view that gets a mouse-down at the info button, 15 points below the
    /// window's top edge and 26 points in from its right edge.
    private func hitAtButton(_ panel: NSPanel) -> NSView? {
        let point = NSPoint(x: panel.frame.width - 26.5, y: panel.frame.height - 15)
        return panel.contentView?.superview?.hitTest(point)
    }

    func testAHeaderButtonInsideTheTitleBarStripGetsTheClick() throws {
        let panel = panel(StripHosting.controller(Header()))
        defer { panel.close() }
        let titleBar = panel.frame.height - panel.contentLayoutRect.height
        XCTAssertGreaterThan(titleBar, 29, "the header must lie wholly inside the title-bar strip for this test to mean anything")
        let hit = try XCTUnwrap(hitAtButton(panel))
        XCTAssertFalse(hit === panel.contentView, "the hosting view kept the click; got \(type(of: hit))")
    }
}
