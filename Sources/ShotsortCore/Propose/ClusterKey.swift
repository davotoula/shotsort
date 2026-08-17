import Foundation

/// Deterministic clustering key. Every dimension must be total — an undefined
/// value for the majority of records would make the cluster structure, and
/// the bounds that rest on it, meaningless.
public struct ClusterKey: Hashable, Sendable {
    public let domain: String
    public let topScene: String
    public let faceBand: String
    public let densityBand: String

    public static func of(_ r: IndexRecord) -> ClusterKey {
        // SceneFilter already orders lexicographically within a confidence
        // group, so "first" is stable across runs.
        let scenes = SceneFilter.scenes(from: r.sceneRaw)

        // Thresholds live in FaceBand only — see the single-source note there.
        let face = FaceBand.of(faceAreaMax: r.faceAreaMax).rawValue

        let density: String
        switch r.density {
        case ..<0.02: density = "none"
        case ..<0.15: density = "sparse"
        default: density = "dense"
        }

        return ClusterKey(domain: r.domains.first ?? "none",
                          topScene: scenes.first ?? "none",
                          faceBand: face,
                          densityBand: density)
    }

    /// Used to stratify the long-tail bucket: everything except the scene
    /// dimension, which is absent for most of the collection.
    public var longTailKey: String { "\(domain)|\(faceBand)|\(densityBand)" }
}
