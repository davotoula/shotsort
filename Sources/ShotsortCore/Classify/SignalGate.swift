import Foundation

/// A deterministic precondition applied before the model is consulted.
///
/// Self-reported confidence is not usable as a gate: a small on-device model's
/// confidence clusters at 0.8-0.9 nearly regardless of evidence, so a numeric
/// threshold would never fire while reading as a safety mechanism. This gate
/// is structural instead, and costs no inference time.
public enum SignalGate {
    public static let minChars = 12

    public static func hasNoSignal(_ r: IndexRecord) -> Bool {
        // Face thresholds come from FaceBand, not a local constant, so the
        // gate cannot drift from what the proposer and classifier are shown.
        r.chars < minChars
            && r.domains.isEmpty
            && !FaceBand.of(faceAreaMax: r.faceAreaMax).isUsableSignal
            && SceneFilter.scenes(from: r.sceneRaw).isEmpty
    }
}
