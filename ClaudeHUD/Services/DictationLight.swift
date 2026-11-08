import Foundation

/// The menu bar gem shows blue while Topaz's fn dictation is listening (Ben,
/// 2026-11-08): from the moment its speech to text socket is connected, so
/// that words are actually being heard, until fn is released or the session
/// ends however it ends. Topaz posts the distributed notification `name`
/// with userInfo `state` ("listening" or "stopped") and `pid` (its own), and
/// refreshes "listening" every second (wezterm-gui/src/dictation/light.rs).
///
/// A gem can never stay blue by mistake: without a refresh for `stale` it
/// goes back by itself, so a lost "stopped" costs at most three seconds; and
/// if Topaz dies, ParentWatch ends this app with it. Launched by Topaz, only
/// notifications carrying its TOPAZ_PID count, so another Topaz (a test
/// build) cannot light it.
///
/// This is the state alone, so that it can be tested; DictationWatch observes.
struct DictationLight {
    static let name = Notification.Name("com.bbdaniels.topaz.dictation")
    static let stale: TimeInterval = 3

    /// The Topaz whose notifications count; nil counts any.
    let topazPid: Int32?
    /// The last "listening", while no "stopped" has come since.
    private(set) var lastListening: Date?

    init(topazPid: Int32?) {
        self.topazPid = topazPid
    }

    mutating func receive(_ info: [AnyHashable: Any]?, at now: Date) {
        guard let state = info?["state"] as? String else { return }
        if let want = topazPid {
            let pid = (info?["pid"] as? String).flatMap { Int32($0) }
            guard pid == want else { return }
        }
        switch state {
        case "listening": lastListening = now
        case "stopped": lastListening = nil
        default: break
        }
    }

    func isLit(at now: Date) -> Bool {
        guard let at = lastListening else { return false }
        return now.timeIntervalSince(at) < Self.stale
    }

    /// When the gem goes back by itself unless a refresh comes first.
    var expires: Date? {
        lastListening?.addingTimeInterval(Self.stale)
    }
}

/// Observes Topaz's dictation notifications and reports each change of the
/// light to `onChange`, on the main thread.
@MainActor
final class DictationWatch: NSObject {
    private var light: DictationLight
    private let onChange: (Bool) -> Void
    private var lit = false
    private var expiry: Timer?

    init(topazPid: Int32?, onChange: @escaping (Bool) -> Void) {
        light = DictationLight(topazPid: topazPid)
        self.onChange = onChange
        super.init()
        // Delivered even while this app is inactive, which a menu bar app
        // nearly always is.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: DictationLight.name,
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func received(_ note: Notification) {
        light.receive(note.userInfo, at: Date())
        update()
    }

    private func update() {
        let now = Date()
        let on = light.isLit(at: now)
        if on != lit {
            lit = on
            onChange(on)
        }
        expiry?.invalidate()
        expiry = nil
        if on, let at = light.expires {
            expiry = Timer.scheduledTimer(
                withTimeInterval: max(0.05, at.timeIntervalSince(now)), repeats: false
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }
}
