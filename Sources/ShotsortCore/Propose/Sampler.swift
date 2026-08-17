import Foundation

public enum Sampler {
    public static let keptClusters = 12
    public static let perCluster = 8
    public static let longTailSamples = 24
    public static let snippetChars = 200

    /// Caps the sample so the proposal stage is finite. The clustering signals
    /// form a cross product, so without a cap the stage would need dozens of
    /// model calls and hundreds of candidate names to consolidate.
    public static func sample(_ records: [IndexRecord]) -> [IndexRecord] {
        var clusters: [ClusterKey: [IndexRecord]] = [:]
        for r in records { clusters[ClusterKey.of(r), default: []].append(r) }

        // Rank by size; ties broken on the key so the result is deterministic.
        let ranked = clusters.sorted {
            $0.value.count != $1.value.count
                ? $0.value.count > $1.value.count
                : "\($0.key)" < "\($1.key)"
        }

        var out: [IndexRecord] = []
        for (_, members) in ranked.prefix(keptClusters) {
            out.append(contentsOf: members.sorted { $0.file < $1.file }
                .prefix(perCluster))
        }

        // The long tail carries the bulk of the no-scene population, so it is
        // stratified across the remaining dimensions rather than sampled
        // uniformly — otherwise the records the scene dimension already fails
        // to separate would be under-represented here too.
        let tail = ranked.dropFirst(keptClusters).flatMap(\.value)
        var strata: [String: [IndexRecord]] = [:]
        for r in tail { strata[ClusterKey.of(r).longTailKey, default: []].append(r) }

        let orderedStrata = strata.keys.sorted()
        var taken = 0
        var round = 0
        while taken < longTailSamples && !orderedStrata.isEmpty {
            var progressed = false
            for key in orderedStrata where taken < longTailSamples {
                let members = (strata[key] ?? []).sorted { $0.file < $1.file }
                guard round < members.count else { continue }
                out.append(members[round])
                taken += 1
                progressed = true
            }
            if !progressed { break }
            round += 1
        }
        return out
    }

    /// Delegates to the shared renderer. The spec requires the proposer to see
    /// the same evidence the classifier will later use, so this must not
    /// format its own line.
    public static func signalLine(for r: IndexRecord) -> String {
        SignalLine.render(for: r)
    }

    public static func sampleText(for r: IndexRecord) -> String {
        let snippet = r.ocr.isEmpty ? "(no text)" : String(r.ocr.prefix(snippetChars))
        return "\(signalLine(for: r)) \(snippet)"
    }
}
