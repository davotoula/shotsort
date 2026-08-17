import Foundation

public enum SceneFilterError: Error, Equatable {
    case denylistEntryNotInVocabulary(String)
}

/// Derives the `scenes` projection from stored `sceneRaw`.
///
/// `scenes` is never persisted. Keeping raw observations in index.jsonl and
/// deriving here means the floor and denylist can be recalibrated without
/// re-extracting 1,494 images — the same principle that keeps OCR a
/// once-ever cost.
public struct SceneFilter {
    /// Bump whenever `confidenceFloor`, `genericLabels` or `groupBudget`
    /// changes. Recorded in labels.jsonl and taxonomy.json so a derived
    /// artifact can be traced to the constants that produced it.
    public static let filterVersion = 3

    public static let confidenceFloor: Float = 0.35

    /// Two observations closer than this are treated as the same concept
    /// level. Derived from measurement, not chosen: on the real collection,
    /// sibling identifiers land anywhere from bit-equal to ~4e-5 apart, and
    /// genuinely distinct concepts in the sample were separated by far more.
    public static let confidenceEpsilon: Float = 0.005

    /// Identifiers true of nearly every screenshot, carrying no discriminating
    /// information. Every entry must exist in ClassifyImageRequest's
    /// supportedIdentifiers — enforced by validateDenylist.
    ///
    /// "text", "paper", "pattern" and "monochrome" are NOT members of the
    /// 1,303-identifier vocabulary and must never be added here.
    public static let genericLabels: Set<String> = [
        "screenshot", "document", "material",
    ]

    public static let groupBudget = 5

    /// Exact identifier equality, case-insensitive. Never substring or prefix:
    /// a "paper" entry would otherwise match "newspaper".
    private static func isGeneric(_ identifier: String) -> Bool {
        genericLabels.contains(identifier.lowercased())
    }

    public static func scenes(from raw: [SceneObservation]) -> [String] {
        let kept = raw
            .filter { $0.confidence >= confidenceFloor }
            .filter { !isGeneric($0.identifier) }

        // Group by confidence PROXIMITY, not exact equality. Vision returns
        // parent and child identifiers at near-identical confidence, but only
        // sometimes bit-identical: measured over 59 adjacent pairs on the real
        // collection, 9 were bit-equal and 23 more were within 0.005. The same
        // people/adult pair came back bit-equal on one image and 4e-5 apart on
        // another, so exact equality is not merely strict — it is unstable
        // across images for the same concept pair, and would silently degrade
        // the group budget into a plain top-5.
        //
        // Single-linkage over the descending list: a gap smaller than epsilon
        // continues the current group.
        let sorted = kept.sorted { $0.confidence > $1.confidence }
        var groups: [[String]] = []
        var current: [String] = []
        var previous: Float?

        for o in sorted {
            if let p = previous, (p - o.confidence) >= confidenceEpsilon {
                groups.append(current)
                current = []
            }
            current.append(o.identifier)
            previous = o.confidence
        }
        if !current.isEmpty { groups.append(current) }

        // Lexicographic within a group: Vision's ordering among equal
        // confidences is not documented as stable.
        return groups.prefix(groupBudget).flatMap { $0.sorted() }
    }

    public static func validateDenylist(against supported: [String]) throws {
        let vocabulary = Set(supported.map { $0.lowercased() })
        for entry in genericLabels.sorted() where !vocabulary.contains(entry) {
            throw SceneFilterError.denylistEntryNotInVocabulary(entry)
        }
    }
}
