import XCTest

/// The menu bar's Open Sessions (`SessionMenu.entries`): exactly the panel's
/// session lines, General first, then each project A to Z. Before 2026-11-07
/// it listed Ghostty windows by title, so it showed duplicates and ended
/// sessions' windows and missed the iMac and phone sessions with no window.
final class SessionMenuTests: XCTestCase {

    func line(_ id: String, _ name: String, machine: String = "iMac",
              light: SessionLight = .running) -> LiveSessionLine {
        LiveSessionLine(id: id, sessionId: id, name: name, machine: machine,
                        isIMac: machine == "iMac", light: light, hasWindow: false)
    }

    func testEmptyRosterListsNothing() {
        XCTAssertEqual(SessionMenu.entries(general: [], byFolder: [:]), [])
        XCTAssertEqual(SessionMenu.entries(general: [], byFolder: ["ai-med": []]), [])
    }

    /// Ben's case: two live iMac sessions and nothing else, however many
    /// Ghostty windows are open, give two entries, one per session.
    func testOneEntryPerLiveSession() {
        let e = SessionMenu.entries(general: [], byFolder: [
            "raspberry-pi": [line("a1", "Session menu reconcile")],
            "ai-med": [line("b2", "Draft results")],
        ])
        XCTAssertEqual(e.map(\.id), ["b2", "a1"])
        XCTAssertEqual(e.map(\.project), ["ai-med", "raspberry-pi"])
        XCTAssertEqual(e.map(\.folder), ["ai-med", "raspberry-pi"])
        XCTAssertEqual(e.map(\.name), ["Draft results", "Session menu reconcile"])
        XCTAssertEqual(e.map(\.machine), ["iMac", "iMac"])
    }

    /// General leads, as at the top of the panel, with no folder, so a click
    /// opens it in a new window as its panel line does. Projects sort A to Z
    /// whatever their case.
    func testGeneralFirstThenProjectsAlphabetical() {
        let e = SessionMenu.entries(general: [line("g", "Phone question", machine: "phone")], byFolder: [
            "nemesis-tv": [line("n", "Remote")],
            "Genealogy": [line("q", "Census")],
            "ai-med": [line("m", "Tables")],
        ])
        XCTAssertEqual(e.map(\.project), ["General", "ai-med", "Genealogy", "nemesis-tv"])
        XCTAssertEqual(e.first?.folder, nil)
        XCTAssertEqual(e.first?.machine, "phone")
    }

    /// Two sessions of one project are two entries told apart by name and
    /// machine, in the panel's order: the order given, leftovers last
    /// (`LiveSessionLine.lines` does that move) and faded.
    func testSessionsOfOneProjectKeepThePanelOrder() {
        let e = SessionMenu.entries(general: [], byFolder: [
            "personal": [line("x", "Planner", machine: "MacBook"),
                         line("y", "Old run", light: .dimmed)],
        ])
        XCTAssertEqual(e.map(\.id), ["x", "y"])
        XCTAssertEqual(e.map(\.project), ["personal", "personal"])
        XCTAssertEqual(e.map(\.machine), ["MacBook", "iMac"])
        XCTAssertEqual(e.map(\.dimmed), [false, true])
    }
}
