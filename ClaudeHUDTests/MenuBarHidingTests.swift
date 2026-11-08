import XCTest

/// MenuBarHiding: "Hide Other Menu Bar Items" holds macOS 27's menu bar
/// allow-list (MenuBarClientCore's assessment-mode assertion) while it is on,
/// letting only ClaudeHUD's item and the system's show (Ben, 2026-11-08).
@MainActor
final class MenuBarHidingTests: XCTestCase {
    /// Records each activation and answers when the test says so.
    final class FakeRestrictor: MenuBarRestricting {
        final class Handle: MenuBarRestriction {
            var invalidated = 0
            func invalidate() { invalidated += 1 }
        }
        var isAvailable = true
        var calls: [(system: [Int], bundles: [String])] = []
        var pending: [(Result<MenuBarRestriction, Error>) -> Void] = []
        var handles: [Handle] = []
        var agent: Int32? = 648
        func enforcer() -> Int32? { agent }

        func activate(allowedSystemItems: [Int], allowedBundleIdentifiers: [String],
                      completion: @escaping (Result<MenuBarRestriction, Error>) -> Void) {
            calls.append((allowedSystemItems, allowedBundleIdentifiers))
            pending.append(completion)
        }
        /// Answers the oldest unanswered activation.
        @discardableResult
        func grant() -> Handle {
            let h = Handle(); handles.append(h)
            pending.removeFirst()(.success(h))
            return h
        }
        func refuse() {
            pending.removeFirst()(.failure(NSError(domain: "test", code: 1)))
        }
    }

    private var defaults: UserDefaults!
    private var fake: FakeRestrictor!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "MenuBarHidingTests-\(UUID().uuidString)")
        fake = FakeRestrictor()
    }

    private func make() -> MenuBarHiding {
        MenuBarHiding(restrictor: fake, defaults: defaults, ownBundleIdentifier: "com.claudehud.app")
    }

    func testTurningOnAllowsOnlyClaudeHUDAndTheSystemItems() {
        let h = make()
        h.toggle()
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].bundles, ["com.claudehud.app"])
        XCTAssertEqual(fake.calls[0].system, Array(0..<64))
        XCTAssertFalse(h.isOn, "on only once macOS grants it")
        fake.grant()
        XCTAssertTrue(h.isOn)
        XCTAssertTrue(make().isRemembered)
    }

    func testTurningOffReleasesItAndIsRemembered() {
        let h = make()
        h.toggle(); let handle = fake.grant()
        h.toggle()
        XCTAssertFalse(h.isOn)
        XCTAssertEqual(handle.invalidated, 1)
        XCTAssertFalse(make().isRemembered)
    }

    func testALaunchRestoresWhatWasRemembered() {
        let first = make()
        first.toggle(); fake.grant()
        first.release()

        let next = make()
        next.restore()
        XCTAssertEqual(fake.calls.count, 2)
        fake.grant()
        XCTAssertTrue(next.isOn)
    }

    func testALaunchWithItOffAsksNothing() {
        make().restore()
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testQuitReleasesButKeepsTheSetting() {
        let h = make()
        h.toggle(); let handle = fake.grant()
        h.release()
        XCTAssertEqual(handle.invalidated, 1)
        XCTAssertFalse(h.isOn)
        XCTAssertTrue(make().isRemembered, "on again at the next launch")
    }

    func testARefusalLeavesTheBarAsItWas() {
        let h = make()
        h.toggle(); fake.refuse()
        XCTAssertFalse(h.isOn)
        XCTAssertFalse(make().isRemembered, "the checkmark and the setting agree")
        XCTAssertNotNil(h.lastError)
    }

    func testAGrantThatArrivesAfterTurningOffIsDroppedAtOnce() {
        let h = make()
        h.toggle()          // asked
        h.toggle()          // turned off before macOS answered
        let late = fake.grant()
        XCTAssertEqual(late.invalidated, 1)
        XCTAssertFalse(h.isOn)
        XCTAssertFalse(make().isRemembered)
    }

    func testARestartedMenuBarAgentTurnsTheCheckmarkOffAndAsksAgain() {
        let h = make()
        h.toggle(); let first = fake.grant()
        h.verify()
        XCTAssertTrue(h.isOn, "the same MenuBarAgent: still held")
        XCTAssertEqual(fake.calls.count, 1)

        fake.agent = 9001          // launchd started a new MenuBarAgent
        h.verify()
        XCTAssertFalse(h.isOn, "the bar shows everything until the new one grants it")
        XCTAssertEqual(first.invalidated, 1)
        XCTAssertEqual(fake.calls.count, 2)
        fake.grant()
        XCTAssertTrue(h.isOn)
        h.verify()
        XCTAssertEqual(fake.calls.count, 2, "held by the new one: nothing more to ask")
    }

    func testARestartWhileOffAsksNothing() {
        let h = make()
        h.toggle(); fake.grant(); h.toggle()
        fake.agent = 9001
        h.verify()
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertFalse(h.isOn)
    }

    func testTheNewAgentRefusingLeavesItOff() {
        let h = make()
        h.toggle(); fake.grant()
        fake.agent = nil           // MenuBarAgent gone, not yet back
        h.verify()
        fake.refuse()
        XCTAssertFalse(h.isOn)
        XCTAssertFalse(make().isRemembered, "the checkmark and the setting agree")
    }

    func testTheRealEnforcerIsMenuBarAgent() {
        // On macOS 27 MenuBarAgent always runs in a login session.
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return }
        XCTAssertNotNil(AssessmentModeRestrictor().enforcer())
    }

    func testWithoutTheFrameworkTheToggleDoesNothing() {
        fake.isAvailable = false
        let h = make()
        XCTAssertFalse(h.isAvailable)
        h.toggle()
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertFalse(h.isOn)
    }
}
