import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.bbdaniels.topaz.loupe", category: "WezTerm")

/// THE terminal Loupe opens sessions in (Ben, 2026-11-07): Topaz, Ben's
/// build of WezTerm (renamed 2026-11-08; binaries and `wezterm cli` keep the
/// WezTerm names), one
/// window, one tab per session. Before this, Ghostty (and a picker of other
/// terminals) opened a window per project and was steered over AppleScript.
///
/// Everything goes through WezTerm's own command line (`wezterm cli`), which
/// reaches the running GUI over its socket: `list` the panes, `spawn` a tab,
/// `set-tab-title`, `activate-tab`. WezTerm comes to the front through
/// NSWorkspace, never AppleScript, so Loupe needs neither Apple Events nor
/// Accessibility for it.
///
/// The WezTerm config (bbdaniels/personal, `deploy/mac/wezterm/wezterm.lua`)
/// is the one opener of an iMac session's tab, titled with its tmux session
/// name, `rc-<name>`: every few seconds it opens one for each live iMac
/// session that never had one, and Loupe asks it for a tab by
/// `openIMac`, never spawning one itself (2026-11-08: both opened one for a
/// new session, so it got two). A session on this Mac gets `<project> (Mac)`,
/// is spawned here, and is found again by the terminal of its
/// `claude attach` process, which is the tab's own.
///
/// The parsing, matching and argument building are pure and unit tested;
/// `open`, `panes` and `activateApp` run them.
enum WezTerm {
    static let appPath = "/Applications/Topaz.app"
    static let cliPath = appPath + "/Contents/MacOS/wezterm"
    static let bundleIdentifier = "com.bbdaniels.topaz"

    /// One row of `wezterm cli list --format json`: a pane, its tab and window.
    struct Pane: Equatable, Decodable {
        let windowId: Int
        let tabId: Int
        let paneId: Int
        let tabTitle: String
        /// As WezTerm reports it, "/dev/ttys003".
        let ttyName: String?

        enum CodingKeys: String, CodingKey {
            case windowId = "window_id", tabId = "tab_id", paneId = "pane_id"
            case tabTitle = "tab_title", ttyName = "tty_name"
        }

        /// The tty as ps prints it, "ttys003".
        var psTTY: String? { ttyName.map(WezTerm.psTTY) }
    }

    // MARK: Pure

    /// The panes in `wezterm cli list --format json`; nil when it is not that.
    static func parsePanes(_ data: Data) -> [Pane]? {
        try? JSONDecoder().decode([Pane].self, from: data)
    }

    /// "/dev/ttys003" as ps prints it: "ttys003".
    static func psTTY(_ ttyName: String) -> String {
        ttyName.hasPrefix("/dev/") ? String(ttyName.dropFirst(5)) : ttyName
    }

    /// The line Loupe writes to `openRequestFile` to ask the config for
    /// an iMac session's tab: the session, a tab, the time in milliseconds
    /// (a new request even for the same session), a newline. Nil unless
    /// `session` is a gate session, `rc-` and pi-gate's NAME
    /// (`[a-z0-9][a-z0-9-]{0,39}`), since the config hands it to ssh.
    static func openRequest(session: String, at: Date) -> String? {
        guard session.hasPrefix("rc-") else { return nil }
        let name = session.dropFirst(3)
        guard (1...IMacLauncher.maxName).contains(name.count), name.first != "-",
              name.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
        else { return nil }
        return "\(session)\t\(Int((at.timeIntervalSince1970 * 1000).rounded()))\n"
    }

    /// The title of a tab for a session on this Mac.
    static func macTabTitle(project: String) -> String {
        "\(project.isEmpty ? "Claude" : project) (Mac)"
    }

    /// The tab each attached session is in, by its attach key
    /// (`AgentsService.attachKey`): an iMac session by its tab's title, its
    /// tmux session name; a Mac session by the terminal of its
    /// `claude attach <short>` process (`attachClients`, short and ps tty).
    static func attaches(panes: [Pane], attachClients: [(short: String, tty: String)],
                         iMacKey: (String) -> String) -> [String: Pane] {
        var out: [String: Pane] = [:]
        for p in panes where p.tabTitle.hasPrefix("rc-") {
            let key = iMacKey(p.tabTitle)
            if out[key] == nil { out[key] = p }
        }
        var byTTY: [String: Pane] = [:]
        for p in panes { if let t = p.psTTY, byTTY[t] == nil { byTTY[t] = p } }
        for c in attachClients where out[c.short] == nil {
            if let p = byTTY[c.tty] { out[c.short] = p }
        }
        return out
    }

    /// What opening a session does: focus the tab it is already in, else
    /// spawn one, into the window WezTerm has (a new window when it has none).
    enum Step: Equatable {
        case focus(tabId: Int)
        case spawn(windowId: Int?)
    }

    static func plan(existing: Pane?, panes: [Pane]) -> Step {
        if let existing { return .focus(tabId: existing.tabId) }
        return .spawn(windowId: panes.first?.windowId)
    }

    /// Every call passes `--no-auto-start`, so a call made while WezTerm is
    /// not running fails instead of starting a server without a window.
    static func listArgs() -> [String] {
        ["cli", "--no-auto-start", "list", "--format", "json"]
    }

    static func spawnArgs(argv: [String], cwd: String?, windowId: Int?) -> [String] {
        var args = ["cli", "--no-auto-start", "spawn"]
        if let windowId { args += ["--window-id", String(windowId)] } else { args.append("--new-window") }
        if let cwd { args += ["--cwd", cwd] }
        return args + ["--"] + argv
    }

    static func setTabTitleArgs(paneId: Int, title: String) -> [String] {
        ["cli", "--no-auto-start", "set-tab-title", "--pane-id", String(paneId), title]
    }

    /// The environment the command line runs in: Loupe's own, without
    /// `WEZTERM_UNIX_SOCKET` and `WEZTERM_PANE`. Loupe relaunched from a
    /// shell in a WezTerm tab inherits that GUI's socket; once the GUI quits,
    /// every call went to the dead socket, so Loupe saw no panes, lit
    /// every session grey and opened no tab (2026-11-08). Without them the
    /// command line finds the running GUI itself.
    static func cliEnvironment(_ env: [String: String]) -> [String: String] {
        env.filter { $0.key != "WEZTERM_UNIX_SOCKET" && $0.key != "WEZTERM_PANE" }
    }

    static func activateTabArgs(tabId: Int) -> [String] {
        ["cli", "--no-auto-start", "activate-tab", "--tab-id", String(tabId)]
    }

    /// Paste text into a pane (the inline editor's Send): the text comes on
    /// stdin, which `send-text` reads when given no text argument, and goes
    /// as a bracketed paste, its default, so a shell or Claude's prompt
    /// takes it as one paste and runs nothing. No `--no-paste`, no newline.
    static func sendTextArgs(paneId: Int) -> [String] {
        ["cli", "--no-auto-start", "send-text", "--pane-id", String(paneId)]
    }

    static func activatePaneArgs(paneId: Int) -> [String] {
        ["cli", "--no-auto-start", "activate-pane", "--pane-id", String(paneId)]
    }

    /// The argv of a tab running `command` in a login zsh, as any shell
    /// window would (PATH entries such as ~/.local/bin, which holds `claude`,
    /// live in ~/.zprofile), outside any Claude session's environment.
    static func shellArgv(_ command: String) -> [String] {
        ["/bin/zsh", "-l", "-c", "source ~/.zshrc 2>/dev/null; unset CLAUDECODE; " + command]
    }

    /// One tab's dot as Loupe lights it: the WezTerm pane, its tab's
    /// title, the session's `SessionLight` and working directory.
    struct TabLight: Equatable {
        let paneId: Int
        let tabTitle: String
        let light: SessionLight
        let cwd: String
    }

    /// The lights file the WezTerm config reads (bbdaniels/personal
    /// `deploy/mac/wezterm/sessions.py`), so a tab's dot is the HUD's own
    /// light for its session, from the one rule (`SessionLight.of`), on the
    /// Mac and the iMac alike. `at` lets the reader tell a file the HUD
    /// stopped writing from a current one.
    static func lightsJSON(_ tabs: [TabLight], at: Date) -> Data {
        let rows: [[String: Any]] = tabs.sorted { $0.paneId < $1.paneId }.map {
            ["pane": $0.paneId, "tab": $0.tabTitle, "light": $0.light.name, "cwd": $0.cwd]
        }
        let obj: [String: Any] = ["at": Int(at.timeIntervalSince1970), "tabs": rows]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    static var lightsFile: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/Loupe/wezterm-lights.json")
    }

    @MainActor private static var lastLights: (tabs: [TabLight], at: Date)?

    /// Write the lights when they change, and at least every 30 seconds so
    /// the reader can trust the file's age.
    @MainActor
    static func publishLights(_ tabs: [TabLight], now: Date = Date()) {
        let sorted = tabs.sorted { $0.paneId < $1.paneId }
        if let last = lastLights, last.tabs == sorted, now.timeIntervalSince(last.at) < 30 { return }
        let url = lightsFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try lightsJSON(sorted, at: now).write(to: url, options: .atomic)
            lastLights = (sorted, now)
        } catch {
            logger.error("WezTerm lights not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Running it

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: cliPath) }

    /// Run the command line; its output when it exits 0, else nil.
    @discardableResult
    static func run(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cliPath)
        p.arguments = args
        p.environment = cliEnvironment(ProcessInfo.processInfo.environment)
        let out = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    /// Run the command line with `input` on stdin; nil when it exits 0, else
    /// what went wrong, its standard error when it wrote one.
    static func run(_ args: [String], input: Data) -> String? {
        guard isInstalled else { return "Topaz is not installed at \(appPath)." }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cliPath)
        p.arguments = args
        p.environment = cliEnvironment(ProcessInfo.processInfo.environment)
        let stdin = Pipe()
        // A write to a command line that already exited fails with EPIPE
        // instead of raising SIGPIPE, which would end Loupe.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let err = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        do { try p.run() } catch { return "wezterm did not start: \(error.localizedDescription)" }
        // Standard error is read on its own thread while stdin is written, so
        // a command line that writes much before reading cannot block both.
        var errData = Data()
        let reader = DispatchQueue.global(qos: .userInitiated)
        let done = DispatchSemaphore(value: 0)
        reader.async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        } catch {
            try? stdin.fileHandleForWriting.close()
        }
        done.wait()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "wezterm exited with status \(p.terminationStatus)." : message
    }

    /// Paste `text` into pane `paneId` and make that pane the active one in
    /// its tab and window; nil when the paste went, else why it did not.
    /// Blocks while the command line runs, so it is called off the main
    /// thread. Bringing Topaz forward is the caller's (`activateApp`).
    static func sendText(_ text: String, paneId: Int) -> String? {
        if let error = run(sendTextArgs(paneId: paneId), input: Data(text.utf8)) { return error }
        if run(activatePaneArgs(paneId: paneId)) == nil {
            logger.error("WezTerm did not activate pane \(paneId)")
        }
        return nil
    }

    /// The panes WezTerm has; nil when it is not running (or not installed).
    static func panes() -> [Pane]? {
        guard isInstalled, let data = run(listArgs()) else { return nil }
        return parsePanes(data)
    }

    /// Read by the config every half second (`take_request` there).
    static var openRequestFile: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/Loupe/wezterm-open.txt")
    }

    /// Put Ben in an iMac session's tab: ask the config to focus it, or open
    /// it when there is none, and bring Topaz forward (launching it, whose
    /// startup then reads the request). False when Topaz is not installed or
    /// `session` is not a gate session.
    @MainActor
    @discardableResult
    static func openIMac(session: String) -> Bool {
        guard isInstalled, let line = openRequest(session: session, at: Date()) else { return false }
        let url = openRequestFile
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(line.utf8).write(to: url, options: .atomic)
        } catch {
            logger.error("Topaz open request not written: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return activateApp()
    }

    /// Bring WezTerm to the front, launching it when it is not running (its
    /// `gui-startup` then opens a tab for every live iMac session).
    @MainActor
    @discardableResult
    static func activateApp() -> Bool {
        guard isInstalled else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: config) { _, error in
            if let error { logger.error("WezTerm did not open: \(error.localizedDescription, privacy: .public)") }
        }
        return true
    }

    /// Open a Mac session's tab and bring WezTerm forward: focus the tab
    /// `find` picks from the panes (scanned now, off the main thread), else
    /// spawn `argv` in `cwd` as a new tab titled `title`. When WezTerm is not
    /// running it is launched first. An iMac session's tab is the config's
    /// to open (`openIMac`). False only when WezTerm is not installed.
    @MainActor
    @discardableResult
    static func open(title: String, argv: [String], cwd: String? = nil,
                     find: @escaping @Sendable ([Pane]) -> Pane?) -> Bool {
        guard isInstalled else { return false }
        DispatchQueue.global(qos: .userInitiated).async {
            var panes = WezTerm.panes()
            if panes == nil {
                DispatchQueue.main.sync { _ = WezTerm.activateApp() }
                panes = waitForPanes(until: { !$0.isEmpty })
            }
            guard let panes else {
                logger.error("WezTerm did not answer; no tab for \(title, privacy: .public)")
                return
            }
            switch plan(existing: find(panes), panes: panes) {
            case .focus(let tabId):
                run(activateTabArgs(tabId: tabId))
            case .spawn(let windowId):
                if let out = run(spawnArgs(argv: argv, cwd: cwd, windowId: windowId)),
                   let paneId = Int(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
                    run(setTabTitleArgs(paneId: paneId, title: title))
                } else {
                    logger.error("WezTerm did not spawn a tab for \(title, privacy: .public)")
                }
            }
            DispatchQueue.main.async { _ = WezTerm.activateApp() }
        }
        return true
    }

    /// Poll a WezTerm just launched (every 0.25 s, up to 8 s) until its panes
    /// satisfy `ready`; the last panes it gave, nil when it never answered.
    private static func waitForPanes(until ready: ([Pane]) -> Bool) -> [Pane]? {
        var last: [Pane]?
        for _ in 0..<32 {
            if let p = panes() {
                last = p
                if ready(p) { return p }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return last
    }
}
