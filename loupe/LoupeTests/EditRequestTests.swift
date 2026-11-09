import XCTest

/// The pure half of the inline editor: reading Topaz's request, the panel's
/// title, size and place, and the text Send pastes.
final class EditRequestTests: XCTestCase {
    func testAGoodRequestIsRead() throws {
        let data = Data("""
            {"version":1,"pane_id":7,"file":"/Users/u/Library/Caches/Topaz/edits/files/intro.edit.md",
             "shown":"~/Projects/paper/intro.edit.md","remote":true}
            """.utf8)
        XCTAssertEqual(try EditRequest.parse(data).get(),
                       EditRequest(version: 1, paneId: 7,
                                   file: "/Users/u/Library/Caches/Topaz/edits/files/intro.edit.md",
                                   shown: "~/Projects/paper/intro.edit.md", remote: true))
    }

    /// A version Loupe does not know is reported as such, even when its other
    /// fields changed shape.
    func testAnUnknownVersionIsRefused() {
        XCTAssertEqual(EditRequest.parse(Data(#"{"version":2,"pane_id":7,"file":"/a.edit.md","shown":"a","remote":false}"#.utf8)),
                       .failure(.unknownVersion(2)))
        XCTAssertEqual(EditRequest.parse(Data(#"{"version":3,"panes":[1]}"#.utf8)), .failure(.unknownVersion(3)))
    }

    func testAMalformedRequestIsRefused() {
        for text in ["", "not json", "[]", #"{"pane_id":7,"file":"/a","shown":"a","remote":false}"#,
                     #"{"version":1,"pane_id":"7","file":"/a","shown":"a","remote":false}"#,
                     #"{"version":1,"pane_id":7,"shown":"a","remote":false}"#,
                     #"{"version":1,"pane_id":7,"file":"relative.edit.md","shown":"a","remote":false}"#] {
            XCTAssertEqual(EditRequest.parse(Data(text.utf8)), .failure(.malformed), text)
        }
    }

    func testTheTitleDropsTheSuffix() {
        XCTAssertEqual(EditRequest.title(forFile: "/tmp/x/intro.edit.md"), "intro")
        XCTAssertEqual(EditRequest.title(forFile: "/tmp/x/notes.md"), "notes.md")
        XCTAssertEqual(EditRequest.title(forFile: "/tmp/x/.edit.md"), ".edit.md")
    }

    /// Only the end is trimmed: Send never presses Return, and the text's own
    /// leading indentation and inner blank lines are kept.
    func testSendTrimsOnlyTheEnd() {
        XCTAssertEqual(EditRequest.trimmedForSend("A line.\n\nAnother.  \n\n\t "), "A line.\n\nAnother.")
        XCTAssertEqual(EditRequest.trimmedForSend("  Indented.\r\n"), "  Indented.")
        XCTAssertEqual(EditRequest.trimmedForSend("Done."), "Done.")
        XCTAssertEqual(EditRequest.trimmedForSend(" \n\n"), "")
        XCTAssertEqual(EditRequest.trimmedForSend("Café\u{00A0}\u{2029}"), "Café")
    }

    /// The panel's top left corner is at the mouse, moved just enough to
    /// stay on the screen's visible frame.
    func testThePanelOpensAtTheMouseOnScreen() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let size = CGSize(width: 640, height: 300)
        XCTAssertEqual(EditRequest.frame(size: size, mouse: CGPoint(x: 100, y: 800), visible: visible),
                       CGRect(x: 100, y: 500, width: 640, height: 300))
        XCTAssertEqual(EditRequest.frame(size: size, mouse: CGPoint(x: 1400, y: 100), visible: visible),
                       CGRect(x: 800, y: 25, width: 640, height: 300))
        XCTAssertEqual(EditRequest.frame(size: size, mouse: CGPoint(x: -50, y: 900), visible: visible),
                       CGRect(x: 0, y: 575, width: 640, height: 300))
        XCTAssertEqual(EditRequest.frame(size: CGSize(width: 2000, height: 1000), mouse: CGPoint(x: 10, y: 10), visible: visible),
                       visible)
    }

    func testTheHeightFitsTheTextWithinBounds() {
        XCTAssertEqual(EditRequest.height(textHeight: 20, chrome: 80), 200)
        XCTAssertEqual(EditRequest.height(textHeight: 300.2, chrome: 80), 381)
        XCTAssertEqual(EditRequest.height(textHeight: 2000, chrome: 80), 600)
    }
}
