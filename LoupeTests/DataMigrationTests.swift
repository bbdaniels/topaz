import XCTest

/// `DataMigration`: the one-time move of the app's data from its ClaudeHUD
/// names to its Loupe names, against a temporary `Library` folder and
/// throwaway defaults domains.
private final class MemoryDomains: PreferenceDomains {
    var domains: [String: [String: Any]] = [:]
    func persistentDomain(forName domainName: String) -> [String: Any]? { domains[domainName] }
    func setPersistentDomain(_ domain: [String: Any], forName domainName: String) { domains[domainName] = domain }
}

final class DataMigrationTests: XCTestCase {
    private var library: URL!
    private var oldDomain: String!
    private var newDomain: String!
    private let fm = FileManager.default
    private var defaults = MemoryDomains()

    override func setUpWithError() throws {
        library = fm.temporaryDirectory.appendingPathComponent("loupe-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        let tag = UUID().uuidString
        oldDomain = "test.loupe-migration.old.\(tag)"
        newDomain = "test.loupe-migration.new.\(tag)"
        defaults = MemoryDomains()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: library)
    }

    private func write(_ relative: String, _ text: String = "x") throws {
        let url = library.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ relative: String) -> String? {
        (try? Data(contentsOf: library.appendingPathComponent(relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func exists(_ relative: String) -> Bool {
        fm.fileExists(atPath: library.appendingPathComponent(relative).path)
    }

    private func migrate() -> DataMigration.Report {
        DataMigration.run(library: library, oldDomain: oldDomain, newDomain: newDomain, defaults: defaults)
    }

    func testTheRealNames() {
        XCTAssertEqual(DataMigration.moves().map(\.1), [
            "Application Support/Loupe", "Caches/Loupe",
            "Caches/com.bbdaniels.topaz.loupe", "HTTPStorages/com.bbdaniels.topaz.loupe",
            "HTTPStorages/com.bbdaniels.topaz.loupe.binarycookies", "WebKit/com.bbdaniels.topaz.loupe",
        ])
        XCTAssertEqual(DataMigration.moves().first?.0, "Application Support/ClaudeHUD")
        XCTAssertEqual(DataMigration.moves()[2].0, "Caches/com.claudehud.app")
    }

    func testMovesEveryFolderAndFileOnce() throws {
        try write("Application Support/ClaudeHUD/transcript-index.sqlite", "index")
        try write("Caches/ClaudeHUD/wezterm-lights.json", "lights")
        try write("Caches/ClaudeHUD/hosts/imac/projects/a.jsonl", "a")
        try write("Caches/\(oldDomain!)/Cache.db", "cache")
        try write("HTTPStorages/\(oldDomain!)/httpstorages.sqlite", "storage")
        try write("HTTPStorages/\(oldDomain!).binarycookies", "cookies")
        try write("WebKit/\(oldDomain!)/WebsiteData/x", "web")

        let report = migrate()
        XCTAssertEqual(report.moved.count, 6)
        XCTAssertEqual(report.kept, [])
        XCTAssertEqual(report.failed, [])
        XCTAssertEqual(read("Application Support/Loupe/transcript-index.sqlite"), "index")
        XCTAssertEqual(read("Caches/Loupe/wezterm-lights.json"), "lights")
        XCTAssertEqual(read("Caches/Loupe/hosts/imac/projects/a.jsonl"), "a")
        XCTAssertEqual(read("Caches/\(newDomain!)/Cache.db"), "cache")
        XCTAssertEqual(read("HTTPStorages/\(newDomain!)/httpstorages.sqlite"), "storage")
        XCTAssertEqual(read("HTTPStorages/\(newDomain!).binarycookies"), "cookies")
        XCTAssertEqual(read("WebKit/\(newDomain!)/WebsiteData/x"), "web")
        for (old, _) in DataMigration.moves(old: oldDomain, new: newDomain) {
            XCTAssertFalse(exists(old), old)
        }
        // A second launch finds nothing to move.
        XCTAssertEqual(migrate().moved, [])
    }

    func testNeverOverwritesWhatTheNewPlaceHolds() throws {
        try write("Caches/ClaudeHUD/wezterm-open.txt", "old")
        try write("Caches/Loupe/wezterm-open.txt", "new")
        let report = migrate()
        XCTAssertEqual(report.kept, ["Caches/ClaudeHUD"])
        XCTAssertEqual(read("Caches/Loupe/wezterm-open.txt"), "new")
        XCTAssertEqual(read("Caches/ClaudeHUD/wezterm-open.txt"), "old")
    }

    func testAnEmptyNewFolderIsReplaced() throws {
        try write("Application Support/ClaudeHUD/transcript-index.sqlite", "index")
        try fm.createDirectory(at: library.appendingPathComponent("Application Support/Loupe"), withIntermediateDirectories: true)
        XCTAssertEqual(migrate().moved, ["Application Support/ClaudeHUD"])
        XCTAssertEqual(read("Application Support/Loupe/transcript-index.sqlite"), "index")
    }

    func testImportsTheOldDefaultsOnceWithoutOverwriting() {
        defaults.setPersistentDomain(["hiddenTabs": "agents", "calendar.excludedIDs": ["A", "B"],
                                      "com.claudehud.vault.migrated.v1": true, "shared": "old"],
                                     forName: oldDomain)
        defaults.setPersistentDomain(["shared": "new"], forName: newDomain)

        XCTAssertEqual(migrate().importedKeys, 3)
        let domain = defaults.persistentDomain(forName: newDomain) ?? [:]
        XCTAssertEqual(domain["hiddenTabs"] as? String, "agents")
        XCTAssertEqual(domain["calendar.excludedIDs"] as? [String], ["A", "B"])
        XCTAssertEqual(domain["com.claudehud.vault.migrated.v1"] as? Bool, true)
        XCTAssertEqual(domain["shared"] as? String, "new")
        XCTAssertEqual(domain[DataMigration.importedKey] as? Bool, true)
        // The old domain is left as it was.
        XCTAssertEqual(defaults.persistentDomain(forName: oldDomain)?["shared"] as? String, "old")

        // Once: a key added to the old domain later is not copied.
        defaults.setPersistentDomain(["late": 1], forName: oldDomain)
        XCTAssertEqual(migrate().importedKeys, 0)
        XCTAssertNil(defaults.persistentDomain(forName: newDomain)?["late"])
    }

    func testNoOldDomainMarksTheImportDone() {
        XCTAssertEqual(migrate().importedKeys, 0)
        XCTAssertEqual(defaults.persistentDomain(forName: newDomain)?[DataMigration.importedKey] as? Bool, true)
    }
}
