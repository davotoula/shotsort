import Testing
import Foundation
@testable import ShotsortCore

@Test func stateFilesLiveUnderDotShotsortInOutputTree() {
    let p = Paths(inbox: URL(fileURLWithPath: "/tmp/ss"),
                  output: URL(fileURLWithPath: "/tmp/ss-sorted"))
    #expect(p.state.path == "/tmp/ss-sorted/.shotsort")
    #expect(p.index.path == "/tmp/ss-sorted/.shotsort/index.jsonl")
    #expect(p.labels.path == "/tmp/ss-sorted/.shotsort/labels.jsonl")
    #expect(p.manifest.path == "/tmp/ss-sorted/.shotsort/manifest.jsonl")
    #expect(p.taxonomy.path == "/tmp/ss-sorted/.shotsort/taxonomy.json")
}

@Test func categoryFolderIsDirectChildOfOutput() {
    let p = Paths(inbox: URL(fileURLWithPath: "/tmp/ss"),
                  output: URL(fileURLWithPath: "/tmp/ss-sorted"))
    #expect(p.category("News & Current Affairs").path
            == "/tmp/ss-sorted/News & Current Affairs")
}

@Test func ensureStateCreatesDirectory() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    let p = Paths(inbox: tmp.appendingPathComponent("ss"),
                  output: tmp.appendingPathComponent("ss-sorted"))
    try p.ensureState()
    #expect(FileManager.default.fileExists(atPath: p.state.path))
    try? FileManager.default.removeItem(at: tmp)
}

// All assertions compare `.path` strings, never URLs: URL equality is not
// path equality (a URL built from "." compares ==-unequal to the
// cwd-derived URL for the same directory despite identical .path), and
// .path keeps these tests immune to that even though resolve's
// standardisation happens to restore == today.

@Test func nilFlagsResolveToCwdAndNestedSsSorted() {
    let cwd = FileManager.default.currentDirectoryPath
    let p = Paths.resolve(inbox: nil, output: nil)
    #expect(p.inbox.path == cwd)
    #expect(p.output.path == cwd + "/ss-sorted")
}

@Test func aRelativeInboxAnchorsTheDefaultOutputUnderItself() {
    // The likeliest regression: a cwd-anchored default output passes the
    // nil/nil test above and silently scatters state away from the
    // collection. State travels with the inbox.
    let cwd = FileManager.default.currentDirectoryPath
    let p = Paths.resolve(inbox: "pile", output: nil)
    #expect(p.inbox.path == cwd + "/pile")
    #expect(p.output.path == cwd + "/pile/ss-sorted")
}

@Test func explicitAbsolutePathsAreTakenAsGiven() {
    // Fictional paths on purpose: resolve never stats, and /tmp-style
    // symlinked prefixes would entangle the assertion with the host.
    let p = Paths.resolve(inbox: "/screens/in", output: "/screens/out")
    #expect(p.inbox.path == "/screens/in")
    #expect(p.output.path == "/screens/out")
}

@Test func derivedStatePathsComposeWithResolve() {
    // Pins that resolve builds a plain Paths and the existing derived
    // properties do the rest — not a parallel path scheme.
    let p = Paths.resolve(inbox: "pile", output: nil)
    #expect(p.index.path.hasSuffix("/pile/ss-sorted/.shotsort/index.jsonl"))
}
