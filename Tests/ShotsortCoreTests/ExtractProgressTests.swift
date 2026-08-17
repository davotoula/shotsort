import Testing
import Foundation
@testable import ShotsortCore

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/synthetic/\(name)")
}

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
    }
    func stage(_ name: String) throws {
        try FileManager.default.copyItem(
            at: fixture(name), to: paths.inbox.appendingPathComponent(name))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func progressIsReportedForEveryBatch() async throws {
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.stage("Screenshot_20260101-120000.png")
    try bed.stage("Screenshot_20260102-130000.png")
    try bed.stage("Screenshot_20260103-140000.png")

    var calls: [ProgressUpdate] = []
    let result = try await ExtractRunner(paths: bed.paths).run(
        concurrency: 1, onProgress: { calls.append($0) })

    #expect(result.processed == 3)
    #expect(!calls.isEmpty)
    // total is the fixed count of work discovered up front — it must not
    // change batch to batch.
    #expect(Set(calls.map(\.total)) == [3])
    // Nothing was already indexed, so the ceiling is the whole inbox.
    #expect(Set(calls.map(\.ceiling)) == [3])
    // done increases monotonically and finishes at the total.
    #expect(calls.map(\.done) == calls.map(\.done).sorted())
    #expect(calls.last?.done == 3)
}

@Test func progressIsNotReportedWhenThereIsNothingToDo() async throws {
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.stage("Screenshot_20260101-120000.png")
    _ = try await ExtractRunner(paths: bed.paths).run(concurrency: 1)

    var calls: [ProgressUpdate] = []
    let second = try await ExtractRunner(paths: bed.paths).run(
        concurrency: 1, onProgress: { calls.append($0) })

    #expect(second.processed == 0)
    // With nothing to do, `run`'s batch loop never executes, so the
    // callback never fires — it is not invoked with a spurious 0/0 either.
    #expect(calls.isEmpty)
}

@Test func aResumedRunCountsAgainstTheWholeInbox() async throws {
    // The property that makes a --supervise restart legible: the child picks
    // the bar up where its predecessor died instead of reopening at 0/1.
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.stage("Screenshot_20260101-120000.png")
    try bed.stage("Screenshot_20260102-130000.png")
    _ = try await ExtractRunner(paths: bed.paths).run(concurrency: 1)

    try bed.stage("Screenshot_20260103-140000.png")
    var calls: [ProgressUpdate] = []
    let result = try await ExtractRunner(paths: bed.paths).run(
        concurrency: 1, onProgress: { calls.append($0) })

    #expect(result.processed == 1)
    #expect(result.skipped == 2)
    // Two calls: the opening paint carrying the baseline before any image is
    // touched, then the batch. Without the opener the run shows nothing until
    // the first Vision request returns.
    #expect(calls == [ProgressUpdate(done: 2, total: 3, ceiling: 3),
                      ProgressUpdate(done: 3, total: 3, ceiling: 3)])
}

@Test func skippedCountsInboxFilesNotIndexRecords() async throws {
    // `already` is resume keys read from the index, and those outlive the
    // files: extract two, then remove one from the inbox. Reporting
    // already.count would claim 2 skipped where only 1 file remained to
    // skip — the same inflation that would put `done` above `total`.
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.stage("Screenshot_20260101-120000.png")
    try bed.stage("Screenshot_20260102-130000.png")
    _ = try await ExtractRunner(paths: bed.paths).run(concurrency: 1)

    try FileManager.default.removeItem(
        at: bed.paths.inbox.appendingPathComponent("Screenshot_20260102-130000.png"))

    let second = try await ExtractRunner(paths: bed.paths).run(concurrency: 1)
    #expect(second.processed == 0)
    #expect(second.skipped == 1)
    // The index still holds both records — that is the whole point.
    #expect(try JSONLStore<IndexRecord>(url: bed.paths.index).readAll().count == 2)
}
