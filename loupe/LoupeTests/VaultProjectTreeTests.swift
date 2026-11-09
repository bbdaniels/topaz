import XCTest

/// The Projects tab's parent → children tree (`ProjectTree`) and the roll-ups
/// a parent row shows. Rule 6 of the nested-subprojects design: an invalid
/// `parent:` leaves the project top-level, so nothing can disappear.
final class VaultProjectTreeTests: XCTestCase {

    func project(_ name: String, parent: String? = nil, status: String = "active") -> VaultProject {
        VaultProject(folder: URL(fileURLWithPath: "/vault/\(name)"), name: name, status: status,
                     updated: nil, cwds: [], manuscript: nil, parent: parent)
    }

    /// "Root" or "Root > Child, Child", one string per top-level row.
    func shape(_ nodes: [ProjectTree.Node]) -> [String] {
        nodes.map { n in
            n.children.isEmpty ? n.project.name
                : "\(n.project.name) > \(n.children.map(\.name).joined(separator: ", "))"
        }
    }

    func day(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 86_400) }

    // MARK: Frontmatter

    func testParentIsReadFromTasksFrontmatter() {
        let folder = URL(fileURLWithPath: "/vault/Raspberry Pi")
        let child = VaultProject.parse(folder: folder, tasksContent: """
        ---
        project: Raspberry Pi
        status: active
        updated: 2026-10-07
        parent: Personal
        cwds:
          - /Users/u/Projects/raspberry-pi
        ---

        # Raspberry Pi Tasks
        """)
        XCTAssertEqual(child.parent, "Personal")
        XCTAssertEqual(child.cwds, ["/Users/u/Projects/raspberry-pi"])

        let plain = VaultProject.parse(folder: folder, tasksContent: "---\nstatus: active\n---\n")
        XCTAssertNil(plain.parent)
        let empty = VaultProject.parse(folder: folder, tasksContent: "---\nparent:\nstatus: active\n---\n")
        XCTAssertNil(empty.parent)
    }

    // MARK: Tree (rule 6)

    func testValidChildRendersUnderItsParentNotAsARoot() {
        let nodes = ProjectTree.build([project("Personal"), project("Investing", parent: "Personal"),
                                       project("Cayda")])
        XCTAssertEqual(shape(nodes), ["Personal > Investing", "Cayda"])
    }

    func testUnknownParentLeavesTheProjectTopLevel() {
        let nodes = ProjectTree.build([project("Personal"), project("Investing", parent: "Personel")])
        XCTAssertEqual(shape(nodes), ["Personal", "Investing"])
    }

    func testParentThatHasAParentIsInvalid() {
        // Momir names Heat TV, which is itself a child: one level only, so
        // Momir is an ordinary top-level project and Heat TV stays a leaf.
        let nodes = ProjectTree.build([project("Games"), project("Heat TV", parent: "Games"),
                                       project("Momir", parent: "Heat TV")])
        XCTAssertEqual(shape(nodes), ["Games > Heat TV", "Momir"])
    }

    func testCycleAndSelfParentLeaveEveryProjectTopLevel() {
        let nodes = ProjectTree.build([project("A", parent: "B"), project("B", parent: "A"),
                                       project("C", parent: "C")])
        XCTAssertEqual(shape(nodes), ["A", "B", "C"])
    }

    func testTwoChildrenUnderOneParent() {
        let nodes = ProjectTree.build([project("CV", parent: "Career"), project("Career"),
                                       project("Job Search", parent: "Career")])
        XCTAssertEqual(shape(nodes), ["Career > CV, Job Search"])
    }

    // MARK: Roll-ups

    func testParentBadgeSumsOwnAndChildrenSessions() {
        let node = ProjectTree.build([project("Personal"), project("Investing", parent: "Personal"),
                                      project("Raspberry Pi", parent: "Personal")])[0]
        let live = [
            "Personal": LiveSessionCounts(running: 1, attention: 0, noTab: 2),
            "Investing": LiveSessionCounts(running: 0, attention: 1, noTab: 0),
            "Raspberry Pi": LiveSessionCounts(running: 2, attention: 0, noTab: 1),
            "Cayda": LiveSessionCounts(running: 9, attention: 9, noTab: 9),
        ]
        XCTAssertEqual(node.liveCounts(in: live), LiveSessionCounts(running: 3, attention: 1, noTab: 3))
        XCTAssertEqual(node.folderNames, ["Personal", "Investing", "Raspberry Pi"])
    }

    func testParentRecencyIsMaxOverItselfAndChildren() {
        let node = ProjectTree.build([project("Personal"), project("Investing", parent: "Personal"),
                                      project("Raspberry Pi", parent: "Personal")])[0]
        let activity = ["Personal": day(3), "Investing": day(9), "Raspberry Pi": day(5)]
        let at: (VaultProject) -> Date = { activity[$0.name]! }
        XCTAssertEqual(node.recency(at), day(9))
        // Children are ordered among themselves by their own recency.
        XCTAssertEqual(node.childrenByRecency(at).map(\.name), ["Investing", "Raspberry Pi"])
        let reversed = ["Personal": day(3), "Investing": day(1), "Raspberry Pi": day(5)]
        XCTAssertEqual(node.childrenByRecency { reversed[$0.name]! }.map(\.name),
                       ["Raspberry Pi", "Investing"])
        XCTAssertEqual(node.recency { reversed[$0.name]! }, day(5))
    }

    func testOrderingUsesFamilyRecencyAndFloatsAWaitingChild() {
        let nodes = ProjectTree.build([project("Cayda"), project("Personal"),
                                       project("Investing", parent: "Personal"), project("Mumbai")])
        let activity = ["Cayda": day(8), "Personal": day(1), "Investing": day(9), "Mumbai": day(5)]
        let at: (VaultProject) -> Date = { activity[$0.name]! }
        // Personal's own activity is the oldest; its child makes it the newest.
        XCTAssertEqual(ProjectTree.ordered(nodes, live: [:], activity: at).map(\.project.name),
                       ["Personal", "Cayda", "Mumbai"])
        // A session waiting on the user in a CHILD floats the whole family.
        let stale = ["Cayda": day(8), "Personal": day(1), "Investing": day(2), "Mumbai": day(5)]
        let live = ["Investing": LiveSessionCounts(running: 0, attention: 1, noTab: 0)]
        XCTAssertEqual(ProjectTree.ordered(nodes, live: live) { stale[$0.name]! }.map(\.project.name),
                       ["Personal", "Cayda", "Mumbai"])
        XCTAssertEqual(ProjectTree.ordered(nodes, live: [:]) { stale[$0.name]! }.map(\.project.name),
                       ["Cayda", "Mumbai", "Personal"])
    }

    func testOrderingFloatsAnOverdueFamilyBelowAWaitingOne() {
        func due(_ name: String, _ d: Date, parent: String? = nil) -> VaultProject {
            VaultProject(folder: URL(fileURLWithPath: "/vault/\(name)"), name: name, status: "active",
                         updated: nil, cwds: [], manuscript: nil, parent: parent,
                         nextDue: ActiveTasks.NextDue(date: d, title: "t"))
        }
        let now = day(10) + 3600
        let nodes = ProjectTree.build([project("Cayda"), project("Personal"),
                                       due("Investing", day(9), parent: "Personal"),
                                       due("Mumbai", day(10)), project("Waiting")])
        let activity = ["Cayda": day(8), "Personal": day(1), "Investing": day(2),
                        "Mumbai": day(5), "Waiting": day(0)]
        let live = ["Waiting": LiveSessionCounts(running: 0, attention: 1, noTab: 0)]
        // Waiting first; then Personal, whose child is a day late; Mumbai is
        // due today, so not late, and keeps its recency place.
        XCTAssertEqual(ProjectTree.ordered(nodes, live: live, activity: { activity[$0.name]! }, now: now)
                        .map(\.project.name),
                       ["Waiting", "Personal", "Cayda", "Mumbai"])
    }

    // MARK: Search

    func testSearchOnAChildShowsItUnderItsParent() {
        let nodes = ProjectTree.build([project("Personal"), project("Investing", parent: "Personal"),
                                       project("Raspberry Pi", parent: "Personal"), project("Cayda")])
        // The parent does not match "invest": it is kept as context, with only
        // the matching child beneath it.
        XCTAssertEqual(shape(ProjectTree.filter(nodes, query: "invest")), ["Personal > Investing"])
        // A parent that matches keeps all its children.
        XCTAssertEqual(shape(ProjectTree.filter(nodes, query: "personal")),
                       ["Personal > Investing, Raspberry Pi"])
        XCTAssertEqual(shape(ProjectTree.filter(nodes, query: "  ")),
                       ["Personal > Investing, Raspberry Pi", "Cayda"])
        XCTAssertEqual(shape(ProjectTree.filter(nodes, query: "zzz")), [])
    }

    // MARK: New-project parent picker

    func testParentCandidatesExcludeProjectsThatDeclareAParent() {
        let all = [project("Personal"), project("Investing", parent: "Personal"),
                   project("Orphan", parent: "Nowhere"), project("Cayda")]
        XCTAssertEqual(ProjectTree.parentCandidates(all), ["Cayda", "Personal"])
    }

    // MARK: Live vault (read-only)

    /// Scans the real vault with the app's own scan + tree and prints the
    /// families. Read-only. Runs only when `LOUPE_VAULT` is set, so the
    /// suite has no dependency on one machine's vault.
    func testPrintLiveVaultTree() throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPE_VAULT"] else {
            throw XCTSkip("set LOUPE_VAULT to print the live vault's project tree")
        }
        let projects = VaultProject.scan(vaultPath: URL(fileURLWithPath: path))
        let nodes = ProjectTree.build(projects)
        print("LIVE-TREE projects=\(projects.count) roots=\(nodes.count)")
        for n in nodes where !n.children.isEmpty {
            print("LIVE-TREE \(n.project.name) > \(n.children.map(\.name).sorted().joined(separator: ", "))")
        }
        let declared = projects.filter { $0.parent != nil }
        let placed = Set(nodes.flatMap { $0.children.map(\.name) })
        for p in declared where !placed.contains(p.name) {
            print("LIVE-TREE INVALID parent: \(p.name) -> \(p.parent ?? "")")
        }
        XCTAssertEqual(nodes.reduce(0) { $0 + 1 + $1.children.count }, projects.count,
                       "every scanned project appears exactly once")
    }
}

/// The session lines' one dot and the no-tab rule (`SessionLight`, Ben,
/// 2026-11-03): green running, red anything else, and a session not running
/// with no WezTerm tab here grey (2026-11-08), sorted last and not lighting
/// its header.
final class SessionLightTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func light(running: Bool = false, quietFor: TimeInterval, window: Bool = true) -> SessionLight {
        SessionLight.of(running: running, hasWindow: window, lastMoved: now.addingTimeInterval(-quietFor), now: now)
    }

    func testRunningIsGreenAndAnythingElseRed() {
        XCTAssertEqual(light(running: true, quietFor: 7200), .running)
        XCTAssertEqual(light(quietFor: 60), .attention)
    }

    func testAShellCommandRunningFiveMinutesWithNothingMovingIsOrange() {
        func shell(_ quiet: TimeInterval) -> SessionLight {
            SessionLight.of(running: true, inShell: true, hasWindow: false, lastMoved: now.addingTimeInterval(-quiet), now: now)
        }
        XCTAssertEqual(shell(301), .holding)
        XCTAssertEqual(shell(299), .running)
        XCTAssertEqual(light(running: true, quietFor: 7200), .running, "a busy turn outside a shell stays green")
        var counts = LiveSessionCounts()
        counts.add(.holding)
        XCTAssertEqual(counts.light, .holding)
        counts.add(.running)
        XCTAssertEqual(counts.light, .running)
        counts.add(.attention)
        XCTAssertEqual(counts.light, .attention)
    }

    func testASessionWithNoTabIsGreyAtOnceUnlessBusy() {
        XCTAssertEqual(light(quietFor: 5, window: false), .noTab)
        XCTAssertEqual(light(quietFor: 7200, window: true), .attention)
        XCTAssertEqual(light(running: true, quietFor: 5, window: false), .running)
        XCTAssertEqual(SessionLight.of(running: false, workOut: true, hasWindow: false, lastMoved: now, now: now), .holding)
    }

    func testALeftOutTreeIsListedUnderTheProjectItRunsIn() {
        XCTAssertEqual(SessionFiling.treeFolder(own: "AI-MED", session: "Personal"), "AI-MED")
        XCTAssertEqual(SessionFiling.treeFolder(own: nil, session: "Personal"), "Personal")
        XCTAssertEqual(SessionFiling.treeFolder(own: nil, session: nil), "")
    }

    func testAServiceRecordIsReadFromTheGatesLiveRow() {
        let row = #"{"pid": 7, "sessionId": "s", "cwd": "/x", "tmux": "duet:@0.%0", "attach": "tmux -L duet attach -t =duet", "service": "duet"}"#
        let r = ClaudeSessionRecords.parse(Data(row.utf8))
        XCTAssertEqual(r?.service, "duet")
        XCTAssertNil(ClaudeSessionRecords.parse(Data(#"{"pid": 7, "sessionId": "s"}"#.utf8))?.service)
    }

    func testTheHeaderIsRedOverGreenAndLeftoversLightNothing() {
        XCTAssertEqual(LiveSessionCounts(running: 1, attention: 1, noTab: 0).light, .attention)
        XCTAssertEqual(LiveSessionCounts(running: 1, attention: 0, noTab: 3).light, .running)
        XCTAssertNil(LiveSessionCounts(running: 0, attention: 0, noTab: 2).light)
    }

    func testSessionsWithNoTabSortLastAndKeepTheirOrder() {
        let items: [(String, SessionLight)] = [("old", .noTab), ("run", .running), ("older", .noTab), ("red", .attention)]
        XCTAssertEqual(SessionLight.tabbedFirst(items, light: { $0.1 }).map { $0.0 }, ["run", "red", "old", "older"])
    }

    func testTheGatesEndAnswerReadsAsStoppedOrItsReason() {
        XCTAssertNil(IMacLauncher.endFailure(status: 0, stdout: Data(#"{"ok": true, "ended": "x", "copies": 1}"#.utf8)))
        XCTAssertEqual(IMacLauncher.endFailure(status: 0, stdout: Data(#"{"ok": false, "error": "no running session with that id"}"#.utf8)),
                       "no running session with that id")
        XCTAssertEqual(IMacLauncher.endFailure(status: 255, stdout: Data()), "the iMac did not answer")
    }

    /// 2026-11-08: the gate said a background session had stopped, its daemon
    /// started it again, and the row stayed struck through with no word.
    func testAStopFailsOnTheGatesRefusalOrASessionStillListedAfterTheDeadline() {
        XCTAssertNil(IMacLauncher.stopFailure(refused: nil, stillListed: false))
        XCTAssertEqual(IMacLauncher.stopFailure(refused: "the session did not stop", stillListed: true),
                       "the session did not stop")
        XCTAssertEqual(IMacLauncher.stopFailure(refused: nil, stillListed: true),
                       "the gate said it stopped, but it was still running 15 seconds later")
    }
}

/// What rescans the Projects list, and the daily note built from the scan.
final class VaultWatchTests: XCTestCase {

    // MARK: Vault watch

    func testANewOrRenamedProjectFolderRescans() {
        let vault = "/Users/b/Projects/obsidian"
        // A folder moved into the vault is reported as the folder alone, not
        // the Tasks.md inside it (probed on the Mac, 2026-11-08).
        XCTAssertTrue(VaultWatch.needsRescan(paths: [vault + "/Topaz"], flags: [0x20800], vault: vault))
        XCTAssertTrue(VaultWatch.needsRescan(paths: [vault + "/Topaz/Tasks.md"], flags: [0x19100], vault: vault))
        XCTAssertTrue(VaultWatch.needsRescan(paths: [vault + "/Old Name"], flags: [0x20800], vault: vault + "/"))
        // a project folder removed (ItemIsDir | ItemRemoved)
        XCTAssertTrue(VaultWatch.needsRescan(paths: [vault + "/Gone"], flags: [0x20200], vault: vault))
        // beside a top-level note, the folder still counts by its own flag
        XCTAssertTrue(VaultWatch.needsRescan(paths: [vault + "/log.md", vault + "/Topaz"],
                                             flags: [0x11000, 0x20100], vault: vault))
    }

    func testOtherVaultWritesDoNotRescan() {
        let vault = "/Users/b/Projects/obsidian"
        XCTAssertFalse(VaultWatch.needsRescan(paths: [vault + "/Topaz/Dashboard.md"], flags: [0x19100], vault: vault))
        XCTAssertFalse(VaultWatch.needsRescan(paths: [vault + "/.git/index", vault + "/.git"], flags: [0x10000, 0x20000], vault: vault))
        XCTAssertFalse(VaultWatch.needsRescan(paths: [vault + "/.obsidian/workspace.json"], flags: [0x10000], vault: vault))
        XCTAssertFalse(VaultWatch.needsRescan(paths: [vault + "/Topaz/.git/x/Tasks.md"], flags: [0x10000], vault: vault))
        XCTAssertFalse(VaultWatch.needsRescan(paths: [vault + "/Daily Notes/2026-11-08.md"], flags: [0x10000], vault: vault))
        // top-level notes are one path deep like a project folder, but files
        // (ItemIsFile with ItemModified, ItemCreated, ItemRenamed or ItemRemoved)
        for note in ["log.md", "index.md", "HOME.md"] {
            for flag: UInt32 in [0x11000, 0x19100, 0x10100, 0x10800, 0x10200] {
                XCTAssertFalse(VaultWatch.needsRescan(paths: [vault + "/" + note], flags: [flag], vault: vault),
                               "\(note) \(flag)")
            }
        }
    }

    func testDroppedEventsRescan() {
        // MustScanSubDirs, UserDropped, KernelDropped, RootChanged: FSEvents
        // could not say what changed, so the scan must look.
        for flag: UInt32 in [0x01, 0x02, 0x04, 0x20] {
            XCTAssertTrue(VaultWatch.needsRescan(paths: ["/Users/b/Projects/obsidian/Topaz/x"], flags: [flag],
                                                 vault: "/Users/b/Projects/obsidian"), "flag \(flag)")
        }
    }

    // MARK: Refiling when the claims change

    func testTheFilingClaimsChangeOnlyWithTheProjectsOrWhatTheyClaim() {
        func project(_ name: String, _ front: String, _ body: String = "") -> VaultProject {
            VaultProject.parse(folder: URL(fileURLWithPath: "/vault/" + name),
                               tasksContent: "---\nstatus: active\n\(front)---\n## Active\n\(body)")
        }
        let wezterm = "cwds:\n  - /Users/b/Projects/wezterm\n"
        let before = VaultProject.filingClaims([project("Tech Setup", "")])
        // A new project that claims a directory (Topaz, 2026-11-08) changes it.
        let added = VaultProject.filingClaims([project("Tech Setup", ""), project("Topaz", wezterm)])
        XCTAssertNotEqual(before, added)
        // A folder renamed or merged away (ClaudeHUD into Topaz) changes it.
        XCTAssertNotEqual(VaultProject.filingClaims([project("ClaudeHUD", wezterm)]),
                          VaultProject.filingClaims([project("Topaz", wezterm)]))
        // An edited repo: claim changes it.
        XCTAssertNotEqual(added, VaultProject.filingClaims([
            project("Tech Setup", ""), project("Topaz", wezterm + "repo:\n  - github.com/bbdaniels/wezterm\n")]))
        // A task ticked or added does not: only the claims are read.
        XCTAssertEqual(added, VaultProject.filingClaims([
            project("Tech Setup", "", "- [ ] New task\n"), project("Topaz", wezterm, "- [x] Done\n")]))
        XCTAssertEqual(project("Topaz", wezterm).claims.cwds, ["/Users/b/Projects/wezterm"])
    }

    // MARK: Daily note from the scan

    func testTheScanKeepsEachProjectsOpenTasks() {
        let p = VaultProject.parse(folder: URL(fileURLWithPath: "/vault/Cayda"), tasksContent: """
        ---
        status: active
        ---
        ## Active
        - [ ] **First**: do it
        - [x] Done already
        - [ ] Second
        ## Completed
        - [ ] Not active
        """)
        // A flat task's title, as the daily note listed it before the move.
        XCTAssertEqual(p.openTasks, ["First", "Second"])
    }

    func testTheDailyNoteListsOpenTasksByProjectName() {
        func with(_ name: String, _ tasks: [String]) -> VaultProject {
            var p = VaultProject(folder: URL(fileURLWithPath: "/vault/\(name)"), name: name, status: "active",
                                 updated: nil, cwds: [], manuscript: nil, parent: nil)
            p.openTasks = tasks; return p
        }
        let date = Date(timeIntervalSince1970: 1_762_560_000) // Saturday, November 8, 2025 UTC
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let note = DailyNote.content(for: date, projects: [
            with("Zeta", ["z1"]), with("Alpha", (1...10).map { "a\($0)" }),
            with("Empty", []), with("Templates", ["skip me"]),
        ], calendar: cal)
        XCTAssertEqual(note, """
        # Saturday, November 8, 2025

        ## Open Items

        ### Alpha
        - [ ] a1
        - [ ] a2
        - [ ] a3
        - [ ] a4
        - [ ] a5
        - [ ] a6
        - [ ] a7
        - [ ] a8

        ### Zeta
        - [ ] z1

        ## Notes


        """)
        XCTAssertEqual(DailyNote.content(for: date, projects: [with("Empty", [])], calendar: cal),
                       "# Saturday, November 8, 2025\n\n- [ ] \n## Notes\n\n")
    }
}
