import AppKit
import Foundation

// MARK: - Terminal Service

/// Opening things from the panel: a new Claude session (through
/// `launchClaudeSession`, in a WezTerm tab), a file in VS Code, a manuscript
/// in Manuscriptor. The terminal itself is `WezTerm`.
@MainActor
class TerminalService: ObservableObject {
    /// A new Claude session in ~/Projects, the folder the iMac's sessions
    /// start in (its Remote Control server's too), through the one launch
    /// path (`launchClaudeSession`): on the iMac, attached in a WezTerm tab;
    /// `onThisMac` (the button's right-click menu) starts it on this Mac.
    @discardableResult
    func launchClaudeInProjects(onThisMac: Bool = false) -> Bool {
        launchClaudeSession(name: "projects", cwd: NSHomeDirectory() + "/Projects",
                            onThisMac: onThisMac)
    }

    /// Mark `dir` trusted in ~/.claude.json so a HUD launch never stops at
    /// Claude Code's folder-trust dialog. Claude Code (2.1.273) skips the
    /// dialog when `projects[<cwd>].hasTrustDialogAccepted` is true. Every
    /// session ClaudeHUD opens on this Mac calls this first.
    ///
    /// Live claude processes rewrite ~/.claude.json, so: read it immediately
    /// before writing, change only that one key (creating a minimal project
    /// entry if absent), skip the write when already true, write atomically
    /// with the original permissions, and never write on a read/parse failure.
    static func preTrustFolder(_ dir: String) {
        let key = URL(fileURLWithPath: dir).resolvingSymlinksInPath().standardizedFileURL.path
        let configURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        guard let data = try? Data(contentsOf: configURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        var projects = root["projects"] as? [String: Any] ?? [:]
        var entry = projects[key] as? [String: Any] ?? [:]
        if entry["hasTrustDialogAccepted"] as? Bool == true { return }
        entry["hasTrustDialogAccepted"] = true
        projects[key] = entry
        root["projects"] = projects
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        else { return }

        let perms = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.posixPermissions] as? NSNumber ?? 0o600
        let tmp = configURL.deletingLastPathComponent().appending(path: ".claude.json.hud-\(UUID().uuidString.prefix(8))")
        do {
            try out.write(to: tmp)
            try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
            // rename(2): atomic replace on the same volume.
            guard rename(tmp.path, configURL.path) == 0 else {
                try? FileManager.default.removeItem(at: tmp)
                return
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// Open a single file or folder in VS Code via `open -a`. Works whether
    /// the target is a file (opens it in an editor tab) or a directory
    /// (opens it as a workspace). Falls back to plain `NSWorkspace.open`
    /// if VS Code isn't installed at the expected path.
    @discardableResult
    func openInVSCode(_ url: URL) -> Bool {
        let vscodePath = "/Applications/Visual Studio Code.app"
        guard FileManager.default.fileExists(atPath: vscodePath) else {
            NSWorkspace.shared.open(url)
            return false
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", vscodePath, url.path]
        do {
            try open.run()
            return true
        } catch {
            NSWorkspace.shared.open(url)
            return false
        }
    }

    /// Open a directory in Manuscriptor via `open -a`. ClaudeHUD hands over the
    /// project's declared `manuscript:` directory (vault Tasks.md frontmatter).
    /// Manuscriptor's root rule resolves upward only — a project root with the
    /// paper in a subdirectory would never resolve, which is why the directory
    /// is declared rather than guessed. Falls back to plain `NSWorkspace.open`
    /// if Manuscriptor isn't installed at the expected path.
    @discardableResult
    func openInManuscriptor(_ url: URL) -> Bool {
        let manuscriptorPath = "/Applications/Manuscriptor.app"
        guard FileManager.default.fileExists(atPath: manuscriptorPath) else {
            NSWorkspace.shared.open(url)
            return false
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", manuscriptorPath, url.path]
        do {
            try open.run()
            return true
        } catch {
            NSWorkspace.shared.open(url)
            return false
        }
    }
}
