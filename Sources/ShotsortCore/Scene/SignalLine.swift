import Foundation

/// The compact evidence header shown to both the proposer and the classifier.
///
/// The spec requires that "the proposer must see the same evidence the
/// classifier will later use", so there is exactly one renderer. Sampler and
/// Classifier both call this rather than formatting their own.
public enum SignalLine {
    public static func render(for r: IndexRecord) -> String {
        let scenes = SceneFilter.scenes(from: r.sceneRaw)
        let band = FaceBand.of(faceAreaMax: r.faceAreaMax)
        return "[scenes: \(scenes.isEmpty ? "—" : scenes.joined(separator: ","))"
            + " | faces: \(band.describe(count: r.faces))"
            + " | domains: \(r.domains.isEmpty ? "—" : r.domains.joined(separator: ","))]"
    }
}
