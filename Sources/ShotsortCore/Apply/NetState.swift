import Foundation

public enum NetLocation: Equatable, Sendable {
    case inbox
    case at(String)
}

/// Folds the append-only manifest into each file's net location.
///
/// The manifest is a log of what happened, not a set of what was intended.
/// Resolving by "last record per file wins" is what lets undo restore
/// eligibility: after a revert the file reads as being in the inbox again.
public struct NetState: Sendable {
    private let latest: [String: ManifestRecord]

    public init(records: [ManifestRecord]) {
        var latest: [String: ManifestRecord] = [:]
        for r in records { latest[r.file] = r }
        self.latest = latest
    }

    public func location(of file: String) -> NetLocation {
        guard let r = latest[file] else { return .inbox }
        switch r.op {
        case .move: return .at(r.to)
        case .revert: return .inbox
        }
    }
}
