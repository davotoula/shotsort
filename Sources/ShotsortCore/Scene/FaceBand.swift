import Foundation

/// The single definition of face-area banding.
///
/// Face *count* alone is weak — feed avatars register as faces — so area is
/// what separates a video call from a timeline full of thumbnails. Every
/// consumer (clustering, the signal line, the no-signal gate) reads these
/// same thresholds; three independently-written ladders would drift.
public enum FaceBand: String, Sendable, Comparable, CaseIterable {
    /// Deliberately not named `none`: in any `FaceBand?` context `.none`
    /// resolves to `Optional.none`, which compiles and means something else.
    case absent
    case tiny
    case small
    case large

    public static func of(faceAreaMax: Double) -> FaceBand {
        switch faceAreaMax {
        case 0: return .absent
        case ..<0.05: return .tiny
        case ..<0.15: return .small
        default: return .large
        }
    }

    /// Anything at or below `.tiny` carries no usable face signal.
    public var isUsableSignal: Bool { self > .tiny }

    public func describe(count: Int) -> String {
        self == .absent ? "0" : "\(count) \(rawValue)"
    }

    public static func < (a: FaceBand, b: FaceBand) -> Bool {
        let order = FaceBand.allCases
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}
