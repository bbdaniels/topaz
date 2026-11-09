import CoreGraphics

/// Magnet's window snapping, as Ben had it set on 2026-11-08: the bindings
/// below were read from Magnet 3.0.7's own preferences
/// (`defaults export com.crowdcafe.windowmagnet`, the `horizontalCommands`
/// and `verticalCommands` lists) and keep Magnet's grid: a landscape screen
/// is 24 columns by 12 rows, a portrait one 12 by 24, counted from the top
/// left of the screen's visible frame (below the menu bar, beside the Dock).
/// Magnet keeps a list for each orientation and binds a chord in each, so a
/// chord does what that list says for the screen the window is on, and
/// nothing where that list has no binding. Commands Ben left unbound (the
/// quarters, top and bottom halves, the displays, center, restore) are left
/// out.
enum SnapLayout {
    /// A chord as Carbon names it, as Magnet stores it.
    struct Chord: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// A rectangle in grid cells, from the top left.
    struct Cells: Equatable {
        let x: Int, y: Int, w: Int, h: Int
    }

    struct Command: Equatable {
        let name: String
        let chord: Chord
        let cells: Cells
    }

    enum Orientation { case landscape, portrait
        var columns: Int { self == .landscape ? 24 : 12 }
        var rows: Int { self == .landscape ? 12 : 24 }
    }

    // Carbon's modifier bits and key codes (Carbon.HIToolbox), spelled out
    // so this file needs only CoreGraphics.
    static let cmd: UInt32 = 0x0100, shift: UInt32 = 0x0200, option: UInt32 = 0x0800, control: UInt32 = 0x1000
    static let left: UInt32 = 123, right: UInt32 = 124, down: UInt32 = 125, up: UInt32 = 126, keyR: UInt32 = 15

    static let landscape: [Command] = [
        Command(name: "Left half", chord: Chord(keyCode: left, modifiers: cmd | shift), cells: Cells(x: 0, y: 0, w: 12, h: 12)),
        Command(name: "Right half", chord: Chord(keyCode: right, modifiers: cmd | shift), cells: Cells(x: 12, y: 0, w: 12, h: 12)),
        Command(name: "Left third", chord: Chord(keyCode: down, modifiers: cmd | shift), cells: Cells(x: 0, y: 0, w: 8, h: 12)),
        Command(name: "Center third", chord: Chord(keyCode: down, modifiers: cmd), cells: Cells(x: 8, y: 0, w: 8, h: 12)),
        Command(name: "Right third", chord: Chord(keyCode: right, modifiers: cmd), cells: Cells(x: 16, y: 0, w: 8, h: 12)),
        Command(name: "Left two thirds", chord: Chord(keyCode: left, modifiers: cmd), cells: Cells(x: 0, y: 0, w: 16, h: 12)),
        Command(name: "Center two thirds", chord: Chord(keyCode: keyR, modifiers: control | option), cells: Cells(x: 4, y: 0, w: 16, h: 12)),
        Command(name: "Maximize", chord: Chord(keyCode: up, modifiers: cmd), cells: Cells(x: 0, y: 0, w: 24, h: 12)),
    ]

    static let portrait: [Command] = [
        Command(name: "Left half", chord: Chord(keyCode: left, modifiers: cmd | shift), cells: Cells(x: 0, y: 0, w: 6, h: 24)),
        Command(name: "Right half", chord: Chord(keyCode: right, modifiers: cmd | shift), cells: Cells(x: 6, y: 0, w: 6, h: 24)),
        Command(name: "Bottom third", chord: Chord(keyCode: right, modifiers: cmd), cells: Cells(x: 0, y: 16, w: 12, h: 8)),
        Command(name: "Top two thirds", chord: Chord(keyCode: left, modifiers: cmd), cells: Cells(x: 0, y: 0, w: 12, h: 16)),
        Command(name: "Center two thirds", chord: Chord(keyCode: keyR, modifiers: control | option), cells: Cells(x: 0, y: 4, w: 12, h: 16)),
        Command(name: "Maximize", chord: Chord(keyCode: up, modifiers: cmd), cells: Cells(x: 0, y: 0, w: 12, h: 24)),
    ]

    /// Every chord either list binds, each once, in a stable order.
    static var chords: [Chord] {
        var seen = Set<Chord>(), out: [Chord] = []
        for c in landscape + portrait where seen.insert(c.chord).inserted { out.append(c.chord) }
        return out
    }

    static func orientation(of visible: CGRect) -> Orientation {
        visible.width >= visible.height ? .landscape : .portrait
    }

    static func command(for chord: Chord, _ orientation: Orientation) -> Command? {
        (orientation == .landscape ? landscape : portrait).first { $0.chord == chord }
    }

    /// The frame for `cells` within `visible`, both with a top-left origin
    /// (Accessibility's coordinates), on whole points, so neighbours meet
    /// with no gap and no overlap.
    static func frame(_ cells: Cells, _ orientation: Orientation, in visible: CGRect) -> CGRect {
        func edge(_ start: CGFloat, _ length: CGFloat, _ n: Int, _ of: Int) -> CGFloat {
            (start + length * CGFloat(n) / CGFloat(of)).rounded()
        }
        let x0 = edge(visible.minX, visible.width, cells.x, orientation.columns)
        let x1 = edge(visible.minX, visible.width, cells.x + cells.w, orientation.columns)
        let y0 = edge(visible.minY, visible.height, cells.y, orientation.rows)
        let y1 = edge(visible.minY, visible.height, cells.y + cells.h, orientation.rows)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// AppKit's screen rectangles (bottom-left origin, the primary screen's
    /// bottom at 0) in Accessibility's (top-left origin, the primary screen's
    /// top at 0).
    static func flipped(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Where `chord` puts a window now at `window` (Accessibility
    /// coordinates), given each screen's frame and visible frame (AppKit
    /// coordinates, the primary screen first); nil when the list for that
    /// screen binds nothing to the chord. The window's screen is the one it
    /// overlaps most, else the primary.
    static func target(for chord: Chord, window: CGRect,
                       screens: [(frame: CGRect, visible: CGRect)]) -> CGRect? {
        guard let primary = screens.first else { return nil }
        let h = primary.frame.height
        let visibles = screens.map { flipped($0.visible, primaryHeight: h) }
        let frames = screens.map { flipped($0.frame, primaryHeight: h) }
        var best = 0, bestArea: CGFloat = 0
        for (i, f) in frames.enumerated() {
            let overlap = f.intersection(window)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea { best = i; bestArea = area }
        }
        let visible = visibles[best]
        let o = orientation(of: visible)
        guard let command = command(for: chord, o) else { return nil }
        return frame(command.cells, o, in: visible)
    }
}
