import Testing
import Foundation
@testable import ShotsortCore

private struct Row: Codable, Sendable, Equatable {
    let a: Int
    let b: String
}

private func tempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("jsonl")
}

@Test func appendThenReadAllPreservesOrder() throws {
    let url = tempURL()
    let store = JSONLStore<Row>(url: url)
    try store.append(Row(a: 1, b: "one"))
    try store.append(Row(a: 2, b: "two"))
    #expect(try store.readAll() == [Row(a: 1, b: "one"), Row(a: 2, b: "two")])
    try? FileManager.default.removeItem(at: url)
}

@Test func readAllOnMissingFileReturnsEmpty() throws {
    let store = JSONLStore<Row>(url: tempURL())
    #expect(try store.readAll().isEmpty)
}

@Test func eachRecordOccupiesExactlyOneLine() throws {
    let url = tempURL()
    let store = JSONLStore<Row>(url: url)
    try store.append(Row(a: 1, b: "has\nnewline"))
    try store.append(Row(a: 2, b: "plain"))
    let text = try String(contentsOf: url, encoding: .utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 2)
    try? FileManager.default.removeItem(at: url)
}

@Test func aTruncatedFinalLineIsSkippedRatherThanThrowing() throws {
    let url = tempURL()
    let store = JSONLStore<Row>(url: url)
    try store.append(Row(a: 1, b: "one"))
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"a\":2,\"b\":".utf8))
    try handle.close()
    // A process killed mid-write leaves a partial final line; the complete
    // records before it must still be readable.
    #expect(try store.readAll() == [Row(a: 1, b: "one")])
    try? FileManager.default.removeItem(at: url)
}

@Test func anUndecodableInteriorLineThrowsRatherThanVanishing() throws {
    // Blanket tolerance would mean that adding a field to a record type
    // silently erases every prior record from readAll() — extract would
    // reprocess the whole collection and classify would skip it, both with
    // no error shown. Only the final line may be partial.
    let url = tempURL()
    let store = JSONLStore<Row>(url: url)
    try store.append(Row(a: 1, b: "one"))
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"unexpected\":true}\n".utf8))
    try handle.close()
    try store.append(Row(a: 3, b: "three"))
    #expect(throws: (any Error).self) { _ = try store.readAll() }
    try? FileManager.default.removeItem(at: url)
}
