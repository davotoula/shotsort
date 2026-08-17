import Foundation
import CryptoKit

public struct Category: Codable, Sendable, Equatable {
    public let name: String
    public let desc: String
    public let examples: [String]
    public init(name: String, desc: String, examples: [String]) {
        self.name = name; self.desc = desc; self.examples = examples
    }
}

public struct Taxonomy: Codable, Sendable {
    public let version: Int
    /// Which SceneFilter constants produced the scenes this taxonomy was
    /// derived from. Also recorded on every LabelRecord, so a mismatch
    /// between the two is detectable from the artifacts alone.
    public let filterVersion: Int
    public let categories: [Category]

    public init(version: Int, filterVersion: Int, categories: [Category]) {
        self.version = version
        self.filterVersion = filterVersion
        self.categories = categories
    }

    public var names: [String] { categories.map(\.name) }

    /// A stable digest of the category set, recorded on every LabelRecord.
    /// `classify` compares it to decide whether existing labels are still
    /// valid, which is what makes the undo -> edit taxonomy -> classify ->
    /// apply loop actually reclassify instead of replaying stale answers.
    ///
    /// Deliberately NOT Swift's `hashValue`: `Hasher` is seeded per process,
    /// so a persisted value would differ on every run and invalidate all
    /// labels every time. SHA-256 over the sorted names is stable across
    /// processes and OS versions.
    public var signature: String {
        let joined = names.sorted().joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The category every fallback path routes to. Never removable.
    public static let unsortedName = "Unsorted"
}
