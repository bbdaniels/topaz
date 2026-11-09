import Cocoa
import os

private let logger = Logger(subsystem: "com.bbdaniels.topaz.launcher", category: "Index")

/// Every application the launcher can open, in memory: the bundles Spotlight
/// finds in the Applications folders (a live `NSMetadataQuery`, so an app
/// installed or removed shows at once), the regular apps in CoreServices
/// (Finder among them), and any regular app that is running from elsewhere.
/// Bundles nested inside another app are left out. Running apps are tracked
/// from NSWorkspace's notifications, so a keystroke never asks for them.
@MainActor
final class AppIndex: NSObject {
    private(set) var candidates: [AppMatcher.Candidate] = []
    /// Bundle paths of the running apps.
    private(set) var running: Set<String> = []
    /// Called after `candidates` changes.
    var onChange: (() -> Void)?

    private let query = NSMetadataQuery()
    private var indexed: [AppMatcher.Candidate] = []
    private let work = DispatchQueue(label: "com.bbdaniels.topaz.launcher.index", qos: .userInitiated)
    nonisolated static let coreServices = "/System/Library/CoreServices"

    static var scopes: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/System/Applications", home.appendingPathComponent("Applications").path,
                coreServices].map { URL(fileURLWithPath: $0) }
    }

    func start() {
        query.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
        query.searchScopes = Self.scopes
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: query)
        center.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidUpdate, object: query)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(runningChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(runningChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        runningChanged()
        if !query.start() { logger.error("the Spotlight query did not start") }
    }

    /// The running app at `path`, if any.
    func runningApp(at path: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == path }
    }

    @objc private func gathered() {
        query.disableUpdates()
        var paths: [String] = []
        paths.reserveCapacity(query.resultCount)
        for i in 0..<query.resultCount {
            if let item = query.result(at: i) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                paths.append(path)
            }
        }
        query.enableUpdates()
        work.async { [weak self] in
            let built = AppIndex.candidates(for: paths)
            DispatchQueue.main.async {
                guard let self else { return }
                self.indexed = built
                self.merge()
                logger.info("indexed \(built.count, privacy: .public) applications")
            }
        }
    }

    @objc private func runningChanged() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
        merge()
    }

    /// The index plus the regular apps running from outside it.
    private func merge() {
        let known = Set(indexed.map(\.path))
        let extra = NSWorkspace.shared.runningApplications.compactMap { app -> AppMatcher.Candidate? in
            guard app.activationPolicy == .regular, let url = app.bundleURL?.standardizedFileURL,
                  !known.contains(url.path), AppIndex.isTopLevel(url.path) else { return nil }
            return AppMatcher.Candidate(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                        path: url.path)
        }
        candidates = indexed + extra
        onChange?()
    }

    /// Not inside another bundle (a helper inside an app).
    nonisolated static func isTopLevel(_ path: String) -> Bool {
        !URL(fileURLWithPath: path).deletingLastPathComponent().path.contains(".app")
    }

    /// Candidates for the bundle paths Spotlight found: top level only, and
    /// in CoreServices only the apps a person opens (not agents or
    /// background-only programs), each once, named as Finder names it.
    nonisolated static func candidates(for paths: [String]) -> [AppMatcher.Candidate] {
        var seen = Set<String>()
        var out: [AppMatcher.Candidate] = []
        let fm = FileManager.default
        for raw in paths {
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            guard isTopLevel(path), seen.insert(path).inserted else { continue }
            if path.hasPrefix(coreServices + "/") {
                guard URL(fileURLWithPath: path).deletingLastPathComponent().path == coreServices,
                      let info = Bundle(path: path)?.infoDictionary,
                      !(info["LSUIElement"] as? Bool ?? (info["LSUIElement"] as? String == "1")),
                      !(info["LSBackgroundOnly"] as? Bool ?? false) else { continue }
            }
            var name = fm.displayName(atPath: path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            out.append(AppMatcher.Candidate(name: name, path: path))
        }
        return out
    }
}
