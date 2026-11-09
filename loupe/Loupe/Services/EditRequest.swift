import CoreGraphics
import Foundation

/// A request from Topaz to edit a passage in place (the inline editor, Ben,
/// 2026-11-09). Claude writes the passage to a file ending `.edit.md` and
/// prints its path; a click on that path in a Topaz pane writes one of these
/// as JSON to `~/Library/Caches/Topaz/edits/requests/<unique>.topazedit` and
/// opens it with Loupe (`open -a Loupe.app <file>`). Loupe shows the text in
/// an editor panel (`EditorPanelManager`) and Send pastes the edited text
/// into the pane, where Ben adds a note and presses Return himself.
///
/// The parsing, the title, the trim and the placement are pure and unit
/// tested; the panel runs them.
struct EditRequest: Codable, Equatable {
    /// The one version Loupe reads. A request of any other version is
    /// ignored, so a Topaz that changed the format cannot be misread.
    static let currentVersion = 1
    /// The extension of a request file, declared in Info.plist.
    static let fileExtension = "topazedit"
    /// The suffix that marks a passage to edit; dropped from the title.
    static let textSuffix = ".edit.md"

    let version: Int
    /// The WezTerm mux pane the path was clicked in, where Send pastes.
    let paneId: Int
    /// The absolute local path of the text (for an iMac pane, Topaz's copy).
    let file: String
    /// The path as the pane showed it.
    let shown: String
    /// Whether the path was on another machine (an iMac pane).
    let remote: Bool

    enum CodingKeys: String, CodingKey {
        case version, file, shown, remote
        case paneId = "pane_id"
    }

    /// Why a request file was not used.
    enum Failure: Error, Equatable {
        case malformed
        case unknownVersion(Int)
    }

    /// The request in `data`. The version is read first, so a request of a
    /// newer version is reported as such even when its other fields changed.
    static func parse(_ data: Data) -> Result<EditRequest, Failure> {
        struct Versioned: Decodable { let version: Int }
        guard let versioned = try? JSONDecoder().decode(Versioned.self, from: data) else {
            return .failure(.malformed)
        }
        guard versioned.version == currentVersion else {
            return .failure(.unknownVersion(versioned.version))
        }
        guard let request = try? JSONDecoder().decode(EditRequest.self, from: data),
              request.file.hasPrefix("/") else {
            return .failure(.malformed)
        }
        return .success(request)
    }

    /// The panel's title: the file's name without `.edit.md`
    /// ("intro.edit.md" is "intro"); the whole name when it lacks the suffix.
    static func title(forFile path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(textSuffix), name.count > textSuffix.count else { return name }
        return String(name.dropLast(textSuffix.count))
    }

    /// The text Send pastes: the edit without the whitespace and newlines it
    /// ends with, so the paste leaves the cursor right after the last word
    /// and never submits the prompt. Leading text is kept as it is.
    static func trimmedForSend(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let before = text.index(before: end)
            guard text[before].isWhitespace || text[before].isNewline else { break }
            end = before
        }
        return String(text[..<end])
    }

    /// The panel's frame: its top left corner at the mouse, moved only as far
    /// as it must be to lie wholly inside the screen's visible frame (AppKit
    /// coordinates, y up).
    static func frame(size: CGSize, mouse: CGPoint, visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let x = min(max(mouse.x, visible.minX), visible.maxX - width)
        let top = min(max(mouse.y, visible.minY + height), visible.maxY)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// The panel's height for text whose laid out height is `textHeight`:
    /// that plus the room around it, between 200 and 600 points.
    static func height(textHeight: CGFloat, chrome: CGFloat) -> CGFloat {
        min(max((textHeight + chrome).rounded(.up), 200), 600)
    }
}
