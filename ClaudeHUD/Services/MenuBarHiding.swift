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
// Known costs of the mechanism, not of this code: while it is held the clock
// does not open Notification Center (assessment mode blocks it on purpose;
// dwarvesf/hidden issue 410), and a legacy menu extra with no system item
// number (Time Machine, Eject; issue 424) hides with the apps.

/// A held allow-list; hiding lasts until `invalidate()` or until this process exits.
protocol MenuBarRestriction: AnyObject {
    func invalidate()
}

protocol MenuBarRestricting: AnyObject {
    var isAvailable: Bool { get }
    /// Shows only these system items and apps. The completion runs on the main queue.
    func activate(allowedSystemItems: [Int], allowedBundleIdentifiers: [String],
                  completion: @escaping (Result<MenuBarRestriction, Error>) -> Void)
}

/// The toggle: what it asks of macOS, what it holds, and what it remembers.
@MainActor
final class MenuBarHiding {
    static let defaultsKey = "hideOtherMenuBarItems"
    /// MenuBarAgent's own items (clock, Wi-Fi, battery, Control Center...).
    /// Numbers a Mac does not have are ignored; Hidden Bar checked 0..<64 on 27.0.
    static let systemItems = Array(0..<64)

    private let restrictor: MenuBarRestricting
    private let defaults: UserDefaults
    private let ownBundleIdentifier: String

    private var held: MenuBarRestriction?
    /// Bumped by every request; a grant for an older one is invalidated on arrival.
    private var generation = 0
    private(set) var lastError: Error?

    init(restrictor: MenuBarRestricting = AssessmentModeRestrictor(),
         defaults: UserDefaults = .standard,
         ownBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.claudehud.app") {
        self.restrictor = restrictor
        self.defaults = defaults
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    var isAvailable: Bool { restrictor.isAvailable }
    /// Hiding now: macOS granted the allow-list and it is held.
    var isOn: Bool { held != nil }
    /// The setting a launch restores.
    var isRemembered: Bool { defaults.bool(forKey: Self.defaultsKey) }

    /// The menu item: on asks macOS for the allow-list, off releases it.
    func toggle() {
        if isOn || isRemembered {
            turnOff()
        } else {
            turnOn()
        }
    }

    /// At launch: hide again if it was on when ClaudeHUD last quit.
    func restore() {
        if isRemembered && !isOn { turnOn() }
    }

    /// At quit: release, keep the setting for the next launch.
    func release() {
        generation += 1
        held?.invalidate()
        held = nil
    }

    private func turnOn() {
        guard restrictor.isAvailable else { return }
        defaults.set(true, forKey: Self.defaultsKey)
        generation += 1
        let asked = generation
        restrictor.activate(allowedSystemItems: Self.systemItems,
                            allowedBundleIdentifiers: [ownBundleIdentifier]) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, asked == self.generation else {
                    if case .success(let stale) = result { stale.invalidate() }
                    return
                }
                switch result {
                case .success(let restriction):
                    self.held?.invalidate()
                    self.held = restriction
                    self.lastError = nil
                case .failure(let error):
                    // Fail open: the bar stays as it was and the checkmark agrees.
                    NSLog("MenuBarHiding: macOS refused the allow-list: \(error.localizedDescription)")
                    self.lastError = error
                    self.defaults.set(false, forKey: Self.defaultsKey)
                }
            }
        }
    }

    private func turnOff() {
        defaults.set(false, forKey: Self.defaultsKey)
        release()
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
    private typealias ActivateIMP = @convention(c) (AnyObject, Selector, AnyObject, @convention(block) (NSError?) -> Void) -> Void

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

    var isAvailable: Bool { Self.classes != nil }

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
        guard let classes = Self.classes,
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
