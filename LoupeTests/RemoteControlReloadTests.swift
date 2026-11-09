import XCTest

/// RemoteControlReload: a change that would stop the Remote Control server
/// waits while the server has a live session, since launchd's bootout ends
/// every session the server started (Ben, 2026-11-08).
final class RemoteControlReloadTests: XCTestCase {
    private let claude = "/Users/bbdaniels/.local/bin/claude"
    private let versioned = "/Users/bbdaniels/.local/share/claude/versions/2.1.319"

    private func row(_ pid: Int, _ ppid: Int, _ command: String) -> ProcRow {
        ProcRow(pid: pid, ppid: ppid, rssKB: 1000, elapsed: 60, tty: "??", command: command)
    }

    /// The server (100) with two sessions, one the versioned binary; a
    /// session's own MCP server and shell below it; an unrelated claude.
    private var table: ProcessTable {
        ProcessTable(rows: [
            row(1, 0, "/sbin/launchd"),
            row(100, 1, "\(claude) remote-control --name Mac --capacity 8"),
            row(200, 100, "\(claude) --print --session-id a --input-format stream-json"),
            row(201, 100, "\(versioned) --print --session-id b --input-format stream-json"),
            row(300, 200, "\(claude) mcp serve"),
            row(301, 200, "/bin/zsh -c ls"),
            row(202, 100, "/usr/bin/caffeinate -i"),
            row(400, 1, "\(claude) --resume c"),
        ])
    }

    func testCountsTheClaudeChildrenOfTheServerOnly() {
        XCTAssertEqual(RemoteControlReload.liveSessions(serverPid: 100, table: table), 2)
    }

    func testNoServerOrAGoneServerHasNoSessions() {
        XCTAssertEqual(RemoteControlReload.liveSessions(serverPid: nil, table: table), 0)
        XCTAssertEqual(RemoteControlReload.liveSessions(serverPid: 999, table: table), 0)
        let idle = ProcessTable(rows: [row(100, 1, "\(claude) remote-control --name Mac")])
        XCTAssertEqual(RemoteControlReload.liveSessions(serverPid: 100, table: idle), 0)
    }

    func testWaitsOnlyWhileARunningServerHasSessions() {
        XCTAssertTrue(RemoteControlReload.mustWait(serverRunning: true, liveSessions: 1))
        XCTAssertFalse(RemoteControlReload.mustWait(serverRunning: true, liveSessions: 0))
        XCTAssertFalse(RemoteControlReload.mustWait(serverRunning: false, liveSessions: 3))
    }

    func testTurningOffWinsOverAReload() {
        XCTAssertEqual(RemoteControlReload.merge(.reload, into: nil), .reload)
        XCTAssertEqual(RemoteControlReload.merge(.reload, into: .reload), .reload)
        XCTAssertEqual(RemoteControlReload.merge(.turnOff, into: .reload), .turnOff)
        XCTAssertEqual(RemoteControlReload.merge(.reload, into: .turnOff), .turnOff)
    }

    func testTurningBackOnCancelsAWaitingTurnOff() {
        XCTAssertNil(RemoteControlReload.turnedBackOn(pending: .turnOff, definitionIsCurrent: true))
        XCTAssertEqual(RemoteControlReload.turnedBackOn(pending: .turnOff, definitionIsCurrent: false), .reload)
        XCTAssertEqual(RemoteControlReload.turnedBackOn(pending: .reload, definitionIsCurrent: true), .reload)
        XCTAssertNil(RemoteControlReload.turnedBackOn(pending: nil, definitionIsCurrent: true))
    }

    func testTheHeaderSaysWhatWaits() {
        func status(_ live: Int, _ waiting: RemoteControlChange?) -> String {
            RemoteControlReload.status(isBusy: false, pid: 100, isEnabled: true, serverName: "Mac",
                                       liveSessions: live, waiting: waiting)
        }
        XCTAssertEqual(status(2, .reload),
                       "Running as Mac (pid 100) · restarts with its new settings when its 2 sessions end")
        XCTAssertEqual(status(1, .turnOff), "Running as Mac (pid 100) · turns off when its 1 session ends")
        XCTAssertEqual(status(1, nil), "Running as Mac (pid 100) · 1 session")
        XCTAssertEqual(status(0, nil), "Running as Mac (pid 100)")
        XCTAssertEqual(RemoteControlReload.status(isBusy: true, pid: 100, isEnabled: true, serverName: "Mac",
                                                  liveSessions: 0, waiting: nil), "Restarting")
        XCTAssertEqual(RemoteControlReload.status(isBusy: false, pid: nil, isEnabled: true, serverName: "Mac",
                                                  liveSessions: 0, waiting: nil), "Enabled, not running")
        XCTAssertEqual(RemoteControlReload.status(isBusy: false, pid: nil, isEnabled: false, serverName: "Mac",
                                                  liveSessions: 0, waiting: nil), "Off")
    }
}
