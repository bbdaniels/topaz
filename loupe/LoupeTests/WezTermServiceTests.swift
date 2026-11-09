import XCTest

/// The pure half of `WezTerm`: reading `wezterm cli list`, finding the tab a
/// session is in, and the command lines it runs.
final class WezTermServiceTests: XCTestCase {
    /// Trimmed from `wezterm cli list --format json` on the Mac, 2026-11-07.
    let listed = Data("""
        [{"window_id": 0, "tab_id": 1, "pane_id": 1, "workspace": "default",
          "size": {"rows": 48, "cols": 114}, "title": "ssh", "cwd": "file:///Users/u/",
          "tab_title": "rc-raspberry-pi-93280f24", "window_title": "", "is_active": true,
          "is_zoomed": false, "tty_name": "/dev/ttys006"},
         {"window_id": 0, "tab_id": 3, "pane_id": 4, "title": "claude", "tab_title": "ClaudeHUD (Mac)",
          "is_active": false, "tty_name": "/dev/ttys002"}]
        """.utf8)

    func testTheListIsRead() throws {
        let panes = try XCTUnwrap(WezTerm.parsePanes(listed))
        XCTAssertEqual(panes, [
            .init(windowId: 0, tabId: 1, paneId: 1, tabTitle: "rc-raspberry-pi-93280f24", ttyName: "/dev/ttys006"),
            .init(windowId: 0, tabId: 3, paneId: 4, tabTitle: "ClaudeHUD (Mac)", ttyName: "/dev/ttys002"),
        ])
        XCTAssertNil(WezTerm.parsePanes(Data("not json".utf8)))
    }

    func testTheTTYIsAsPsPrintsIt() {
        XCTAssertEqual(WezTerm.psTTY("/dev/ttys003"), "ttys003")
        XCTAssertEqual(WezTerm.psTTY("ttys003"), "ttys003")
    }

    /// An iMac session is found by its tab's title, its tmux session name; a
    /// Mac session by the terminal its `claude attach` runs on.
    func testEachSessionIsFoundInItsTab() throws {
        let panes = try XCTUnwrap(WezTerm.parsePanes(listed))
        let found = WezTerm.attaches(panes: panes,
                                     attachClients: [("06b55469", "ttys002"), ("d2b6b617", "ttys009")],
                                     iMacKey: { "imac-tmux:" + $0 })
        XCTAssertEqual(found["imac-tmux:rc-raspberry-pi-93280f24"]?.tabId, 1)
        XCTAssertEqual(found["06b55469"]?.tabId, 3)
        XCTAssertNil(found["d2b6b617"], "an attach in no WezTerm tab is not attached here")
        XCTAssertEqual(found.count, 2)
    }

    func testAFoundTabIsFocusedElseOneIsSpawned() throws {
        let panes = try XCTUnwrap(WezTerm.parsePanes(listed))
        XCTAssertEqual(WezTerm.plan(existing: panes[1], panes: panes), .focus(tabId: 3))
        XCTAssertEqual(WezTerm.plan(existing: nil, panes: panes), .spawn(windowId: 0))
        XCTAssertEqual(WezTerm.plan(existing: nil, panes: []), .spawn(windowId: nil))
    }

    func testTheCommandLines() {
        XCTAssertEqual(WezTerm.listArgs(), ["cli", "--no-auto-start", "list", "--format", "json"])
        XCTAssertEqual(WezTerm.spawnArgs(argv: ["/usr/bin/ssh", "-t", "imac", "tmux -L pi-gate attach -t =rc-x"],
                                         cwd: nil, windowId: 0),
                       ["cli", "--no-auto-start", "spawn", "--window-id", "0", "--",
                        "/usr/bin/ssh", "-t", "imac", "tmux -L pi-gate attach -t =rc-x"])
        XCTAssertEqual(WezTerm.spawnArgs(argv: ["/bin/zsh"], cwd: "/Users/u/Projects/a", windowId: nil),
                       ["cli", "--no-auto-start", "spawn", "--new-window", "--cwd", "/Users/u/Projects/a", "--", "/bin/zsh"])
        XCTAssertEqual(WezTerm.setTabTitleArgs(paneId: 4, title: "rc-x"),
                       ["cli", "--no-auto-start", "set-tab-title", "--pane-id", "4", "rc-x"])
        XCTAssertEqual(WezTerm.activateTabArgs(tabId: 3), ["cli", "--no-auto-start", "activate-tab", "--tab-id", "3"])
        // The edit's text goes on stdin as a bracketed paste: no text
        // argument, no --no-paste, nothing that would press Return.
        XCTAssertEqual(WezTerm.sendTextArgs(paneId: 7), ["cli", "--no-auto-start", "send-text", "--pane-id", "7"])
        XCTAssertEqual(WezTerm.activatePaneArgs(paneId: 7), ["cli", "--no-auto-start", "activate-pane", "--pane-id", "7"])
        XCTAssertEqual(WezTerm.shellArgv("claude attach abc"),
                       ["/bin/zsh", "-l", "-c", "source ~/.zshrc 2>/dev/null; unset CLAUDECODE; claude attach abc"])
    }

    /// The WezTerm config opens a tab for every live iMac session that has no
    /// tab titled with its tmux name, so the tab ClaudeHUD opens carries that
    /// name exactly; a Mac session's title can never be taken for one.
    func testAnIMacTabIsTitledWithItsTmuxSession() {
        let answer = IMacLauncher.Answer(started: true, session: "rc-probe", dir: nil)
        XCTAssertEqual(IMacLauncher.tabTitle(answer), "rc-probe")
        // tmux names have no spaces (pi-gate's NAME is [a-z0-9-]), a Mac title always has one
        XCTAssertTrue(WezTerm.macTabTitle(project: "rc-probe").contains(" "))
        XCTAssertEqual(WezTerm.macTabTitle(project: "ClaudeHUD"), "ClaudeHUD (Mac)")
    }

    /// Topaz's config is the one opener of an iMac session's tab: ClaudeHUD
    /// asks it by this line (the gate's tmux session, a tab, the time in
    /// milliseconds), and only a gate session's name is ever asked, since the
    /// config passes it to ssh.
    func testAnIMacTabIsAskedOfTheConfig() {
        let at = Date(timeIntervalSince1970: 1000.25)
        XCTAssertEqual(WezTerm.openRequest(session: "rc-topaz-1", at: at), "rc-topaz-1\t1000250\n")
        XCTAssertEqual(WezTerm.openRequest(session: "rc-" + String(repeating: "a", count: 40), at: at)?.isEmpty, false)
        for bad in ["rc-", "rc--x", "rc-Topaz", "rc-a b", "rc-a;rm", "duet", "Topaz (Mac)",
                    "rc-" + String(repeating: "a", count: 41)] {
            XCTAssertNil(WezTerm.openRequest(session: bad, at: at), bad)
        }
    }

    /// The WezTerm config reads each tab's dot from this file, so it names
    /// the pane, the tab and the HUD's light for the session in it.
    func testTheLightsFileCarriesEachTabsLight() throws {
        let tabs = [
            WezTerm.TabLight(paneId: 7, tabTitle: "projects (Mac)", light: .holding, cwd: "/Users/u/Projects"),
            WezTerm.TabLight(paneId: 1, tabTitle: "rc-tech-setup-1107", light: .running, cwd: "/home/u/Projects/pi"),
        ]
        let data = WezTerm.lightsJSON(tabs, at: Date(timeIntervalSince1970: 1_000))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["at"] as? Int, 1_000)
        let rows = try XCTUnwrap(obj["tabs"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["pane"] as? Int }, [1, 7])
        XCTAssertEqual(rows.map { $0["light"] as? String }, ["running", "holding"])
        XCTAssertEqual(rows[1]["tab"] as? String, "projects (Mac)")
        XCTAssertEqual(rows[1]["cwd"] as? String, "/Users/u/Projects")
        XCTAssertEqual([SessionLight.running, .holding, .attention, .noTab].map(\.name),
                       ["running", "holding", "attention", "no-tab"])
    }

    func testAnInheritedSocketNeverReachesTheCommandLine() {
        let env = WezTerm.cliEnvironment(["HOME": "/Users/u", "PATH": "/usr/bin",
                                          "WEZTERM_UNIX_SOCKET": "/Users/u/.local/share/wezterm/gui-sock-3381",
                                          "WEZTERM_PANE": "8"])
        XCTAssertEqual(env, ["HOME": "/Users/u", "PATH": "/usr/bin"])
    }
}
