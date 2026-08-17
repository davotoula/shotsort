import Foundation

/// Append-only JSONL. Every stage must survive being killed partway through,
/// so records are flushed as they are produced rather than written at the end.
public struct JSONLStore<T: Codable & Sendable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(_ record: T) throws {
        try appendAll([record])
    }

    public func appendAll(_ records: [T]) throws {
        guard !records.isEmpty else { return }
        let encoder = JSONEncoder()
        // Sorted keys make a record's bytes stable across runs, which keeps
        // the state files diffable.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var blob = Data()
        for record in records {
            var line = try encoder.encode(record)
            // JSONEncoder escapes newlines inside string values, so one
            // record is always exactly one physical line.
            line.append(0x0A)
            blob.append(line)
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try blob.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: blob)
        try handle.synchronize()
    }

    public func readAll() throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var out: [T] = []

        for (offset, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8) else {
                throw JSONLError.corruptLine(url: url, line: offset + 1)
            }
            do {
                out.append(try decoder.decode(T.self, from: data))
            } catch {
                // Tolerance is POSITIONAL, not blanket. Only the final line
                // can be a partial write from an interrupted process.
                //
                // Skipping every undecodable line would mean that adding a
                // field to a record type silently erases all prior records
                // from readAll(): extract would reprocess everything and
                // classify would skip everything, both without an error.
                guard offset == lines.count - 1 else {
                    throw JSONLError.corruptLine(url: url, line: offset + 1)
                }
            }
        }
        return out
    }
}

public enum JSONLError: Error, CustomStringConvertible {
    case corruptLine(url: URL, line: Int)

    public var description: String {
        switch self {
        case .corruptLine(let url, let line):
            return "\(url.lastPathComponent): line \(line) is not decodable. "
                + "If the record format changed, delete the file and re-run "
                + "the stage that produces it."
        }
    }
}
