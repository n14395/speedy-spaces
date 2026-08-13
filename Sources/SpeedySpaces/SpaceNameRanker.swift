import Foundation

/// Shared name-match ranking for user-typed space queries: exact beats prefix beats
/// substring, and custom-named spaces beat synthesized "Desktop N" titles within a
/// tier. Used by the `--switch <name>` command router and the menu's jump field, so
/// both resolve identically. Pure — candidates injected, no domain reads.
enum SpaceNameRanker {
    /// Match tier of `title` against the normalized query `q` (lowercased, trimmed):
    /// 0 exact, 1 prefix, 2 substring, nil no match. An empty query matches everything
    /// at tier 0 (the jump field shows the full list before any typing).
    static func rank(title: String, query q: String) -> Int? {
        if q.isEmpty { return 0 }
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        if t == q { return 0 }
        if t.hasPrefix(q) { return 1 }
        if t.contains(q) { return 2 }
        return nil
    }

    /// Index of the best candidate: lowest tier wins; a custom-named space beats an
    /// unnamed one within a tier; the earliest index wins remaining ties. nil when
    /// nothing matches.
    static func bestIndex(candidates: [(title: String, named: Bool)], query raw: String) -> Int? {
        let q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        var best: (rank: Int, named: Bool, index: Int)?
        for (i, c) in candidates.enumerated() {
            guard let r = rank(title: c.title, query: q) else { continue }
            if let b = best {
                if r < b.rank || (r == b.rank && c.named && !b.named) { best = (r, c.named, i) }
            } else {
                best = (r, c.named, i)
            }
        }
        return best?.index
    }

    static func selfChecks(_ check: SelfTest.Check) {
        let list: [(title: String, named: Bool)] = [
            (title: "Desktop 1", named: false),
            (title: "Mail", named: true),
            (title: "Mailbox Cleanup", named: true),
            (title: "Desktop 4", named: false),
            (title: "mail", named: false),
        ]
        check(bestIndex(candidates: list, query: "Mail") == 1, "ranker: exact beats prefix")
        check(bestIndex(candidates: list, query: "mailb") == 2, "ranker: prefix beats substring")
        check(bestIndex(candidates: list, query: "box") == 2, "ranker: substring matches")
        check(bestIndex(candidates: list, query: "desk") == 0, "ranker: earliest wins ties")
        check(bestIndex(candidates: list, query: "MAIL") == 1, "ranker: case-insensitive")
        check(bestIndex(candidates: list, query: " mail ") == 1, "ranker: query trimmed")
        check(bestIndex(candidates: list, query: "zzz") == nil, "ranker: no match -> nil")
        check(bestIndex(candidates: [], query: "a") == nil, "ranker: empty candidates -> nil")
        check(bestIndex(candidates: list, query: "") == 1,
              "ranker: empty query matches all — first named candidate wins the tier")
        // Named-wins within a tier: an exact unnamed title loses to an exact named one.
        let tie: [(title: String, named: Bool)] = [
            (title: "Work", named: false), (title: "Work", named: true),
        ]
        check(bestIndex(candidates: tie, query: "work") == 1, "ranker: named beats unnamed in a tier")
        check(rank(title: "Desktop 2", query: "desktop 2") == 0, "ranker: rank exact")
        check(rank(title: "Desktop 2", query: "desk") == 1, "ranker: rank prefix")
        check(rank(title: "Desktop 2", query: "top") == 2, "ranker: rank substring")
        check(rank(title: "Desktop 2", query: "x") == nil, "ranker: rank none")
    }
}
