import Foundation

/// What kind of shared evidence formed a group. The runner treats their
/// verdicts differently: a domain is a real source, so its Unsorted is a
/// real judgment; a scene cluster is weaker, so its Unsorted means the
/// grouping failed and members deserve individual answers. Measured on the
/// real index: 19 scene groups stamped 173 records Unsorted wholesale while
/// per-image had sorted 164 of them.
public enum GroupKind: Sendable, Equatable {
    case domain
    case scene
}

/// Records believed to come from one source, classified once — the answer is
/// stamped on every member. `evidence` is human-readable and appears
/// verbatim in the group prompt.
public struct ClassifyGroup: Sendable, Equatable {
    public let evidence: String
    public let kind: GroupKind
    public let members: [IndexRecord]
    public init(evidence: String, kind: GroupKind, members: [IndexRecord]) {
        self.evidence = evidence
        self.kind = kind
        self.members = members
    }

    /// Equality compares evidence, kind and member file identities, not member
    /// content. `file` is the codebase's de facto primary key; `IndexRecord`
    /// is not `Equatable`, so members are compared by filename to avoid
    /// false-pass tests that might rely on wrong content carrying correct
    /// file names.
    public static func == (lhs: ClassifyGroup, rhs: ClassifyGroup) -> Bool {
        lhs.evidence == rhs.evidence
            && lhs.kind == rhs.kind
            && lhs.members.map(\.file) == rhs.members.map(\.file)
    }
}

/// Splits the index into groups (one model call each) and singles (the
/// per-image path). Pure and deterministic.
///
/// Grouping by full ClusterKey was measured and rejected: the domainless
/// side of the real index contains a single 375-record
/// (no scene, no faces, sparse) cluster — a junk drawer, not a source. Only
/// shared POSITIVE evidence forms a group: a domain, or a named scene.
public enum GroupPlanner {
    /// Two screenshots from one domain are already a source.
    public static let domainFloor = 2
    /// A scene cluster is weaker evidence than a domain; it needs more
    /// mutual support before one answer may cover it.
    public static let sceneFloor = 3

    public static func plan(_ records: [IndexRecord])
        -> (groups: [ClassifyGroup], singles: [IndexRecord]) {
        var groups: [ClassifyGroup] = []
        var singles: [IndexRecord] = []

        // No-signal records never join a group: nothing about them can make
        // them "the same source" as anything, and the per-image path files
        // them as Unsorted without a model call.
        var groupable: [IndexRecord] = []
        for r in records {
            if SignalGate.hasNoSignal(r) { singles.append(r) }
            else { groupable.append(r) }
        }

        // Tier 1: shared first domain — the same choice ClusterKey.of makes.
        var byDomain: [String: [IndexRecord]] = [:]
        var domainless: [IndexRecord] = []
        for r in groupable {
            if let d = r.domains.first { byDomain[d, default: []].append(r) }
            else { domainless.append(r) }
        }
        for (domain, members) in byDomain.sorted(by: { $0.key < $1.key }) {
            if members.count >= domainFloor {
                groups.append(ClassifyGroup(
                    evidence: "domain \(domain)", kind: .domain,
                    members: members.sorted { $0.file < $1.file }))
            } else {
                singles.append(contentsOf: members)
            }
        }

        // Tier 2: domainless records sharing a named scene plus face and
        // density bands. topScene == "none" is the absence of evidence, not
        // shared evidence — those records are unrelated by construction.
        var byScene: [String: [IndexRecord]] = [:]
        for r in domainless {
            let key = ClusterKey.of(r)
            if key.topScene == "none" {
                singles.append(r)
            } else {
                byScene["\(key.topScene)|\(key.faceBand)|\(key.densityBand)",
                        default: []].append(r)
            }
        }
        for (bucket, members) in byScene.sorted(by: { $0.key < $1.key }) {
            if members.count >= sceneFloor {
                let parts = bucket.split(separator: "|")
                groups.append(ClassifyGroup(
                    evidence: "scene \(parts[0]), faces \(parts[1]), text \(parts[2])",
                    kind: .scene,
                    members: members.sorted { $0.file < $1.file }))
            } else {
                singles.append(contentsOf: members)
            }
        }

        // Never rely on dictionary iteration order anywhere above; sort the
        // spill here so singles are stable too.
        singles.sort { $0.file < $1.file }
        return (groups, singles)
    }
}
