import AppKit
import SwiftUI

/// One editor panel's state: the request, the text as Ben edits it, and the
/// Send in progress or its error. The manager sets the two actions.
@MainActor
final class EditorModel: ObservableObject {
    let request: EditRequest
    /// The text as it is now; the text view writes it on every change.
    var text: String
    @Published var sending = false
    @Published var error: String?
    var onSend: () -> Void = {}
    var onCancel: () -> Void = {}

    init(request: EditRequest, text: String) {
        self.request = request
        self.text = text
    }
}

/// The panel's content: the text, and below it Cancel (Escape) and Send
/// (Command-Return), with Send's error when it failed.
struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            EditorTextView(model: model)
            Divider()
            HStack(spacing: 10) {
                if let error = model.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .help(error)
                }
                Spacer(minLength: 0)
                if model.sending {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { model.onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close without sending (Escape)")
                Button("Send") { model.onSend() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.sending)
                    .help("Paste into the pane, without pressing Return (Command-Return)")
            }
            .padding(.horizontal, 14)
            .frame(height: EditorPanelManager.barHeight - 1)
        }
    }
}

/// The text itself: an AppKit text view, plain text, wrapped to the panel's
/// width (no horizontal scrolling; wrapping inserts no line breaks), with
/// undo and continuous spell checking. Substitutions that would change what
/// Ben types (smart quotes and dashes, text replacement, autocorrection) are
/// off, so what is pasted is what he typed.
struct EditorTextView: NSViewRepresentable {
    let model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = EditorPanelManager.textInset
        textView.textContainer?.lineFragmentPadding = 0

        let font = EditorPanelManager.font
        let style = EditorPanelManager.paragraphStyle
        textView.font = font
        textView.defaultParagraphStyle = style
        textView.typingAttributes = [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.textColor]
        textView.string = model.text
        if let storage = textView.textStorage {
            storage.setAttributes([.font: font, .paragraphStyle: style, .foregroundColor: NSColor.textColor],
                                  range: NSRange(location: 0, length: storage.length))
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.delegate = context.coordinator

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.scrollToBeginningOfDocument(nil)
        }
        return scroll
    }

    /// The text view owns the text while the panel is open, so nothing is
    /// pushed back into it (which would move the cursor and break undo).
    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: EditorModel

        init(model: EditorModel) { self.model = model }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            MainActor.assumeIsolated { model.text = textView.string }
        }

        /// Escape and Command-Return reach the text view before the buttons'
        /// shortcuts can, so they are answered here as well: Escape cancels
        /// (rather than offering completions), Command-Return sends.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                MainActor.assumeIsolated { model.onCancel() }
                return true
            case #selector(NSResponder.insertNewline(_:))
                where NSApp.currentEvent?.modifierFlags.contains(.command) == true:
                MainActor.assumeIsolated { model.onSend() }
                return true
            default:
                return false
            }
        }
    }
}
