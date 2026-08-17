import Foundation

public enum ApplyError: Error, Equatable {
    case differentVolumes
}

public enum PlanAction: String, Equatable, Sendable {
    case move
    case alreadyDone
    case completeInterrupted
    case recategorise
    case error
}

public struct PlanRow: Equatable, Sendable {
    public let file: String
    public let category: String
    public let action: PlanAction
    public init(file: String, category: String, action: PlanAction) {
        self.file = file; self.category = category; self.action = action
    }
}

/// Moves files and maintains the manifest. Knows nothing about Vision or
/// FoundationModels — it consumes labels and produces filesystem changes.
public struct Applier {
    private let paths: Paths
    private let manifestStore: JSONLStore<ManifestRecord>

    public init(paths: Paths) {
        self.paths = paths
        self.manifestStore = JSONLStore<ManifestRecord>(url: paths.manifest)
    }

    private func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Net state is only a claim about what should have happened. Because a
    /// record is appended before the rename, the claim can outrun reality —
    /// so it is used only to locate the file, and the filesystem decides.
    private func resolve(_ label: LabelRecord, net: NetState) -> PlanAction {
        let source = paths.inbox.appendingPathComponent(label.file)
        let dest = paths.category(label.category).appendingPathComponent(label.file)

        switch net.location(of: label.file) {
        case .inbox:
            if exists(source) { return .move }
            // A revert was logged but never performed, or something outside
            // the tool moved it. If it is already where we want it, done.
            if exists(dest) { return .alreadyDone }
            return .error

        case .at(let claimed):
            let claimedURL = URL(fileURLWithPath: claimed)
            if claimedURL.path == dest.path {
                if !exists(source) && exists(dest) { return .alreadyDone }
                // Write-ahead crash: record written, rename never ran.
                if exists(source) && !exists(dest) { return .completeInterrupted }
                if exists(source) && exists(dest) { return .error }   // collision
                return .error                                          // vanished
            }
            // Claimed at a different category: re-categorise from where it is.
            if exists(claimedURL) { return .recategorise }
            if exists(source) { return .move }
            return .error
        }
    }

    public func plan(labels: [LabelRecord]) throws -> [PlanRow] {
        let net = NetState(records: try manifestStore.readAll())
        return labels.map {
            PlanRow(file: $0.file, category: $0.category,
                    action: resolve($0, net: net))
        }
    }

    public func commit(labels: [LabelRecord]) throws -> [PlanRow] {
        guard try VolumeCheck.sameVolume(paths.inbox, paths.output) else {
            throw ApplyError.differentVolumes
        }
        let net = NetState(records: try manifestStore.readAll())
        var rows: [PlanRow] = []

        for label in labels {
            let action = resolve(label, net: net)
            let dest = paths.category(label.category)
                .appendingPathComponent(label.file)

            switch action {
            case .move, .recategorise:
                var from = paths.inbox.appendingPathComponent(label.file)
                if case .at(let claimed) = net.location(of: label.file),
                   exists(URL(fileURLWithPath: claimed)) {
                    from = URL(fileURLWithPath: claimed)
                }
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                // Write-ahead: log the intent, then rename. A crash between
                // the two is recoverable; the reverse order would leave
                // moved-but-unlogged orphans undo could never find.
                try manifestStore.append(ManifestRecord(
                    op: .move, file: label.file, from: from.path,
                    to: dest.path, at: now()))
                try FileManager.default.moveItem(at: from, to: dest)

            case .completeInterrupted:
                try FileManager.default.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                // The existing record becomes true once the rename lands,
                // so no second record is appended.
                try FileManager.default.moveItem(
                    at: paths.inbox.appendingPathComponent(label.file), to: dest)

            case .alreadyDone, .error:
                break
            }
            rows.append(PlanRow(file: label.file, category: label.category,
                                action: action))
        }
        return rows
    }

    /// Returns the number of files actually returned to the inbox.
    @discardableResult
    public func undo() throws -> Int {
        let records = try manifestStore.readAll()
        let net = NetState(records: records)
        var restored = 0

        for file in Set(records.map(\.file)).sorted() {
            guard case .at(let claimed) = net.location(of: file) else { continue }
            let current = URL(fileURLWithPath: claimed)
            let target = paths.inbox.appendingPathComponent(file)

            // Skip and report rather than overwrite. A record is written only
            // for a move the tool is about to perform and will verify —
            // logging a revert that did not happen would make net state claim
            // the file is in the inbox when it is not.
            guard exists(current), !exists(target) else { continue }

            try manifestStore.append(ManifestRecord(
                op: .revert, file: file, from: current.path,
                to: target.path, at: now()))
            try FileManager.default.moveItem(at: current, to: target)
            restored += 1
        }
        return restored
    }
}
