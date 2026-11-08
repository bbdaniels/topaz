import Foundation
import Combine
import AppKit
import os

private let logger = Logger(subsystem: "com.claudehud", category: "VaultManager")

@MainActor
class VaultManager: ObservableObject {
    @Published var currentVault: VaultSettings?
    @Published var savedVaults: [VaultSettings] = []
    @Published var vaultFiles: [NoteFile] = []
    @Published var isVaultSelected = false

    /// The URL whose security-scoped access is open, so it is stopped on the same URL.
    private var scopedURL: URL?

    init() {
        loadVaultSettings()
    }

    func loadVaultSettings() {
        savedVaults = VaultSettings.loadFromDefaults()

        if let lastId = UserDefaults.standard.string(forKey: "obsidian.lastUsedVaultId"),
           let uuid = UUID(uuidString: lastId),
           let vault = savedVaults.first(where: { $0.id == uuid }) {
            switchToVault(vault)
        } else if let first = savedVaults.first {
            switchToVault(first)
        }
    }

    func switchToVault(_ vault: VaultSettings) {
        // The saved path is the source of truth; the bookmark only aids access
        // (see VaultAccess). A bad bookmark is healed, never fatal.
        var vault = vault
        var isDir: ObjCBool = false
        let pathExists = FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDir) && isDir.boolValue

        var resolvedURL: URL?
        var bookmark = VaultAccess.Bookmark.none
        if let data = vault.bookmarkData {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                resolvedURL = url
                bookmark = .resolved(path: url.path, isStale: isStale)
            } catch {
                logger.warning("Failed to resolve bookmark for \(vault.name): \(error.localizedDescription)")
                bookmark = .failed
            }
        }

        let decision = VaultAccess.decide(savedPath: vault.path, pathExists: pathExists, bookmark: bookmark)
        guard decision.path != nil else {
            logger.error("Vault folder does not exist: \(vault.path) (\(vault.name))")
            return
        }

        // Release the previous vault's scope on the URL that was started.
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil

        var refreshBookmark = decision.refreshBookmark
        if decision.useBookmarkScope, let url = resolvedURL {
            if url.startAccessingSecurityScopedResource() {
                scopedURL = url
            } else {
                logger.warning("Bookmark access failed for \(vault.name); using saved path")
                refreshBookmark = true
            }
        }
        if refreshBookmark {
            if bookmark != .none {
                logger.warning("Vault bookmark for \(vault.name) was stale or elsewhere; re-created from \(vault.path)")
            }
            vault.bookmarkData = try? URL(fileURLWithPath: vault.path, isDirectory: true).bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        currentVault = vault
        isVaultSelected = true
        UserDefaults.standard.set(vault.id.uuidString, forKey: "obsidian.lastUsedVaultId")
        loadVaultContents()
    }

    func selectVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select your Obsidian vault folder"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                // switchToVault opens (and later stops) access via the bookmark.
                var settings = VaultSettings(path: url.path, name: url.lastPathComponent)
                settings.bookmarkData = bookmark
                settings.saveToDefaults()

                savedVaults = VaultSettings.loadFromDefaults()
                switchToVault(settings)
            } catch {
                logger.error("Error creating bookmark: \(error.localizedDescription)")
            }
        }
    }

    func removeVault(_ vault: VaultSettings) {
        savedVaults.removeAll { $0.id == vault.id }
        do {
            let data = try JSONEncoder().encode(savedVaults)
            UserDefaults.standard.set(data, forKey: "obsidian.savedVaults")
        } catch {}

        if currentVault?.id == vault.id {
            if let next = savedVaults.first {
                switchToVault(next)
            } else {
                scopedURL?.stopAccessingSecurityScopedResource()
                scopedURL = nil
                currentVault = nil
                isVaultSelected = false
                vaultFiles = []
            }
        }
    }

    func loadVaultContents() {
        guard let vault = currentVault else { return }
        let vaultURL = URL(fileURLWithPath: vault.path)

        if let files = loadDirectory(at: vaultURL, relativePath: "") {
            vaultFiles = files
        }
    }

    // MARK: - Daily Note Generation

    /// Create today's daily note when it is missing, listing each project's
    /// open tasks (`DailyNote.content`). The tasks come from the Projects
    /// scan, which runs off the main thread; until 2026-11-08 this read every
    /// project's task file again, on the main thread.
    func ensureDailyNote(for date: Date, projects service: VaultProjectService) async {
        guard let vault = currentVault, Calendar.current.isDateInToday(date) else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = fmt.string(from: date)
        let dailyDir = (vault.path as NSString).appendingPathComponent("Daily Notes")
        let dailyPath = (dailyDir as NSString).appendingPathComponent("\(dateStr).md")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dailyPath) else { return }
        let projects = await service.currentProjects()
        // The scan took a moment: another caller may have written it since.
        guard !fm.fileExists(atPath: dailyPath) else { return }
        try? fm.createDirectory(atPath: dailyDir, withIntermediateDirectories: true)
        let content = DailyNote.content(for: date, projects: projects)
        try? content.write(toFile: dailyPath, atomically: true, encoding: .utf8)
        logger.info("Created daily note: \(dateStr) from \(projects.count) projects")
    }

    // MARK: - New project scaffold

    enum CreateProjectError: LocalizedError {
        case emptyName
        case invalidName
        case alreadyExists(String)
        case noVault
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyName:            return "Enter a project name."
            case .invalidName:          return "Name can't contain “/” or “:”, or start with a dot."
            case .alreadyExists(let n): return "A project folder named “\(n)” already exists."
            case .noVault:              return "No Obsidian vault is configured."
            case .writeFailed(let m):   return "Couldn't write the project files: \(m)"
            }
        }
    }

    /// Create a new vault project folder, scaffolded to schema conventions
    /// (see Projects/obsidian/schema.md §Vault structure / §Canonical project
    /// model): `<vault>/<name>/` with `Tasks.md` (the human-owned source of
    /// truth, `## Active`/`## Completed`, empty `cwds:` for the human to fill),
    /// a minimal `Dashboard.md` carrying the `gen:briefing` block the cloud
    /// cleaner regenerates, and a `Technical Notes.md` stub. Non-destructive:
    /// refuses if the folder already exists (never overwrites). A non-empty
    /// `parent` (a folder name chosen in the new-project sheet) is written as
    /// `parent:` in the `Tasks.md` frontmatter, making the project a child of
    /// that one; this is the app creating a file at the user's request, the
    /// only time it writes that human-owned key. Returns the new
    /// folder URL. Caller owns the follow-up (`VaultProjectService.insertProject`
    /// to surface the row, then a background `refresh()`; the 15-min
    /// `obsidian-sync.sh` pushes the folder to `origin/main`, so it's local
    /// until then).
    static func createProject(vaultPath: URL, name rawName: String,
                              parent rawParent: String? = nil) -> Result<URL, CreateProjectError> {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        // Folder-name hygiene: no path separators, no leading dot (hidden /
        // off-limits per schema), no colon (legacy HFS separator + confusing).
        guard !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            return .failure(.invalidName)
        }
        let folder = vaultPath.appending(path: name)
        if FileManager.default.fileExists(atPath: folder.path) {
            return .failure(.alreadyExists(name))
        }

        let today: String = {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .iso8601)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        let parent = rawParent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parentLine = parent.isEmpty ? "" : "parent: \(parent)\n"

        let tasks = """
        ---
        project: \(name)
        status: active
        updated: \(today)
        \(parentLine)cwds: []
        migrated-from: []
        aka: []
        ---

        # \(name) Tasks

        ## Active

        ## Completed
        """

        let dashboard = """
        ---
        project: \(name)
        status: active
        updated: \(today)
        ---

        # \(name)

        <!-- gen:briefing -->
        _No active work._
        <!-- /gen:briefing -->

        ## Tasks
        [[Tasks]]

        ## Key notes
        - [[Technical Notes]]
        """

        let techNotes = """
        ---
        project: \(name)
        updated: \(today)
        ---

        # \(name) Technical Notes

        Implementation history and non-obvious decisions. Tasks live in
        [[\(name)/Tasks]].
        """

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try tasks.write(to: folder.appending(path: "Tasks.md"),
                            atomically: true, encoding: .utf8)
            try dashboard.write(to: folder.appending(path: "Dashboard.md"),
                                atomically: true, encoding: .utf8)
            try techNotes.write(to: folder.appending(path: "Technical Notes.md"),
                                atomically: true, encoding: .utf8)
            return .success(folder)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    // MARK: - Private

    private func loadDirectory(at url: URL, relativePath: String) -> [NoteFile]? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else {
            return nil
        }

        return contents.compactMap { itemURL -> NoteFile? in
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let isDir = resourceValues?.isDirectory ?? false
            let modDate = resourceValues?.contentModificationDate
            let name = itemURL.lastPathComponent

            // Skip hidden dirs/files
            if name.hasPrefix(".") { return nil }

            let itemRelative = relativePath.isEmpty ? name : "\(relativePath)/\(name)"

            if isDir {
                let children = loadDirectory(at: itemURL, relativePath: itemRelative)
                return NoteFile(name: name, path: itemURL.path, relativePath: itemRelative,
                                isDirectory: true, modificationDate: modDate, children: children)
            } else {
                return NoteFile(name: name, path: itemURL.path, relativePath: itemRelative,
                                isDirectory: false, modificationDate: modDate, children: nil)
            }
        }
    }


}
