import Foundation

/// A single (identifier, confidence) pair as returned by ClassifyImageRequest.
public struct SceneObservation: Codable, Sendable, Equatable {
    public let identifier: String
    public let confidence: Float
    public init(identifier: String, confidence: Float) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

public enum TimestampSource: String, Codable, Sendable {
    case filename
    case mtime
}

/// One record per extracted image. `sceneRaw` is persisted unfiltered; the
/// derived `scenes` projection is computed by SceneFilter at read time so
/// filter constants can change without re-extracting 1,494 images.
public struct IndexRecord: Codable, Sendable {
    public let file: String
    public let ts: String
    public let tsSource: TimestampSource
    /// Modification time and byte size. Together with `file` these form the
    /// resume key the spec specifies (path + mtime + size). They are also the
    /// two values the undo/mtime invariant is stated in terms of, so storing
    /// them is what makes that invariant checkable rather than rhetorical.
    public let mtime: Double
    public let size: Int
    public let ocr: String
    public let chars: Int
    public let blocks: Int
    public let density: Double
    public let sceneRaw: [SceneObservation]
    public let faces: Int
    public let faceAreaMax: Double
    public let domains: [String]
    public let error: String?

    /// `mtime` and `size` default so test fixtures need not supply them;
    /// Extractor always does.
    public init(file: String, ts: String, tsSource: TimestampSource,
                mtime: Double = 0, size: Int = 0,
                ocr: String, chars: Int, blocks: Int, density: Double,
                sceneRaw: [SceneObservation], faces: Int, faceAreaMax: Double,
                domains: [String], error: String?) {
        self.file = file; self.ts = ts; self.tsSource = tsSource
        self.mtime = mtime; self.size = size
        self.ocr = ocr; self.chars = chars; self.blocks = blocks
        self.density = density; self.sceneRaw = sceneRaw
        self.faces = faces; self.faceAreaMax = faceAreaMax
        self.domains = domains; self.error = error
    }

    /// Single source for the resume key. `ExtractRunner` builds the same key
    /// from filesystem attributes before a record exists, so both paths must
    /// come from here — if they drift, resume silently does the wrong amount
    /// of work and nothing fails.
    public static func resumeKey(file: String, mtime: Double, size: Int) -> String {
        "\(file)|\(mtime)|\(size)"
    }

    /// The resume key. Filename alone would not notice a replaced file.
    public var resumeKey: String {
        Self.resumeKey(file: file, mtime: mtime, size: size)
    }
}
