import Foundation

/// The launcher's matching (Ben, 2026-11-08: "nothing but app names"): a
/// query is matched against application names only, case and diacritics
/// ignored, and ranked by how well it matches, then by how often and how
/// lately Ben opened the app, then by the shorter name.
///
/// Tiers, best first: the whole name; a prefix of the name; a prefix of a
/// later word ("code" in "Visual Studio Code"); the initials ("vsc"); a
/// substring; the letters in order with gaps ("sfr" in "Safari"). A tier is
/// worth a hundred points and recency at most 99, so recency orders apps
/// within a tier and never lifts one over a better match.
enum AppMatcher {
    /// One application as matched: its name folded once, when the index is
    /// built, so a keystroke only compares.
    struct Candidate: Hashable {
        let name: String
        let path: String
        let folded: [Character]
        /// Indices in `folded` where a word starts.
        let wordStarts: [Int]
        let initials: [Character]

        init(name: String, path: String) {
            self.name = name
            self.path = path
            var folded: [Character] = []
            var starts: [Int] = []
            var previous: Character?
            for ch in name {
                let lower = AppMatcher.fold(String(ch))
                let startsWord: Bool
                if let p = previous {
                    let boundary = !(p.isLetter || p.isNumber)
                    let camel = p.isLowercase && ch.isUppercase
                    let digitAfterLetter = p.isLetter && ch.isNumber
                    startsWord = (ch.isLetter || ch.isNumber) && (boundary || camel || digitAfterLetter)
                } else {
                    startsWord = ch.isLetter || ch.isNumber
                }
                if startsWord && !lower.isEmpty { starts.append(folded.count) }
                folded.append(contentsOf: lower)
                previous = ch
            }
            self.folded = folded
            self.wordStarts = starts
            self.initials = starts.map { folded[$0] }
        }
    }

    static func fold(_ s: String) -> [Character] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased())
    }

    enum Tier: Int, Comparable {
        case subsequence = 3, substring = 6, initials = 7, wordPrefix = 8, prefix = 9, exact = 10
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    /// How `query` (already folded, not empty) matches `c`, or nil.
    static func tier(_ query: [Character], _ c: Candidate) -> Tier? {
        let name = c.folded
        guard !query.isEmpty, query.count <= name.count else { return nil }
        if query == name { return .exact }
        if name.starts(with: query) { return .prefix }
        for start in c.wordStarts.dropFirst() where name[start...].starts(with: query) {
            return .wordPrefix
        }
        if query.count >= 2, c.initials.starts(with: query) { return .initials }
        if contains(name, query) { return .substring }
        var i = 0
        for ch in name where ch == query[i] {
            i += 1
            if i == query.count { return .subsequence }
        }
        return nil
    }

    private static func contains(_ hay: [Character], _ needle: [Character]) -> Bool {
        guard needle.count <= hay.count else { return false }
        for start in 0...(hay.count - needle.count) where hay[start] == needle[0] {
            if hay[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }

    /// The best `limit` candidates for `query`, best first; none for a blank
    /// query. `bonus` is the recency of a candidate, 0 to 99.
    static func rank(_ query: String, in candidates: [Candidate], limit: Int = 8,
                     bonus: (Candidate) -> Int = { _ in 0 }) -> [Candidate] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        var scored: [(score: Int, c: Candidate)] = []
        scored.reserveCapacity(32)
        for c in candidates {
            guard let t = tier(q, c) else { continue }
            scored.append((t.rawValue * 100 + min(max(bonus(c), 0), 99), c))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.c.folded.count != b.c.folded.count { return a.c.folded.count < b.c.folded.count }
            return a.c.name.localizedStandardCompare(b.c.name) == .orderedAscending
        }
        return scored.prefix(limit).map(\.c)
    }
}

/// How often and how lately each app was opened from the launcher, kept in
/// UserDefaults by bundle path, as a 0 to 99 bonus for the ranking.
struct Frecency {
    struct Use: Codable, Equatable { var count: Int; var last: Date }
    static let defaultsKey = "LauncherUses"
    private(set) var uses: [String: Use]

    init(uses: [String: Use] = [:]) { self.uses = uses }

    init(defaults: UserDefaults) {
        let data = defaults.data(forKey: Self.defaultsKey)
        uses = data.flatMap { try? JSONDecoder().decode([String: Use].self, from: $0) } ?? [:]
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(uses) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    mutating func record(_ path: String, at now: Date) {
        var use = uses[path] ?? Use(count: 0, last: now)
        use.count += 1
        use.last = now
        uses[path] = use
    }

    /// log2(1 + count) * 15, so one use is 15 and 63 are 90, weighted by age:
    /// all of it within a day, 0.8 within a week, 0.5 within a month, else 0.25.
    func bonus(_ path: String, at now: Date) -> Int {
        guard let use = uses[path] else { return 0 }
        let age = now.timeIntervalSince(use.last)
        let weight: Double = age < 86_400 ? 1 : age < 7 * 86_400 ? 0.8 : age < 30 * 86_400 ? 0.5 : 0.25
        return min(99, Int((log2(1 + Double(use.count)) * 15 * weight).rounded()))
    }
}
