import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "ClaudeProcessMonitor")

/// Scans Claude Code processes for the menu-bar menu: background jobs,
/// orphans and their total memory.
///
/// Scans only when the menu opens (a scan is one `ps`, one `lsof` over the
/// workers and a few small JSON reads, about 0.1 s); nothing else reads a
/// scan, so there is no timer (the 15-minute timer fed only the orphan count
/// beside the menu-bar icon, removed 2026-11-08).
/// It NEVER closes anything by itself. Close is `close(_:)`, reached only from
/// a confirmed menu click: on 2026-10-05 a process that looked orphaned was a
/// live 8-day monitoring job.
@MainActor
final class ClaudeProcessMonitor {
    /// Synchronous scan for the menu, which is built synchronously. Cheap
    /// enough (about 0.1 s) to run on the click.
    func scan() -> ClaudeProcessReport {
        ClaudeProcessSnapshot.capture()
    }

    /// Close one orphan, after the user confirmed it.
    ///
    /// A daemon session (it has a short id) is first asked to stop through
    /// the CLI's own verb, `claude stop <id>`, so the daemon records it as
    /// stopped rather than crashed and it stays resumable. Whatever is still
    /// running 5 s later, and every process of an orphan with no session, gets
    /// SIGTERM, then SIGKILL after another 5 s. Each signal is sent only to a
    /// pid whose command line still matches the one recorded at scan time, so
    /// a recycled pid is never hit.
    func close(_ w: ClassifiedWorker) async {
        guard w.cls.isOrphan else { return }
        logger.notice("Closing orphan \(w.project, privacy: .public) root=\(w.rootPid) short=\(w.short ?? "-", privacy: .public)")
        let list = w.killList
        if let short = w.short {
            let r = await AgentsService.stopAndWait(short)
            if r.code != 0 { logger.notice("claude stop \(short, privacy: .public) exited \(r.code)") }
            if await Self.waitGone(list, seconds: 5) { return }
        }
        Self.signal(list, SIGTERM)
        if !(await Self.waitGone(list, seconds: 5)) {
            Self.signal(list, SIGKILL)
            _ = await Self.waitGone(list, seconds: 2)
        }
    }

    /// Rows of `list` still running the same command.
    nonisolated static func survivors(_ list: [ProcRow]) -> [ProcRow] {
        let now = ClaudeProcessSnapshot.processTable()
        return list.filter { now.rows[$0.pid]?.command == $0.command }
    }

    nonisolated static func signal(_ list: [ProcRow], _ sig: Int32) {
        for p in survivors(list) { kill(pid_t(p.pid), sig) }
    }

    nonisolated static func waitGone(_ list: [ProcRow], seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if survivors(list).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return survivors(list).isEmpty
    }
}
