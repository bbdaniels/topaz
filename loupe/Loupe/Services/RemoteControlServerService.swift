import Foundation
import os

private let logger = Logger(subsystem: "com.bbdaniels.topaz.loupe", category: "RemoteControlServer")

/// Owns the persistent `claude remote-control` server that lets claude.ai/code
/// and the Claude app start new sessions on this Mac (the counterpart of the
/// Pi's `claude-rc.service`).
///
/// launchd runs the server, not the HUD: a user agent with `KeepAlive`, so it
/// survives the HUD quitting and restarts itself if it dies. The HUD writes,
/// loads, unloads and observes it. Enabled means the plist exists in
/// `~/Library/LaunchAgents`, so the state after a reboot is the state the
/// toggle shows: launchd loads the plist at login, and disabling deletes it.
///
/// The server's `--permission-mode` follows the global permission mode
/// (`LaunchPermissionMode`, chosen in the info popover); when it changes, the plist is
/// rewritten and the agent reloaded so the server matches.
///
/// The sessions the server runs are its child processes, so a reload or
/// turning it off ends every one of them (Ben, 2026-11-08). Such a change
/// therefore waits while the server has a live session (`RemoteControlReload`),
/// is applied by the poll once the last one ends, and the info popover says so.
@MainActor
final class RemoteControlServerService: ObservableObject {
    /// True when the plist is installed (launchd loads it at login).
    @Published private(set) var isEnabled = false
    /// The server's pid while launchd reports it running.
    @Published private(set) var pid: Int?
    /// A load, unload or reload is in flight.
    @Published private(set) var isBusy = false
    /// The sessions the running server has open.
    @Published private(set) var liveSessions = 0
    /// A reload or turn-off waiting for those sessions to end.
    @Published private(set) var waiting: RemoteControlChange?

    /// The info popover's status line, which says when a change waits for
    /// sessions.
    var status: String {
        RemoteControlReload.status(isBusy: isBusy, pid: pid, isEnabled: isEnabled,
                                   serverName: Self.serverName, liveSessions: liveSessions,
                                   waiting: waiting)
    }
    /// What the toggle shows: off as soon as a turn-off is asked for.
    var isOn: Bool { isEnabled && waiting != .turnOff }
    /// A check for live sessions is in flight (not shown as busy).
    private var isChecking = false

    nonisolated static let label = "com.bbdaniels.claude-remote-control"
    nonisolated static let serverName = "Mac"
    nonisolated static let capacity = 8
    /// Matches the Pi's RestartSec: a crash-looping server retries every 30 s.
    nonisolated static let throttleInterval = 30

    nonisolated static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    nonisolated static var logPath: String {
        "\(NSHomeDirectory())/Library/Logs/claude-remote-control.log"
    }
    nonisolated private static var serviceTarget: String { "gui/\(getuid())/\(label)" }
    nonisolated private static var domainTarget: String { "gui/\(getuid())" }

    private var timer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private static let pollInterval: TimeInterval = 15

    deinit {
        timer?.invalidate()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    func start() {
        // The picker writes through @AppStorage, which posts this on every
        // UserDefaults write; `syncWithPermissionMode` is a no-op unless the
        // installed plist no longer matches the definition.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncWithPermissionMode() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Also catches a plist written by an older HUD build.
        syncWithPermissionMode()
        refresh()
    }

    // MARK: - Definition

    /// The launchd job, generated from the current global permission mode.
    nonisolated static func plist(mode: LaunchPermissionMode = .current) -> [String: Any] {
        let home = NSHomeDirectory()
        var args = ["\(home)/.local/bin/claude", "remote-control",
                    "--name", serverName, "--capacity", String(capacity)]
        args += mode.remoteControlArguments
        return [
            "Label": label,
            "ProgramArguments": args,
            "WorkingDirectory": "\(home)/Projects",
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": throttleInterval,
            "EnvironmentVariables": [
                "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            ],
            // Standard output is the server's status screen, redrawn
            // continuously (about 34 MB a day); only errors are kept.
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": logPath,
        ]
    }

    nonisolated private static func writePlist() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist(), format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    nonisolated private static func installedPlistIsCurrent() -> Bool {
        guard let installed = NSDictionary(contentsOf: plistURL) else { return false }
        return installed.isEqual(to: plist())
    }

    // MARK: - Actions

    /// The toggle. Turning on again while a turn-off waits only cancels it.
    func setEnabled(_ enabled: Bool) {
        guard !isBusy else { return }
        if !enabled {
            request(.turnOff)
            return
        }
        if waiting == .turnOff {
            waiting = RemoteControlReload.turnedBackOn(
                pending: waiting, definitionIsCurrent: Self.installedPlistIsCurrent())
            applyWaiting()
            return
        }
        request(.reload)
    }

    /// Rewrite and reload when the installed plist differs from the one the
    /// current permission mode generates. Never enables a disabled server.
    /// A change already waiting is applied from the definition current then.
    func syncWithPermissionMode() {
        guard !isBusy, waiting == nil,
              FileManager.default.fileExists(atPath: Self.plistURL.path),
              !Self.installedPlistIsCurrent() else { return }
        logger.info("Permission mode changed; reloading the Remote Control server")
        request(.reload)
    }

    private func request(_ change: RemoteControlChange) {
        waiting = RemoteControlReload.merge(change, into: waiting)
        applyWaiting()
    }

    /// Apply the waiting change unless the server still has live sessions;
    /// the poll calls this again until it applies.
    private func applyWaiting() {
        guard let change = waiting, !isBusy, !isChecking else { return }
        isChecking = true
        Task {
            let seen = await Task.detached { Self.observe() }.value
            isChecking = false
            liveSessions = seen.live
            guard waiting == change else {
                applyWaiting()
                return
            }
            if RemoteControlReload.mustWait(serverRunning: seen.pid != nil, liveSessions: seen.live) {
                logger.info("Remote Control \(String(describing: change), privacy: .public) waits for \(seen.live) sessions")
                return
            }
            isBusy = true
            let outcome = await Task.detached { Self.apply(change) }.value
            isBusy = false
            switch outcome {
            case .applied: if waiting == change { waiting = nil }
            case .waits(let live): liveSessions = live
            case .failed(let error):
                logger.error("\(error, privacy: .public)")
                if waiting == change { waiting = nil }
            }
            refresh()
            // A picker change that arrived mid-reload was skipped; catch it.
            syncWithPermissionMode()
        }
    }

    func refresh() {
        Task {
            let seen = await Task.detached { Self.observe() }.value
            isEnabled = seen.enabled
            pid = seen.pid
            liveSessions = seen.live
            if waiting != nil { applyWaiting() }
        }
    }

    /// `Loupe --remote-control on|off|status`. Returns the exit status.
    nonisolated static func commandLine(_ verb: String) -> Int32 {
        var error: String?
        switch verb {
        case "on", "off":
            // No poll here to wait with: refuse, and say why.
            switch apply(verb == "on" ? .reload : .turnOff) {
            case .applied: break
            case .failed(let message): error = message
            case .waits(let live):
                error = "Remote Control has \(live) live session\(live == 1 ? "" : "s"), which "
                    + (verb == "on" ? "restarting it" : "turning it off")
                    + " would end; nothing was changed. Run this again when they end."
            }
        case "status": break
        default: error = "Usage: Loupe --remote-control on|off|status"
        }
        if let error { FileHandle.standardError.write(Data((error + "\n").utf8)) }
        let (enabled, pid, live) = observe()
        let state = pid.map { "running (pid \($0))" + (live == 0 ? "" : ", \(live) live sessions") }
            ?? (enabled ? "enabled, not running" : "off")
        print("Remote Control: \(state)")
        return error == nil ? 0 : 1
    }

    // MARK: - launchctl (off the main thread)

    /// Apply `change` unless the server has live sessions, counted again here
    /// right before the bootout. A reload of a running server whose installed
    /// plist is already current is nothing to do.
    nonisolated static func apply(_ change: RemoteControlChange) -> RemoteControlOutcome {
        let (_, pid, live) = observe()
        if change == .reload, pid != nil, installedPlistIsCurrent() { return .applied }
        if RemoteControlReload.mustWait(serverRunning: pid != nil, liveSessions: live) { return .waits(live) }
        let error = change == .reload ? load() : unload()
        return error.map(RemoteControlOutcome.failed) ?? .applied
    }

    /// (plist installed, the server's pid while running, its live sessions).
    nonisolated private static func observe() -> (enabled: Bool, pid: Int?, live: Int) {
        let (enabled, pid) = query()
        guard pid != nil else { return (enabled, nil, 0) }
        return (enabled, pid, RemoteControlReload.liveSessions(
            serverPid: pid, table: ClaudeProcessSnapshot.processTable()))
    }

    /// Write the plist and (re)bootstrap it. launchd caches a job's
    /// definition at bootstrap, so a changed plist needs a bootout first;
    /// bootstrap fails while the old job is still tearing down, so wait for
    /// it to leave the domain. Returns an error message, or nil.
    nonisolated private static func load() -> String? {
        do { try writePlist() } catch { return "Writing \(plistURL.path) failed: \(error)" }
        if isLoaded() {
            _ = launchctl(["bootout", serviceTarget])
            var waited = 0
            while isLoaded() && waited < 40 { usleep(250_000); waited += 1 }
        }
        let (status, output) = launchctl(["bootstrap", domainTarget, plistURL.path])
        return status == 0 ? nil : "launchctl bootstrap failed (\(status)): \(output)"
    }

    /// Bootout, then delete the plist so the server stays off after login.
    nonisolated private static func unload() -> String? {
        if isLoaded() { _ = launchctl(["bootout", serviceTarget]) }
        do {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        } catch { return "Removing \(plistURL.path) failed: \(error)" }
        return nil
    }

    nonisolated private static func isLoaded() -> Bool {
        launchctl(["print", serviceTarget]).status == 0
    }

    /// (plist installed, pid when launchd reports the job running).
    nonisolated private static func query() -> (Bool, Int?) {
        let enabled = FileManager.default.fileExists(atPath: plistURL.path)
        let (status, output) = launchctl(["print", serviceTarget])
        guard status == 0, output.contains("state = running") else { return (enabled, nil) }
        let pid = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("pid = ") }
            .flatMap { Int($0.dropFirst("pid = ".count)) }
        return (enabled, pid)
    }

    nonisolated private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
