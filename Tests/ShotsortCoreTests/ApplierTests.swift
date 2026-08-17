import Testing
import Foundation
@testable import ShotsortCore

private struct Bed {
    let root: URL
    let paths: Paths

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        paths = Paths(inbox: root.appendingPathComponent("ss"),
                      output: root.appendingPathComponent("ss-sorted"))
        try FileManager.default.createDirectory(at: paths.inbox,
                                                withIntermediateDirectories: true)
        try paths.ensureState()
    }

    func makeInboxFile(_ name: String) throws {
        try Data("png".utf8).write(to: paths.inbox.appendingPathComponent(name))
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func label(_ file: String, _ category: String) -> LabelRecord {
    LabelRecord(file: file, category: category, reason: "model",
                modelConfidence: 0.9, filterVersion: 3, verifyAgreed: nil)
}

@Test func planDoesNotTouchTheFilesystem() throws {
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.makeInboxFile("a.png")
    let rows = try Applier(paths: bed.paths).plan(labels: [label("a.png", "News")])
    #expect(rows == [PlanRow(file: "a.png", category: "News", action: .move)])
    #expect(bed.exists(bed.paths.inbox.appendingPathComponent("a.png")))
    #expect(!bed.exists(bed.paths.category("News").appendingPathComponent("a.png")))
}

@Test func commitMovesTheFileAndLogsIt() throws {
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.makeInboxFile("a.png")
    _ = try Applier(paths: bed.paths).commit(labels: [label("a.png", "News")])
    #expect(!bed.exists(bed.paths.inbox.appendingPathComponent("a.png")))
    #expect(bed.exists(bed.paths.category("News").appendingPathComponent("a.png")))
    let log = try JSONLStore<ManifestRecord>(url: bed.paths.manifest).readAll()
    #expect(log.count == 1)
    #expect(log[0].op == .move)
}

@Test func reApplyIsIdempotent() throws {
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.makeInboxFile("a.png")
    let applier = Applier(paths: bed.paths)
    _ = try applier.commit(labels: [label("a.png", "News")])
    let second = try applier.commit(labels: [label("a.png", "News")])
    #expect(second == [PlanRow(file: "a.png", category: "News", action: .alreadyDone)])
    #expect(try JSONLStore<ManifestRecord>(url: bed.paths.manifest).readAll().count == 1)
}

@Test func writeAheadCrashIsCompletedOnReRun() throws {
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.makeInboxFile("a.png")
    // Simulate a crash between appending the record and performing the
    // rename: the record exists, the file is still in the inbox.
    let dest = bed.paths.category("News").appendingPathComponent("a.png")
    try JSONLStore<ManifestRecord>(url: bed.paths.manifest).append(
        ManifestRecord(op: .move, file: "a.png",
                       from: bed.paths.inbox.appendingPathComponent("a.png").path,
                       to: dest.path, at: "t"))

    let rows = try Applier(paths: bed.paths).commit(labels: [label("a.png", "News")])
    #expect(rows == [PlanRow(file: "a.png", category: "News",
                             action: .completeInterrupted)])
    #expect(bed.exists(dest))
    // The existing record became true; no second record is appended.
    #expect(try JSONLStore<ManifestRecord>(url: bed.paths.manifest).readAll().count == 1)
}

@Test func vanishedFileIsAGenuineError() throws {
    let bed = try Bed(); defer { bed.cleanup() }
    let dest = bed.paths.category("News").appendingPathComponent("a.png")
    try JSONLStore<ManifestRecord>(url: bed.paths.manifest).append(
        ManifestRecord(op: .move, file: "a.png",
                       from: bed.paths.inbox.appendingPathComponent("a.png").path,
                       to: dest.path, at: "t"))
    let rows = try Applier(paths: bed.paths).commit(labels: [label("a.png", "News")])
    #expect(rows[0].action == .error)
}

@Test func applyUndoApplyMovesTheFilesAgain() throws {
    // The regression test for the net-state predicate. Under a naive
    // "present in manifest" rule every other assertion here still passes
    // while the reclassify loop is silently dead.
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.makeInboxFile("a.png")
    let applier = Applier(paths: bed.paths)

    _ = try applier.commit(labels: [label("a.png", "News")])
    #expect(try applier.undo() == 1)
    #expect(bed.exists(bed.paths.inbox.appendingPathComponent("a.png")))

    let rows = try applier.commit(labels: [label("a.png", "Travel")])
    #expect(rows == [PlanRow(file: "a.png", category: "Travel", action: .move)])
    #expect(bed.exists(bed.paths.category("Travel").appendingPathComponent("a.png")))
}

@Test func recategoriseMovesFromWhereTheFileActuallyIs() throws {
    // A taxonomy edit WITHOUT a prior undo. Net state says News, the label
    // says Travel, and the file physically sits in News. This is the only
    // branch where the source path is computed rather than assumed, and it
    // became the primary path once labels started being invalidated by a
    // taxonomy change — before that it was nearly unreachable.
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.makeInboxFile("a.png")
    let applier = Applier(paths: bed.paths)
    _ = try applier.commit(labels: [label("a.png", "News")])

    let rows = try applier.commit(labels: [label("a.png", "Travel")])
    #expect(rows == [PlanRow(file: "a.png", category: "Travel",
                             action: .recategorise)])
    #expect(bed.exists(bed.paths.category("Travel").appendingPathComponent("a.png")))
    #expect(!bed.exists(bed.paths.category("News").appendingPathComponent("a.png")))
    // Moved from News, not from the inbox it was never in.
    let log = try JSONLStore<ManifestRecord>(url: bed.paths.manifest).readAll()
    #expect(log.count == 2)
    #expect(log[1].from.contains("/News/"))
    #expect(log[1].to.contains("/Travel/"))
}

@Test func recategoriseIsUndoableBackToTheInbox() throws {
    // Net state after a re-categorisation must still resolve to the current
    // location, or undo would try to restore from the vacated folder.
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.makeInboxFile("a.png")
    let applier = Applier(paths: bed.paths)
    _ = try applier.commit(labels: [label("a.png", "News")])
    _ = try applier.commit(labels: [label("a.png", "Travel")])
    #expect(try applier.undo() == 1)
    #expect(bed.exists(bed.paths.inbox.appendingPathComponent("a.png")))
}

@Test func undoRoundTripPreservesPathsAndMtimes() throws {
    // rename(2) preserves mtime, and the index key is path + mtime + size.
    // That invariant is what keeps index.jsonl valid across the reclassify loop.
    let bed = try Bed(); defer { bed.cleanup() }
    for n in ["a.png", "b.png", "c.png"] { try bed.makeInboxFile(n) }

    func snapshot() throws -> [String: Date] {
        var out: [String: Date] = [:]
        for n in try FileManager.default.contentsOfDirectory(atPath: bed.paths.inbox.path) {
            let attrs = try FileManager.default.attributesOfItem(
                atPath: bed.paths.inbox.appendingPathComponent(n).path)
            out[n] = attrs[.modificationDate] as? Date
        }
        return out
    }

    let before = try snapshot()
    let applier = Applier(paths: bed.paths)
    _ = try applier.commit(labels: [label("a.png", "News"),
                                    label("b.png", "Travel"),
                                    label("c.png", "Unsorted")])
    _ = try applier.undo()
    #expect(try snapshot() == before)
}

@Test func undoAppendsNoRevertRecordForASkippedFile() throws {
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.makeInboxFile("a.png")
    let applier = Applier(paths: bed.paths)
    _ = try applier.commit(labels: [label("a.png", "News")])

    // Something else occupies the original path: undo must skip, not clobber.
    try Data("other".utf8).write(to: bed.paths.inbox.appendingPathComponent("a.png"))
    #expect(try applier.undo() == 0)

    let log = try JSONLStore<ManifestRecord>(url: bed.paths.manifest).readAll()
    // Only the original move. Recording a revert that did not happen would
    // make net state claim the file is in the inbox when it is not.
    #expect(log.count == 1)
    #expect(log[0].op == .move)
}

@Test func sameVolumeCheckPassesWithinOneVolume() throws {
    let bed = try Bed(); defer { bed.cleanup() }
    #expect(try VolumeCheck.sameVolume(bed.paths.inbox, bed.paths.output))
}

@Test func differentVolumeIdentifiersRefuse() throws {
    let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b")
    #expect(try !VolumeCheck.sameVolume(a, b) { url in
        url.lastPathComponent == "a" ? "vol-1" : "vol-2"
    })
}

@Test func anUnknownVolumeIdentifierRefusesRatherThanAssumingSame() throws {
    // Two nils compare equal; defaulting to "same" would let a cross-volume
    // move proceed on exactly the evidence that should stop it.
    let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b")
    #expect(try !VolumeCheck.sameVolume(a, b) { _ in nil })
}

@Test func identicalVolumeIdentifiersAgree() throws {
    let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b")
    #expect(try VolumeCheck.sameVolume(a, b) { _ in "vol-1" })
}

@Test func theManifestRecordIsWrittenBeforeTheRename() throws {
    // Write-ahead ordering is what makes a crash recoverable. Swapping the
    // append and the rename in commit() otherwise breaks no test.
    // Make the rename fail while everything before it succeeds: the
    // destination directory exists but is not writable.
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.makeInboxFile("a.png")
    let categoryDir = bed.paths.category("News")
    try FileManager.default.createDirectory(at: categoryDir,
                                            withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                          ofItemAtPath: categoryDir.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: categoryDir.path)
    }

    #expect(throws: (any Error).self) {
        _ = try Applier(paths: bed.paths).commit(labels: [label("a.png", "News")])
    }
    // The rename failed, but the record must already be on disk — that is
    // what lets a later run detect and complete the interrupted move.
    let log = try JSONLStore<ManifestRecord>(url: bed.paths.manifest).readAll()
    #expect(log.count == 1)
    #expect(log[0].op == .move)
    #expect(!bed.exists(categoryDir.appendingPathComponent("a.png")))
}
