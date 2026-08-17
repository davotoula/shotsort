import Foundation
import Vision

/// Checks that must pass before ANY stage reads `scenes`.
///
/// Validating only in `extract` would miss the workflow the sceneRaw/derived
/// split exists to enable: recalibrate the floor or denylist, then re-run
/// propose and classify against the untouched index with no re-extraction.
/// That path would never check the denylist it had just changed. The spec
/// says "at startup", and startup of one stage out of four is not that.
///
/// Lives outside Scene/ so `SceneFilter` stays Foundation-only: it is
/// described elsewhere as a pure function over data, and importing Vision
/// there to reach `supportedIdentifiers` would quietly soften that claim.
public enum Preflight {
    public static func run() throws {
        try SceneFilter.validateDenylist(
            against: ClassifyImageRequest().supportedIdentifiers)
    }
}
