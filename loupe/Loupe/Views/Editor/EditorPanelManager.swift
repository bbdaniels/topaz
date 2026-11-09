import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.bbdaniels.topaz.loupe", category: "Editor")

/// The inline editor's panels (Ben, 2026-11-09): one floating panel per
/// `EditRequest`, opened at the mouse, which takes typing (unlike the note
/// windows, it is not a nonactivating panel). Send pastes the text into the
/// request's Topaz pane and closes the panel; Cancel closes it and sends
/// nothing. The text is never written back to its file.
@MainActor
final class EditorPanelManager {
    static let shared = EditorPanelManager()

    static let width: CGFloat = 640
    static let textInset = NSSize(width: 16, height: 14)
    static let font = NSFont.systemFont(ofSize: 15)
    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style
    }
    /// The height of the button bar below the text, divider included.
    static let barHeight: CGFloat = 52

    /// The open panels, by the absolute path of the file each edits.
    private var panels: [String: EditorPanel] = [:]

    private init() {}

    /// The files Loupe was asked to open (`application(_:open:)`): each
    /// `.topazedit` request is read, deleted and shown; anything else is
    /// logged and left alone.
    func open(urls: [URL]) {
        for url in urls {
            guard url.isFileURL, url.pathExtension == EditRequest.fileExtension else {
                logger.error("Not an edit request, ignored: \(url.path, privacy: .public)")
                continue
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                logger.error("Edit request not read: \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            // Read once: a request is never shown twice, and a malformed or
            // unknown one does not pile up in the requests folder.
            try? FileManager.default.removeItem(at: url)
            switch EditRequest.parse(data) {
            case .success(let request):
                open(request)
            case .failure(.unknownVersion(let version)):
                logger.error("Edit request of unknown version \(version), ignored: \(url.lastPathComponent, privacy: .public)")
            case .failure(.malformed):
                logger.error("Malformed edit request, ignored: \(url.lastPathComponent, privacy: .public)")
            }
        }
    }

    /// Show `request`'s text in a panel at the mouse, or bring forward the
    /// panel already editing that file.
    func open(_ request: EditRequest) {
        if let panel = panels[request.file] {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let text: String
        do {
            text = try String(contentsOfFile: request.file, encoding: .utf8)
        } catch {
            logger.error("Edit text not read: \(request.file, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return
        }

        let model = EditorModel(request: request, text: text)
        let panel = EditorPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = EditRequest.title(forFile: request.file)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 360, height: 200)
        panel.contentView = NSHostingView(rootView: EditorView(model: model))

        let contentHeight = EditRequest.height(textHeight: Self.textHeight(text),
                                               chrome: 2 * Self.textInset.height + Self.barHeight)
        let size = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: contentHeight)).size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(EditRequest.frame(size: size, mouse: mouse, visible: visible), display: false)
        } else {
            panel.setContentSize(NSSize(width: Self.width, height: contentHeight))
            panel.center()
        }

        let file = request.file
        model.onCancel = { [weak self] in self?.close(file) }
        model.onSend = { [weak self] in self?.send(model, file: file) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.panels.removeValue(forKey: file) }
        }

        panels[file] = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Paste the trimmed text into the pane off the main thread; on success
    /// close the panel and bring Topaz forward on that pane, else keep the
    /// panel open with the error in it.
    private func send(_ model: EditorModel, file: String) {
        guard !model.sending else { return }
        let text = EditRequest.trimmedForSend(model.text)
        guard !text.isEmpty else {
            model.error = "The text is empty: nothing to send."
            return
        }
        model.error = nil
        model.sending = true
        let paneId = model.request.paneId
        DispatchQueue.global(qos: .userInitiated).async {
            let error = WezTerm.sendText(text, paneId: paneId)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    model.sending = false
                    if let error {
                        logger.error("Edit not sent to pane \(paneId): \(error, privacy: .public)")
                        model.error = "Not sent: \(error)"
                        return
                    }
                    self.close(file)
                    WezTerm.activateApp()
                }
            }
        }
    }

    private func close(_ file: String) {
        panels.removeValue(forKey: file)?.close()
    }

    /// The height `text` lays out to at the panel's width, in the editor's
    /// font and line spacing, wrapped as the text view wraps it.
    private static func textHeight(_ text: String) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: font, .paragraphStyle: paragraphStyle])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width - 2 * textInset.width,
                                                     height: .greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return max(layout.usedRect(for: container).height, font.boundingRectForFont.height)
    }
}

/// A floating panel that becomes key, so its text view takes typing.
final class EditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
