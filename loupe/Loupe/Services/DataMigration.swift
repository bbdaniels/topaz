import Foundation

/// Moves the app's data from its ClaudeHUD names to its Loupe names, once,
/// at launch (Ben, 2026-11-08: the app underneath became Loupe; its bundle
/// id went from `com.claudehud.app` to `com.bbdaniels.topaz.loupe`).
///
/// Each folder or file under `~/Library` moves only when the old one exists
/// and the new one is absent or an empty folder, so a second launch does
/// nothing and nothing is ever overwritten. The old defaults domain is
/// copied into the new one, key by key where the new one has none, once
/// (marked by `importedKey`); the old domain is left as it was.
///
/// It runs before anything opens these files (`AppDelegate.init`, before
/// `AppState`). Pure Foundation, so the tests run it against a temporary
/// folder and in-memory defaults domains (see project.yml, LoupeTests).
/// The keychain item `com.claudehud.vault` is not data here: it keeps its
/// name (SecretsVault).
/// The defaults domains the import reads and writes: `UserDefaults` in the
/// app, a dictionary in the tests (which never touch real preferences).
protocol PreferenceDomains: AnyObject {
    func persistentDomain(forName domainName: String) -> [String: Any]?
    func setPersistentDomain(_ domain: [String: Any], forName domainName: String)
}

extension UserDefaults: PreferenceDomains {}

enum DataMigration {
    static let oldBundleIdentifier = "com.claudehud.app"
    static let newBundleIdentifier = "com.bbdaniels.topaz.loupe"
    /// Set in the new domain once the old domain has been copied into it.
    static let importedKey = "loupe.importedClaudeHUDDefaults"

    /// The moves, as paths relative to `~/Library`, old then new. The first
    /// two are the app's own folders; the rest are named by the bundle id
    /// (the URL cache, cookies and WebKit's website data, which holds the
    /// claude.ai Cloudflare clearance).
    static func moves(old: String = oldBundleIdentifier, new: String = newBundleIdentifier) -> [(String, String)] {
        [
            ("Application Support/ClaudeHUD", "Application Support/Loupe"),
            ("Caches/ClaudeHUD", "Caches/Loupe"),
            ("Caches/\(old)", "Caches/\(new)"),
            ("HTTPStorages/\(old)", "HTTPStorages/\(new)"),
            ("HTTPStorages/\(old).binarycookies", "HTTPStorages/\(new).binarycookies"),
            ("WebKit/\(old)", "WebKit/\(new)"),
        ]
    }

    /// What one launch did, for the log and the tests.
    struct Report: Equatable {
        var moved: [String] = []
        /// Old paths left in place because the new one already holds something.
        var kept: [String] = []
        var failed: [String] = []
        /// Keys copied from the old defaults domain.
        var importedKeys = 0
    }

    /// The real run: `~/Library`, the standard defaults, this app's bundle id.
    @discardableResult
    static func runAtLaunch() -> Report {
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        let new = Bundle.main.bundleIdentifier ?? newBundleIdentifier
        let report = run(library: library, oldDomain: oldBundleIdentifier, newDomain: new, defaults: UserDefaults.standard)
        if report != Report() {
            NSLog("Loupe data migration: moved %@; kept %@; failed %@; %d defaults keys imported",
                  report.moved.description, report.kept.description, report.failed.description, report.importedKeys)
        }
        return report
    }

    static func run(library: URL, oldDomain: String, newDomain: String,
                    defaults: PreferenceDomains, fm: FileManager = .default) -> Report {
        var report = Report()
        guard oldDomain != newDomain else { return report }
        for (old, new) in moves(old: oldDomain, new: newDomain) {
            let from = library.appendingPathComponent(old)
            let to = library.appendingPathComponent(new)
            guard fm.fileExists(atPath: from.path) else { continue }
            if fm.fileExists(atPath: to.path) {
                let contents = try? fm.contentsOfDirectory(atPath: to.path)
                guard contents?.isEmpty == true else { report.kept.append(old); continue }
                try? fm.removeItem(at: to)
            }
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                report.moved.append(old)
            } catch {
                report.failed.append(old)
            }
        }
        report.importedKeys = importDefaults(from: oldDomain, to: newDomain, defaults: defaults)
        return report
    }

    /// Copies every key of the old domain the new one lacks, once. Returns
    /// how many were copied.
    static func importDefaults(from oldDomain: String, to newDomain: String, defaults: PreferenceDomains) -> Int {
        var current = defaults.persistentDomain(forName: newDomain) ?? [:]
        guard current[importedKey] == nil else { return 0 }
        let old = defaults.persistentDomain(forName: oldDomain) ?? [:]
        var copied = 0
        for (key, value) in old where current[key] == nil {
            current[key] = value
            copied += 1
        }
        current[importedKey] = true
        defaults.setPersistentDomain(current, forName: newDomain)
        return copied
    }
}
