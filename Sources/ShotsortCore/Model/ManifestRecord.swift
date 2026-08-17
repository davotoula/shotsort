import Foundation

public enum ManifestOp: String, Codable, Sendable {
    case move
    case revert
}

/// The manifest is a log of what happened, not a set of what was intended.
/// `undo` appends compensating `revert` records rather than replaying
/// silently, so the file stays append-only and net state stays resolvable.
public struct ManifestRecord: Codable, Sendable {
    public let op: ManifestOp
    public let file: String
    public let from: String
    public let to: String
    public let at: String

    public init(op: ManifestOp, file: String, from: String,
                to: String, at: String) {
        self.op = op; self.file = file; self.from = from
        self.to = to; self.at = at
    }
}
