import Foundation

public enum Timestamp {
    // Regex<Output> does NOT conform to Sendable on this toolchain (Swift
    // 6.3.1 / swiftlang-6.3.1.1.2), even though Output here is a tuple of
    // Substring. `swift build -Xswiftc -strict-concurrency=complete` fails
    // with:
    //   error: static property 'pattern' is not concurrency-safe because
    //   non-'Sendable' type 'Regex<(Substring, Substring, Substring,
    //   Substring, Substring, Substring, Substring)>' may have shared
    //   mutable state [#MutableGlobalVariable]
    //   note: generic struct 'Regex' does not conform to the 'Sendable'
    //   protocol
    // Computed, not stored: Regex is not Sendable on this toolchain, and
    // extract matches from 8 concurrent tasks. A fresh value per access
    // removes the race by construction rather than by annotation.
    private static var pattern: Regex<(Substring, Substring, Substring, Substring, Substring, Substring, Substring)> {
        /Screenshot_(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/
    }

    // extract runs Timestamp.parse from inside a withTaskGroup of 8 concurrent
    // extractions, so this must be safe to touch from multiple threads at
    // once. Date.ISO8601FormatStyle is a Sendable value type, so each call
    // gets its own copy and there is no shared mutable state to race on —
    // the race is removed by construction, not by an unsafe annotation.
    private static let iso = Date.ISO8601FormatStyle()

    /// All 1,494 current files match the pattern, but future input must not be
    /// assumed to. `source` records which path was taken so a reader can tell
    /// a real capture time from an inferred one.
    public static func parse(filename: String,
                             mtime: Date) -> (ts: String, source: TimestampSource) {
        if let m = filename.firstMatch(of: pattern) {
            return ("\(m.1)-\(m.2)-\(m.3)T\(m.4):\(m.5):\(m.6)", .filename)
        }
        return (iso.format(mtime), .mtime)
    }
}
