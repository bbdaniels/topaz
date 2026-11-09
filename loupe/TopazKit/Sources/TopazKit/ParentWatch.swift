import Foundation

/// A helper's watch on Topaz, the app that launches it from
/// `Topaz.app/Contents/Helpers` and passes its own pid as `TOPAZ_PID`
/// (Loupe and Topaz Launcher both use it). When that process exits, by a
/// quit or a crash, the helper exits too, so a helper never outlives Topaz. Topaz also sends SIGTERM when it quits; this
/// watch covers the cases where it cannot (a crash, a SIGKILL).
public enum ParentWatch {
    /// The pid in `TOPAZ_PID`, or nil when the helper was not launched by Topaz
    /// (the variable is missing, not a number, or names launchd or the kernel).
    public static func parentPid(_ environment: [String: String]) -> pid_t? {
        guard let text = environment["TOPAZ_PID"]?.trimmingCharacters(in: .whitespaces),
              let pid = pid_t(text), pid > 1 else { return nil }
        return pid
    }

    /// Calls `onExit` once, on `queue`, when process `pid` exits; at once if it
    /// has already exited. A dispatch process source is a kqueue
    /// `EVFILT_PROC` filter with `NOTE_EXIT`. Keep the returned source alive.
    public static func watch(_ pid: pid_t, queue: DispatchQueue = .main,
                      onExit: @escaping () -> Void) -> DispatchSourceProcess {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        var fired = false
        let fire = {
            guard !fired else { return }
            fired = true
            source.cancel()
            onExit()
        }
        source.setEventHandler(handler: fire)
        source.resume()
        // A process that exited before the source was armed raises no event.
        if kill(pid, 0) != 0 && errno == ESRCH {
            queue.async(execute: fire)
        }
        return source
    }
}
