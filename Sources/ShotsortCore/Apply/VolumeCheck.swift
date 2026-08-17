import Foundation

public enum VolumeCheck {
    /// Resolves a URL to its volume identifier, walking up to the nearest
    /// existing ancestor because the output tree may not exist on a first run.
    /// The walk always terminates at "/", which always exists.
    public static func defaultVolumeID(_ url: URL) throws -> AnyHashable? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path),
              probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        // volumeIdentifier is typed
        // (any NSCopying & NSSecureCoding & NSObjectProtocol)?, not
        // AnyHashable?, so this cast is required to compare it.
        return try probe.resourceValues(forKeys: [.volumeIdentifierKey])
            .volumeIdentifier as? AnyHashable
    }

    /// Atomicity is load-bearing throughout the design and holds only for
    /// same-volume renames. apply refuses to run across volumes rather than
    /// degrading to copy-and-unlink, which would reintroduce exactly the
    /// half-copied-file failure the design claims to have eliminated.
    ///
    /// `resolveID` is injectable so the refusal path is reachable in tests
    /// without mounting a second volume.
    public static func sameVolume(
        _ a: URL, _ b: URL,
        resolveID: (URL) throws -> AnyHashable? = defaultVolumeID
    ) throws -> Bool {
        // An unknown identifier must REFUSE, not default to "same". Two nils
        // comparing equal would let a cross-volume move proceed on exactly
        // the evidence that should stop it.
        guard let x = try resolveID(a), let y = try resolveID(b) else {
            return false
        }
        return x == y
    }
}
