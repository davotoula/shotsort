import Foundation

/// One record per classified image. `modelConfidence` is advisory only —
/// nothing branches on it. A small on-device model's self-reported confidence
/// clusters at 0.8-0.9 nearly regardless of evidence, so a threshold on it
/// would never fire while reading as a safety mechanism.
public struct LabelRecord: Codable, Sendable {
    public let file: String
    public let category: String
    /// "model", "no-signal", "guardrail", "schema-miss", or "model-unavailable".
    /// Distinct values matter: the smoke run reads this histogram as its
    /// diagnostic, so a wiring fault must not be indistinguishable from a
    /// model refusal.
    public let reason: String
    public let modelConfidence: Double?
    public let filterVersion: Int
    /// Digest of the taxonomy this label was produced against. `classify`
    /// treats a label whose signature differs from the current taxonomy as
    /// stale and reclassifies it.
    public let taxonomySignature: String
    /// Populated only when classify ran with --verify.
    public let verifyAgreed: Bool?
    /// The category the `--verify` re-ask returned, when it ran. Kept
    /// alongside `verifyAgreed` because the boolean alone cannot distinguish
    /// adjacent disagreement (an overlapping taxonomy) from wild disagreement
    /// (an unstable model), and those have opposite remedies.
    public let verifyAlternate: String?

    public init(file: String, category: String, reason: String,
                modelConfidence: Double?, filterVersion: Int,
                taxonomySignature: String = "",
                verifyAgreed: Bool?,
                verifyAlternate: String? = nil) {
        self.file = file; self.category = category; self.reason = reason
        self.modelConfidence = modelConfidence
        self.filterVersion = filterVersion
        self.taxonomySignature = taxonomySignature
        self.verifyAgreed = verifyAgreed
        self.verifyAlternate = verifyAlternate
    }
}
