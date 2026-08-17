import Foundation

public enum TaxonomyError: Error, Equatable {
    /// name, reason
    case invalidName(String, String)
    /// the two names that resolve to one directory
    case collision(String, String)
    case missingUnsorted
    case empty
}

public struct TaxonomyStore {
    public static let maxNameLength = 64

    /// Rejects; never rewrites. Silently sanitising a name would make the
    /// name recorded in manifest.jsonl diverge from taxonomy.json, so undo
    /// and reclassification would disagree about what a category is called.
    public static func validate(_ t: Taxonomy) throws {
        guard !t.categories.isEmpty else { throw TaxonomyError.empty }

        for c in t.categories {
            if let reason = rejection(for: c.name) {
                throw TaxonomyError.invalidName(c.name, reason)
            }
        }

        // APFS is both case-insensitive and normalisation-insensitive by
        // default, so two distinct taxonomy entries can be one directory.
        var seen: [String: String] = [:]
        for c in t.categories {
            let key = folded(c.name)
            if let prior = seen[key] {
                throw TaxonomyError.collision(prior, c.name)
            }
            seen[key] = c.name
        }

        guard t.names.contains(Taxonomy.unsortedName) else {
            throw TaxonomyError.missingUnsorted
        }
    }

    /// Why this name is unusable as a path component, or nil if it is fine.
    /// Exposed separately from `validate` so `Proposer` can drop bad model
    /// output rather than losing a whole ~12-call stage to one stray name.
    public static func rejection(for n: String) -> String? {
        if n.isEmpty { return "empty" }
        if n.trimmingCharacters(in: .whitespaces).isEmpty { return "whitespace only" }
        if n != n.trimmingCharacters(in: .whitespaces) {
            return "leading or trailing whitespace"
        }
        if n.contains("/") || n.contains(":") { return "contains a path separator" }
        if n.hasPrefix(".") { return "begins with a dot" }
        if n == ".shotsort" { return "reserved for tool state" }
        if n.count > maxNameLength { return "exceeds \(maxNameLength) characters" }
        if n.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) { return "contains control characters" }
        return nil
    }

    public static func isValidName(_ n: String) -> Bool { rejection(for: n) == nil }

    /// The comparison APFS effectively performs on filenames.
    public static func folded(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: nil)
    }

    public static func load(from url: URL) throws -> Taxonomy {
        let t = try JSONDecoder().decode(Taxonomy.self, from: Data(contentsOf: url))
        try validate(t)
        return t
    }

    public static func save(_ t: Taxonomy, to url: URL) throws {
        try validate(t)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys,
                                    .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(t).write(to: url, options: .atomic)
    }
}
