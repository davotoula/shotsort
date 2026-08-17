import Foundation

/// Resolves every path the tool reads or writes.
/// Inbox holds unsorted screenshots; output holds category folders and tool state.
public struct Paths: Sendable {
    public let inbox: URL
    public let output: URL

    public init(inbox: URL, output: URL) {
        self.inbox = inbox
        self.output = output
    }

    /// Resolves the CLI's path flags. `inbox` nil → the current directory
    /// (cd into the pile and run); `output` nil → `ss-sorted` under the
    /// RESOLVED inbox, not under cwd — state travels with the collection,
    /// and with the default inbox the two coincide anyway.
    ///
    /// Relative strings resolve against the working directory via
    /// `URL(fileURLWithPath:)`. A leading `~` is expanded by Foundation
    /// itself, not only by the shell — verified: `URL(fileURLWithPath:
    /// "~/x").standardizedFileURL.path` resolves to the real home
    /// directory — so a quoted `--inbox "~/x"` works too, not just an
    /// unquoted one the shell would have expanded anyway. Both URLs
    /// are standardised because URL equality is not path equality — a URL
    /// built from "." compares ==-unequal to the cwd-derived URL for the
    /// same directory — and an unstandardised default also drags a stray
    /// `/./` into every error message.
    ///
    /// Never stats: a missing inbox must surface where it matters
    /// (extract's directory read, classify's empty index), because an
    /// existence gate here would break `apply`'s dry run against an
    /// already-emptied inbox.
    public static func resolve(inbox: String?, output: String?) -> Paths {
        let inboxURL = URL(fileURLWithPath: inbox ?? ".").standardizedFileURL
        let outputURL = output
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            // No `.standardizedFileURL` here: `inboxURL` is already
            // standardised and "ss-sorted" holds nothing to standardise.
            ?? inboxURL.appendingPathComponent("ss-sorted")
        return Paths(inbox: inboxURL, output: outputURL)
    }

    public var state: URL { output.appendingPathComponent(".shotsort") }
    public var index: URL { state.appendingPathComponent("index.jsonl") }
    public var labels: URL { state.appendingPathComponent("labels.jsonl") }
    public var manifest: URL { state.appendingPathComponent("manifest.jsonl") }
    public var taxonomy: URL { state.appendingPathComponent("taxonomy.json") }

    public func category(_ name: String) -> URL {
        output.appendingPathComponent(name)
    }

    /// Stage 1 is the first writer, so it owns creating the state directory.
    public func ensureState() throws {
        try FileManager.default.createDirectory(
            at: state, withIntermediateDirectories: true)
    }
}
