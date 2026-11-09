import Foundation

// "Hide Other Menu Bar Items" (Ben, 2026-11-08).
//
// On macOS 27 one system process, MenuBarAgent, draws every status item, and
// the old managers' tricks (a wide spacer that pushes icons off screen,
// reading the window list) no longer work. What does work for an unsandboxed
// app is the menu bar allow-list behind exam "assessment mode", in the private
// MenuBarClientCore framework: while an MBAssessmentModeAssertion is held,
// only the listed apps' items and the listed system items show. Hidden Bar
// 1.11.1 and Thaw 3 hide this way; a sandboxed app is refused.
//
// Measured on the Mac (27.2, 2026-11-08): allowing only com.claudehud.app and
// system items 0..<64 hid every other app's item and kept ClaudeHUD's, Wi-Fi,
// battery, Control Center and the clock; invalidating brought them all back,
// and so did killing the holder with SIGKILL, so a crash cannot leave the bar
// hidden. Item order (Cmd-drag) is never touched: macOS keeps it in
// com.apple.MenuBar.plist and nothing here writes it.
//
// Since 2026-11-08 the allow-list also keeps Tot, hiding is on by default,
// and a chevron next to the gem (or Ctrl+Opt+Cmd+B) releases it for ten
// seconds to show everything.
//
// Known costs of the mechanism, not of this code: while it is held the clock
// does not open Notification Center (assessment mode blocks it on purpose;
// dwarvesf/hidden issue 410), and a legacy menu extra with no system item
// number (Time Machine, Eject; issue 424) hides with the apps.
//
// The assertion gives no word when it stops working: MBAssessmentModeAssertion
// has only init, activate and invalidate (its methods listed on the Mac, 27.2,
// 2026-11-08), no handler and no state to read. What ends it from outside is
// MenuBarAgent ending, since that process holds the allow-list, and launchd
// starts a new one that knows nothing of it. So while it is held the toggle
// checks every few seconds that the MenuBarAgent it was granted by is still
// the one running, and when it is not, asks the new one; until that answers,
// the checkmark is off, as the bar is.

/// A held allow-list; hiding lasts until `invalidate()` or until this process exits.
protocol MenuBarRestriction: AnyObject {
    func invalidate()
}

protocol MenuBarRestricting: AnyObject {
    var isAvailable: Bool { get }
    /// Shows only these system items and apps. The completion runs on the main queue.
    func activate(allowedSystemItems: [Int], allowedBundleIdentifiers: [String],
                  completion: @escaping (Result<MenuBarRestriction, Error>) -> Void)
    /// The process that keeps the allow-list (MenuBarAgent's pid), or nil if none runs.
    func enforcer() -> Int32?
}

/// A pending call to come back later; `cancel()` stops it.
protocol MenuBarTimer: AnyObject {
    func cancel()
}

/// The toggle: what it asks of macOS, what it holds, and what it remembers.
///
/// Bartender style (Ben, 2026-11-08: "We really don't need anything aside from
/// the gem, the tot, the Wi-Fi, the battery"): hiding is on unless Ben turns it
/// off, and the allow-list is Loupe's own items (the gem and the chevron), Tot
/// and the system items. The chevron or Ctrl+Opt+Cmd+B reveals everything for
/// `revealFor` seconds, or until pressed again, by releasing the allow-list;
/// then it is asked for again.
@MainActor
final class MenuBarHiding {
    static let defaultsKey = "hideOtherMenuBarItems"
    /// MenuBarAgent's own items (clock, Wi-Fi, battery, Control Center...).
    /// Numbers a Mac does not have are ignored; Hidden Bar checked 0..<64 on 27.0.
    static let systemItems = Array(0..<64)
    /// Other apps whose items stay: Tot.
    static let otherApps = ["com.iconfactory.Tot"]
    /// How long a reveal lasts.
    static let revealFor: TimeInterval = 10

    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> MenuBarTimer

    private let restrictor: MenuBarRestricting
    private let defaults: UserDefaults
    private let ownBundleIdentifier: String
    private let schedule: Schedule

    private var held: MenuBarRestriction?
    /// The enforcer that granted `held`; another one means the grant is gone.
    private var heldBy: Int32?
    private var watch: Timer?
    static let checkEvery: TimeInterval = 5
    /// Bumped by every request; a grant for an older one is invalidated on arrival.
    private var generation = 0
    /// A request macOS has not answered yet.
    private var asking = false
    private var revealTimer: MenuBarTimer?
    private(set) var lastError: Error?
    /// Called whenever hidden, revealed or off changes, for the chevron.
    var onChange: (() -> Void)?

    init(restrictor: MenuBarRestricting = AssessmentModeRestrictor(),
         defaults: UserDefaults = .standard,
         ownBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.claudehud.app",
         schedule: @escaping Schedule = MenuBarHiding.runLoopTimer) {
        self.restrictor = restrictor
        self.defaults = defaults
        self.ownBundleIdentifier = ownBundleIdentifier
        self.schedule = schedule
    }

    var isAvailable: Bool { restrictor.isAvailable }
    /// Hiding now: macOS granted the allow-list and it is held.
    var isOn: Bool { held != nil }
    /// Everything shows for a while, and hides again after.
    private(set) var isRevealed = false
    /// The setting a launch restores: on unless Ben turned it off.
    var isRemembered: Bool { defaults.object(forKey: Self.defaultsKey) as? Bool ?? true }

    /// The menu item: on asks macOS for the allow-list, off releases it.
    func toggle() {
        if isOn || isRevealed || asking {
            turnOff()
        } else {
            turnOn()
        }
    }

    /// The chevron and the shortcut: reveal everything, or hide it again.
    /// Nothing happens while hiding is off.
    func toggleReveal() {
        if isRevealed {
            hideAgain()
        } else if isOn {
            generation += 1
            drop()
            isRevealed = true
            revealTimer = schedule(Self.revealFor) { [weak self] in self?.hideAgain() }
            onChange?()
        }
    }

    /// At launch: hide, unless Ben turned it off.
    func restore() {
        if isRemembered && !isOn && !asking { turnOn() }
    }

    /// At quit: release, keep the setting for the next launch.
    func release() {
        generation += 1
        asking = false
        endReveal()
        drop()
        onChange?()
    }

    /// While held: if the MenuBarAgent that granted it has ended, the bar
    /// shows everything again, so let the checkmark say so and ask again.
    func verify() {
        guard held != nil, restrictor.enforcer() != heldBy else { return }
        NSLog("MenuBarHiding: MenuBarAgent restarted, so its allow-list is gone; asking again")
        drop()
        onChange?()
        if isRemembered { turnOn() }
    }

    private func hideAgain() {
        guard isRevealed else { return }
        endReveal()
        onChange?()
        if isRemembered { turnOn() }
    }

    private func endReveal() {
        revealTimer?.cancel()
        revealTimer = nil
        isRevealed = false
    }

    private func drop() {
        watch?.invalidate()
        watch = nil
        held?.invalidate()
        held = nil
        heldBy = nil
    }

    private func turnOn() {
        guard restrictor.isAvailable else { return }
        defaults.set(true, forKey: Self.defaultsKey)
        generation += 1
        asking = true
        let asked = generation
        restrictor.activate(allowedSystemItems: Self.systemItems,
                            allowedBundleIdentifiers: [ownBundleIdentifier] + Self.otherApps) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, asked == self.generation else {
                    if case .success(let stale) = result { stale.invalidate() }
                    return
                }
                self.asking = false
                switch result {
                case .success(let restriction):
                    self.held?.invalidate()
                    self.held = restriction
                    self.heldBy = self.restrictor.enforcer()
                    self.lastError = nil
                    if self.watch == nil {
                        let t = Timer(timeInterval: Self.checkEvery, repeats: true) { [weak self] _ in
                            MainActor.assumeIsolated { self?.verify() }
                        }
                        t.tolerance = 1
                        RunLoop.main.add(t, forMode: .common)
                        self.watch = t
                    }
                case .failure(let error):
                    // Fail open: the bar stays as it was and the checkmark agrees.
                    // The setting stays, so the menu item or the next launch asks again.
                    NSLog("MenuBarHiding: macOS refused the allow-list: \(error.localizedDescription)")
                    self.lastError = error
                }
                self.onChange?()
            }
        }
    }

    private func turnOff() {
        defaults.set(false, forKey: Self.defaultsKey)
        release()
    }

    /// The real timer: a one-shot Timer on the main run loop.
    static func runLoopTimer(_ after: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> MenuBarTimer {
        let timer = Timer(timeInterval: after, repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return RunLoopTimer(timer)
    }

    private final class RunLoopTimer: MenuBarTimer {
        private let timer: Timer
        init(_ timer: Timer) { self.timer = timer }
        func cancel() { timer.invalidate() }
    }
}

/// MenuBarClientCore, resolved at run time so a macOS that moves or drops it
/// reads as unavailable rather than failing to launch.
final class AssessmentModeRestrictor: MenuBarRestricting {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    private static let configure = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    private static let activateSelector = NSSelectorFromString("activateWithConfiguration:completionHandler:")
    private static let invalidateSelector = NSSelectorFromString("invalidate")

    private typealias ConfigureIMP = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject?
    private typealias ActivateIMP = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (NSError?) -> Void) -> Void

    private static let classes: (configuration: NSObject.Type, assertion: NSObject.Type)? = {
        guard dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL) != nil,
              let configuration = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
              let assertion = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
              configuration.instancesRespond(to: configure),
              assertion.instancesRespond(to: activateSelector),
              assertion.instancesRespond(to: invalidateSelector)
        else { return nil }
        return (configuration, assertion)
    }()

    /// The framework's classes, or stand-ins with the same selectors (tests).
    private let classes: (configuration: NSObject.Type, assertion: NSObject.Type)?

    init() { classes = Self.classes }

    /// For tests: drives `activate` through the same Objective-C calls,
    /// against stand-in classes that answer as MenuBarClientCore does.
    init(configurationClass: NSObject.Type, assertionClass: NSObject.Type) {
        classes = (configurationClass, assertionClass)
    }

    var isAvailable: Bool { classes != nil }

    /// MenuBarAgent's pid, by process name (libproc, so no AppKit here).
    func enforcer() -> Int32? {
        var pids = [Int32](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            if proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "MenuBarAgent" { return pid }
        }
        return nil
    }

    private final class Handle: MenuBarRestriction {
        private var assertion: NSObject?
        init(_ assertion: NSObject) { self.assertion = assertion }
        func invalidate() {
            guard let a = assertion else { return }
            assertion = nil
            _ = a.perform(AssessmentModeRestrictor.invalidateSelector)
        }
        deinit { invalidate() }
    }

    func activate(allowedSystemItems: [Int], allowedBundleIdentifiers: [String],
                  completion: @escaping (Result<MenuBarRestriction, Error>) -> Void) {
        func finish(_ r: Result<MenuBarRestriction, Error>) {
            DispatchQueue.main.async { completion(r) }
        }
        guard let classes,
              let allocated = (classes.configuration as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let configureIMP = classes.configuration.instanceMethod(for: Self.configure),
              let activateIMP = classes.assertion.instanceMethod(for: Self.activateSelector)
        else {
            return finish(.failure(Self.error("MenuBarClientCore is not available on this macOS")))
        }
        // Both lists must be arrays: the framework indexes into them.
        guard let configuration = unsafeBitCast(configureIMP, to: ConfigureIMP.self)(
            allocated, Self.configure,
            allowedSystemItems.map { NSNumber(value: $0) } as NSArray,
            allowedBundleIdentifiers as NSArray)
        else {
            return finish(.failure(Self.error("Could not make the allow-list configuration")))
        }
        let assertion = classes.assertion.init()
        // macOS answers in 100 to 150 ms; one that never answers is treated as a refusal.
        let once = Once()
        unsafeBitCast(activateIMP, to: ActivateIMP.self)(assertion, Self.activateSelector, configuration) { error in
            guard once.claim() else { return }
            if let error {
                _ = assertion.perform(Self.invalidateSelector)
                finish(.failure(error))
            } else {
                finish(.success(Handle(assertion)))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard once.claim() else { return }
            _ = assertion.perform(Self.invalidateSelector)
            completion(.failure(Self.error("macOS did not answer within 3 seconds")))
        }
    }

    /// The first of the answer and the timeout wins; the other is ignored.
    private final class Once {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    private static func error(_ reason: String) -> NSError {
        NSError(domain: "MenuBarHiding", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }
}
