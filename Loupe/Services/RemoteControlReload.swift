import Foundation

// When the Remote Control server may restart. Foundation only, no I/O, so the
// unit tests feed it fixture process tables; RemoteControlServerService does
// the launchctl calls.
//
// The server's sessions are its own child processes, so launchd's bootout of
// com.bbdaniels.claude-remote-control ends every session it started (Ben,
// 2026-11-08). The toggle, a permission picker change and a HUD build whose
// plist differs all went through that bootout at once. Now a change that
// would stop a running server waits while the server has a live session,
// applies by itself once the last one ends, and the header says it waits.

/// A change to the server that stops the running job.
enum RemoteControlChange: Equatable {
    /// Rewrite the plist and bootstrap it again: the permission picker
    /// changed, or this HUD build writes a different definition.
    case reload
    /// Bootout and delete the plist: the toggle was turned off.
    case turnOff
}

/// What applying a change did.
enum RemoteControlOutcome: Equatable {
    case applied
    /// Not applied: the server has this many live sessions.
    case waits(Int)
    case failed(String)
}

enum RemoteControlReload {
    /// The sessions the server runs: the claude processes directly under it.
    /// Anything those sessions start (shells, MCP servers) sits below them and
    /// is not counted; a child that is not claude is not a session.
    static func liveSessions(serverPid: Int?, table: ProcessTable) -> Int {
        guard let serverPid, table.rows[serverPid] != nil else { return 0 }
        return table.children(of: serverPid)
            .filter { ClaudeProcKind.of(command: $0.command) != .notClaude }
            .count
    }

    /// Whether `change` waits: only while a server is running with a live
    /// session. With no server running there is nothing to end.
    static func mustWait(serverRunning: Bool, liveSessions: Int) -> Bool {
        serverRunning && liveSessions > 0
    }

    /// The change left waiting when `requested` arrives while `pending`
    /// waits: turning off wins over a reload, since it stops the server too.
    static func merge(_ requested: RemoteControlChange, into pending: RemoteControlChange?) -> RemoteControlChange {
        pending == .turnOff || requested == .turnOff ? .turnOff : .reload
    }

    /// Turning the toggle back on while a turn-off waits cancels it; what
    /// still waits is only the reload the installed definition needs.
    static func turnedBackOn(pending: RemoteControlChange?, definitionIsCurrent: Bool) -> RemoteControlChange? {
        definitionIsCurrent && pending != .reload ? nil : .reload
    }

    /// The header's line for the server.
    static func status(isBusy: Bool, pid: Int?, isEnabled: Bool, serverName: String,
                       liveSessions: Int, waiting: RemoteControlChange?) -> String {
        if isBusy { return "Restarting" }
        let sessions = liveSessions == 1 ? "1 session" : "\(liveSessions) sessions"
        let end = liveSessions == 1 ? "ends" : "end"
        if let pid {
            let running = "Running as \(serverName) (pid \(pid))"
            switch waiting {
            case .reload: return "\(running) · restarts with its new settings when its \(sessions) \(end)"
            case .turnOff: return "\(running) · turns off when its \(sessions) \(end)"
            case nil: return liveSessions > 0 ? "\(running) · \(sessions)" : running
            }
        }
        return isEnabled ? "Enabled, not running" : "Off"
    }
}
