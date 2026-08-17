import Foundation
import FoundationModels

public enum ModelAvailabilityError: Error {
    case unavailable(String)
}

public enum ModelAvailability {
    /// Checked at startup by propose and classify, never partway through a
    /// long run: a 40-minute stage must not die at image 900 for a reason
    /// that was knowable at second zero.
    public static func check() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            let detail: String
            switch reason {
            case .deviceNotEligible:
                detail = "this device is not eligible for Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                detail = "Apple Intelligence is not enabled in System Settings"
            case .modelNotReady:
                detail = "the on-device model is still downloading"
            @unknown default:
                detail = "unavailable for an unrecognised reason"
            }
            throw ModelAvailabilityError.unavailable(detail)
        @unknown default:
            throw ModelAvailabilityError.unavailable("unrecognised availability state")
        }
    }
}
