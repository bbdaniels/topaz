import XCTest

/// Topaz Launcher's matching: application names only, ranked by how the
/// query meets the name, then by use (Ben, 2026-11-08).
final class AppMatcherTests: XCTestCase {
    private func c(_ name: String) -> AppMatcher.Candidate {
        AppMatcher.Candidate(name: name, path: "/Applications/\(name).app")
    }

    private func names(_ q: String, _ list: [AppMatcher.Candidate], bonus: @escaping (AppMatcher.Candidate) -> Int = { _ in 0 }) -> [String] {
        AppMatcher.rank(q, in: list, bonus: bonus).map(\.name)
    }

    func testTiers() {
        let vsc = c("Visual Studio Code")
        XCTAssertEqual(AppMatcher.tier(AppMatcher.fold("visual studio code"), vsc), .exact)
        XCTAssertEqual(AppMatcher.tier(AppMatcher.fold("vis"), vsc), .prefix)
        XCTAssertEqual(AppMatcher.tier(AppMatcher.fold("code"), vsc), .wordPrefix)
        XCTAssertEqual(AppMatcher.tier(AppMatcher.fold("vsc"), vsc), .initials)
        XCTAssertEqual(AppMatcher.tier(AppMatcher.fold("udio"), vsc), .substring)
        XCTAssertEqual(AppMatcher.tier(AppMatcher.fold("vstc"), vsc), .subsequence)
        XCTAssertNil(AppMatcher.tier(AppMatcher.fold("xyz"), vsc))
    }

    func testCaseAndAccentsAreFolded() {
        XCTAssertEqual(AppMatcher.tier(AppMatcher.fold("SAFARI"), c("Safari")), .exact)
        XCTAssertEqual(AppMatcher.tier(AppMatcher.fold("cafe"), c("Café")), .exact)
    }

    func testCamelCaseAndDigitsStartWords() {
        XCTAssertEqual(AppMatcher.tier(AppMatcher.fold("hud"), c("ClaudeHUD")), .wordPrefix)
        XCTAssertEqual(AppMatcher.tier(AppMatcher.fold("2"), c("Civilization2")), .wordPrefix)
    }

    func testBlankQueryMatchesNothing() {
        XCTAssertEqual(names("", [c("Safari")]), [])
        XCTAssertEqual(names("   ", [c("Safari")]), [])
    }

    func testBetterTiersRankFirst() {
        let list = [c("Messages"), c("Mail"), c("Maps"), c("Photo Booth"), c("Music")]
        XCTAssertEqual(names("ma", list), ["Mail", "Maps", "Messages"])
        XCTAssertEqual(names("mail", list).first, "Mail")
    }

    func testShorterNameBreaksATie() {
        XCTAssertEqual(names("term", [c("Terminal Pro"), c("Terminal")]), ["Terminal", "Terminal Pro"])
    }

    func testUseRaisesAnAppWithinItsTier() {
        let list = [c("Mail"), c("Maps")]
        XCTAssertEqual(names("ma", list), ["Mail", "Maps"])
        XCTAssertEqual(names("ma", list) { $0.name == "Maps" ? 40 : 0 }, ["Maps", "Mail"])
    }

    func testUseNeverLiftsAWorseTier() {
        let list = [c("Safari"), c("Messages")]
        XCTAssertEqual(names("sa", list) { $0.name == "Messages" ? 99 : 0 }, ["Safari", "Messages"])
    }

    func testTheLimitHolds() {
        let list = (1...20).map { c("App \($0)") }
        XCTAssertEqual(AppMatcher.rank("app", in: list, limit: 8).count, 8)
    }

    func testFrecencyCountsAndAges() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        var f = Frecency()
        XCTAssertEqual(f.bonus("/A.app", at: now), 0)
        f.record("/A.app", at: now)
        let once = f.bonus("/A.app", at: now)
        f.record("/A.app", at: now)
        XCTAssertGreaterThan(f.bonus("/A.app", at: now), once)
        XCTAssertLessThan(f.bonus("/A.app", at: now.addingTimeInterval(40 * 86_400)), f.bonus("/A.app", at: now))
        for _ in 0..<5000 { f.record("/A.app", at: now) }
        XCTAssertLessThanOrEqual(f.bonus("/A.app", at: now), 99)
    }

    func testFrecencyPersists() {
        let d = UserDefaults(suiteName: "AppMatcherTests")!
        d.removePersistentDomain(forName: "AppMatcherTests")
        var f = Frecency()
        let now = Date()
        f.record("/A.app", at: now)
        f.save(to: d)
        XCTAssertEqual(Frecency(defaults: d).bonus("/A.app", at: now), f.bonus("/A.app", at: now))
        d.removePersistentDomain(forName: "AppMatcherTests")
    }
}
