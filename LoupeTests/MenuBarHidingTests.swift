import XCTest

/// MenuBarHiding: "Hide Other Menu Bar Items" holds macOS 27's menu bar
/// allow-list (MenuBarClientCore's assessment-mode assertion) while it is on,
/// letting only Loupe's items, Tot's and the system's show (Ben, 2026-11-08).
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

    /// Timers the test fires by hand.
    final class FakeTimers {
        final class Pending: MenuBarTimer {
            let after: TimeInterval
            let fire: @MainActor () -> Void
            var cancelled = false
            init(_ after: TimeInterval, _ fire: @escaping @MainActor () -> Void) { self.after = after; self.fire = fire }
            func cancel() { cancelled = true }
        }
        var all: [Pending] = []
        var live: [Pending] { all.filter { !$0.cancelled } }
        func schedule(_ after: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> MenuBarTimer {
            let p = Pending(after, fire); all.append(p); return p
        }
        /// Fires the oldest timer still live, as the run loop would.
        @MainActor func fireNext() {
            guard let p = live.first else { return }
            p.cancelled = true
            p.fire()
        }
    }

    private var defaults: UserDefaults!
    private var fake: FakeRestrictor!
    private var timers: FakeTimers!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "MenuBarHidingTests-\(UUID().uuidString)")
        fake = FakeRestrictor()
        timers = FakeTimers()
    }

    private func make() -> MenuBarHiding {
        MenuBarHiding(restrictor: fake, defaults: defaults, ownBundleIdentifier: "com.bbdaniels.topaz.loupe",
                      schedule: { [timers] in timers!.schedule($0, $1) })
    }

    func testTurningOnAllowsOnlyLoupeTotAndTheSystemItems() {
        let h = make()
        h.toggle()
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].bundles, ["com.bbdaniels.topaz.loupe", "com.iconfactory.Tot"])
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
        defaults.set(false, forKey: MenuBarHiding.defaultsKey)
        make().restore()
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testHidingIsOnByDefaultAtLaunch() {
        XCTAssertTrue(make().isRemembered)
        let h = make()
        h.restore()
        XCTAssertEqual(fake.calls.count, 1)
        fake.grant()
        XCTAssertTrue(h.isOn)
    }

    func testTheChevronRevealsForTenSecondsThenHidesAgain() {
        let h = make()
        h.restore(); let first = fake.grant()
        h.toggleReveal()
        XCTAssertTrue(h.isRevealed)
        XCTAssertFalse(h.isOn)
        XCTAssertEqual(first.invalidated, 1, "everything shows")
        XCTAssertEqual(timers.live.map(\.after), [10])
        timers.fireNext()
        XCTAssertFalse(h.isRevealed)
        XCTAssertEqual(fake.calls.count, 2, "asked again")
        fake.grant()
        XCTAssertTrue(h.isOn)
        XCTAssertTrue(make().isRemembered)
    }

    func testASecondPressHidesAtOnceAndCancelsTheTimer() {
        let h = make()
        h.restore(); fake.grant()
        h.toggleReveal()
        h.toggleReveal()
        XCTAssertFalse(h.isRevealed)
        XCTAssertTrue(timers.live.isEmpty)
        XCTAssertEqual(fake.calls.count, 2)
        fake.grant()
        XCTAssertTrue(h.isOn)
        timers.fireNext()
        XCTAssertEqual(fake.calls.count, 2, "the cancelled timer asks nothing")
    }

    func testRevealDoesNothingWhileHidingIsOff() {
        defaults.set(false, forKey: MenuBarHiding.defaultsKey)
        let h = make()
        h.toggleReveal()
        XCTAssertFalse(h.isRevealed)
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertTrue(timers.all.isEmpty)
    }

    func testTurningOffWhileRevealedStaysOff() {
        let h = make()
        h.restore(); fake.grant()
        h.toggleReveal()
        h.toggle()
        XCTAssertFalse(h.isRevealed)
        XCTAssertFalse(make().isRemembered)
        timers.fireNext()
        XCTAssertEqual(fake.calls.count, 1, "no hiding comes back")
    }

    func testQuitWhileRevealedKeepsTheSetting() {
        let h = make()
        h.restore(); fake.grant()
        h.toggleReveal()
        h.release()
        XCTAssertTrue(timers.live.isEmpty)
        XCTAssertTrue(make().isRemembered)
    }

    func testARestartCheckWhileRevealedAsksNothing() {
        let h = make()
        h.restore(); fake.grant()
        h.toggleReveal()
        fake.agent = 9001
        h.verify()
        XCTAssertEqual(fake.calls.count, 1)
    }

    func testChangesAreReported() {
        let h = make()
        var changes = 0
        h.onChange = { changes += 1 }
        h.restore(); fake.grant()
        h.toggleReveal()
        timers.fireNext()
        fake.grant()
        XCTAssertEqual(changes, 4, "granted, revealed, hiding again, granted")
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
        XCTAssertNotNil(h.lastError)
        XCTAssertTrue(make().isRemembered, "the next launch asks again")
        h.toggle()
        XCTAssertEqual(fake.calls.count, 2, "the menu item asks again")
        fake.grant()
        XCTAssertTrue(h.isOn)
        XCTAssertNil(h.lastError)
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
        XCTAssertNotNil(h.lastError)
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

// MARK: - The Objective-C call itself

/// Stand-ins for MBAssessmentModeConfiguration and MBAssessmentModeAssertion:
/// the same selectors, and, like MenuBarClientCore, the assertion keeps the
/// completion block and calls it after `activate` has returned. A block passed
/// as non-escaping traps here, as it did at launch on 2026-11-08.
final class StandInConfiguration: NSObject {
    @objc(initWithAllowedSystemItems:allowedBundleIdentifiers:)
    init(allowedSystemItems: NSArray, allowedBundleIdentifiers: NSArray) { super.init() }
}

final class StandInAssertion: NSObject {
    static var refuse = false
    private(set) static var invalidated = 0
    private var kept: ((NSError?) -> Void)?

    @objc(activateWithConfiguration:completionHandler:)
    func activate(configuration: AnyObject, completionHandler: @escaping (NSError?) -> Void) {
        kept = completionHandler
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            kept?(Self.refuse ? NSError(domain: "StandIn", code: 7) : nil)
            kept = nil
        }
    }

    @objc func invalidate() { Self.invalidated += 1 }
}

@MainActor
final class AssessmentModeRestrictorTests: XCTestCase {
    private func activate(refuse: Bool) -> Result<MenuBarRestriction, Error>? {
        StandInAssertion.refuse = refuse
        let restrictor = AssessmentModeRestrictor(configurationClass: StandInConfiguration.self,
                                                  assertionClass: StandInAssertion.self)
        XCTAssertTrue(restrictor.isAvailable)
        var result: Result<MenuBarRestriction, Error>?
        let answered = expectation(description: "answered")
        restrictor.activate(allowedSystemItems: Array(0..<64), allowedBundleIdentifiers: ["com.bbdaniels.topaz.loupe"]) {
            result = $0
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)
        return result
    }

    func testALaterAnswerFromTheFrameworkGrantsTheAllowList() throws {
        let before = StandInAssertion.invalidated
        let restriction = try XCTUnwrap(activate(refuse: false)).get()
        XCTAssertEqual(StandInAssertion.invalidated, before)
        restriction.invalidate()
        XCTAssertEqual(StandInAssertion.invalidated, before + 1)
    }

    func testALaterRefusalIsReportedAndTheAssertionDropped() {
        let before = StandInAssertion.invalidated
        guard case .failure? = activate(refuse: true) else { return XCTFail("expected a refusal") }
        XCTAssertEqual(StandInAssertion.invalidated, before + 1)
    }
}
