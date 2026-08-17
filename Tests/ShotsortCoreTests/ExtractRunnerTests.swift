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

@Test func extractCreatesTheStateDirectoryAndIndexesEveryImage() async throws {
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.stage("Screenshot_20260101-120000.png")
    try bed.stage("Screenshot_20260102-130000.png")

    let result = try await ExtractRunner(paths: bed.paths).run(concurrency: 2)
    #expect(result.processed == 2)
    #expect(result.skipped == 0)
    #expect(FileManager.default.fileExists(atPath: bed.paths.state.path))
    #expect(try JSONLStore<IndexRecord>(url: bed.paths.index).readAll().count == 2)
}

@Test func aSecondRunSkipsEverythingAlreadyIndexed() async throws {
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.stage("Screenshot_20260101-120000.png")
    _ = try await ExtractRunner(paths: bed.paths).run(concurrency: 2)

    let second = try await ExtractRunner(paths: bed.paths).run(concurrency: 2)
    #expect(second.processed == 0)
    // The index is not appended to a second time.
    #expect(try JSONLStore<IndexRecord>(url: bed.paths.index).readAll().count == 1)
}

@Test func aReplacedFileWithTheSameNameIsReExtracted() async throws {
    // The resume key is path + mtime + size, not filename alone. Keying on
    // the name would silently skip a file whose contents changed.
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.stage("Screenshot_20260101-120000.png")
    _ = try await ExtractRunner(paths: bed.paths).run(concurrency: 2)

    // Replace with different content, keeping the name.
    let target = bed.paths.inbox.appendingPathComponent("Screenshot_20260101-120000.png")
    try FileManager.default.removeItem(at: target)
    try FileManager.default.copyItem(
        at: fixture("Screenshot_20260102-130000.png"), to: target)

    let second = try await ExtractRunner(paths: bed.paths).run(concurrency: 2)
    #expect(second.processed == 1)
    #expect(try JSONLStore<IndexRecord>(url: bed.paths.index).readAll().count == 2)
}

@Test func nonPNGFilesInTheInboxAreIgnored() async throws {
    let bed = try Bed(); defer { bed.cleanup() }
    try bed.stage("Screenshot_20260101-120000.png")
    try Data("not an image".utf8).write(
        to: bed.paths.inbox.appendingPathComponent("notes.txt"))

    let result = try await ExtractRunner(paths: bed.paths).run(concurrency: 2)
    #expect(result.processed == 1)
}
