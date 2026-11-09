import Cocoa
import os

private let logger = Logger(subsystem: "com.bbdaniels.topaz.launcher", category: "Panel")
private let timing = Logger(subsystem: "com.bbdaniels.topaz.launcher", category: "Timing")

/// A panel that takes the keyboard without activating the launcher, so the
/// app Ben was in stays frontmost until he picks another.
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The row's selection stays blue while the search field, not the table,
/// has the keyboard.
private final class RowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
}

/// The launcher's window: built once at launch and kept, so showing it is a
/// move, an order-front and an alpha change, never a window being made
/// (the plan's speed bar: as fast as Raycast at the hotkey and at each
/// keystroke). A search field over up to eight rows; the panel is the field
/// alone until a query matches, as Raycast's is.
@MainActor
final class LauncherController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let width: CGFloat = 750
    static let fieldHeight: CGFloat = 64
    static let rowHeight: CGFloat = 44
    static let maxRows = 8

    private let index: AppIndex
    private var frecency: Frecency
    private let defaults: UserDefaults
    private let panel: LauncherPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let divider = NSBox()
    private var results: [AppMatcher.Candidate] = []
    private var icons: [String: NSImage] = [:]
    private(set) var isShown = false

    init(index: AppIndex, defaults: UserDefaults = .standard) {
        self.index = index
        self.defaults = defaults
        frecency = Frecency(defaults: defaults)
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        panel.level = .modalPanel
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .light)
        field.placeholderString = "Open an app"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        effect.addSubview(field)

        divider.boxType = .separator
        effect.addSubview(divider)

        let column = NSTableColumn(identifier: .init("app"))
        column.width = Self.width - 16
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        effect.addSubview(scroll)

        layout(rows: 0)
        // Warm the window server and the drawing path once, off screen and
        // invisible, so the first hotkey costs no more than the others.
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        _ = AppMatcher.rank("a", in: index.candidates)
    }

    // MARK: Showing and hiding

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        let started = ProcessInfo.processInfo.systemUptime
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        field.stringValue = ""
        results = []
        table.reloadData()
        layout(rows: 0)
        if let frame = screen?.frame {
            let top = frame.maxY - (frame.height * 0.14).rounded()
            panel.setFrameTopLeftPoint(NSPoint(x: (frame.midX - Self.width / 2).rounded(), y: top))
        }
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        isShown = true
        timing.info("shown in \(Self.ms(since: started), privacy: .public) ms after the hotkey handler began")
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel.orderOut(nil)
        panel.alphaValue = 0
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    /// The panel's height for `rows` result rows, its top edge kept.
    private func layout(rows: Int) {
        let listHeight = rows == 0 ? 0 : CGFloat(rows) * Self.rowHeight + 12
        let height = Self.fieldHeight + listHeight
        var frame = panel.frame
        if frame.height != height {
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: false, animate: false)
        }
        field.frame = NSRect(x: 20, y: height - Self.fieldHeight + 16, width: Self.width - 40, height: 32)
        divider.isHidden = rows == 0
        divider.frame = NSRect(x: 0, y: listHeight, width: Self.width, height: 1)
        scroll.frame = NSRect(x: 8, y: 6, width: Self.width - 16, height: max(0, listHeight - 12))
    }

    // MARK: Typing

    func controlTextDidChange(_ obj: Notification) {
        let typed = NSApp.currentEvent?.timestamp
        results = AppMatcher.rank(field.stringValue, in: index.candidates, limit: Self.maxRows) { [frecency] c in
            frecency.bonus(c.path, at: Date())
        }
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        layout(rows: results.count)
        panel.displayIfNeeded()
        if let typed {
            timing.info("keystroke to results drawn: \(Self.ms(since: typed), privacy: .public) ms (\(self.results.count, privacy: .public) rows)")
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): hide(); return true
        default: return false
        }
    }

    private func move(_ by: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(table.selectedRow + by, 0), results.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        openSelected()
    }

    private func openSelected() {
        let row = table.selectedRow
        guard results.indices.contains(row) else { return }
        open(results[row])
    }

    /// A running app is brought forward (unhidden if hidden); any other is
    /// launched.
    private func open(_ c: AppMatcher.Candidate) {
        hide()
        frecency.record(c.path, at: Date())
        frecency.save(to: defaults)
        if let app = index.runningApp(at: c.path) {
            if app.isHidden { app.unhide() }
            if !app.activate(options: [.activateAllWindows]) {
                logger.error("\(c.name, privacy: .public) did not come forward")
            }
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: c.path), configuration: config) { _, error in
            if let error { logger.error("cannot open \(c.path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
        let c = results[row]
        cell.textField?.stringValue = c.name
        cell.imageView?.image = icon(c.path)
        (cell.viewWithTag(7) as? NSTextField)?.stringValue = index.running.contains(c.path) ? "Running" : ""
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView(frame: NSRect(x: 10, y: 6, width: 32, height: 32))
        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: 15)
        name.frame = NSRect(x: 54, y: 12, width: Self.width - 200, height: 20)
        name.autoresizingMask = [.width]
        let state = NSTextField(labelWithString: "")
        state.tag = 7
        state.font = .systemFont(ofSize: 12)
        state.textColor = .secondaryLabelColor
        state.alignment = .right
        state.frame = NSRect(x: Self.width - 136, y: 13, width: 100, height: 18)
        state.autoresizingMask = [.minXMargin]
        cell.addSubview(image)
        cell.addSubview(name)
        cell.addSubview(state)
        cell.imageView = image
        cell.textField = name
        return cell
    }

    /// Each app's icon, read from its bundle the first time it is shown.
    private func icon(_ path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        icons[path] = image
        return image
    }

    /// Reads every app's icon ahead of the first query, so no keystroke
    /// waits on a bundle's icon file.
    func preloadIcons() {
        let paths = index.candidates.map(\.path).filter { icons[$0] == nil }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = paths.map { path -> (String, NSImage) in
                let image = NSWorkspace.shared.icon(forFile: path)
                image.size = NSSize(width: 32, height: 32)
                // Draw it once at the row's size, so the first row that
                // shows it draws a ready bitmap.
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                if let rep, let context = NSGraphicsContext(bitmapImageRep: rep) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
                    NSGraphicsContext.restoreGraphicsState()
                    let ready = NSImage(size: NSSize(width: 32, height: 32))
                    ready.addRepresentation(rep)
                    return (path, ready)
                }
                return (path, image)
            }
            DispatchQueue.main.async {
                for (path, image) in loaded where self?.icons[path] == nil { self?.icons[path] = image }
            }
        }
    }

    private static func ms(since uptime: TimeInterval) -> String {
        String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - uptime) * 1000)
    }
}
