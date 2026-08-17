import Testing
import Foundation
@testable import ShotsortCore

private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ShotsortCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("fixtures/synthetic/\(name)")
}

@Test func readsTextFromASyntheticFixture() async {
    let r = await Extractor().extract(url: fixture("Screenshot_20260101-120000.png"))
    // Containment, not equality: Vision output shifts between OS versions.
    #expect(r.ocr.uppercased().contains("SHOTSORT"))
    #expect(r.chars > 0)
    #expect(r.blocks > 0)
    #expect(r.error == nil)
}

@Test func harvestsDomainsFoundInTheImageText() async {
    let r = await Extractor().extract(url: fixture("Screenshot_20260102-130000.png"))
    #expect(r.domains.contains("news.sky.com"))
}

@Test func recordsTimestampFromTheFilename() async {
    let r = await Extractor().extract(url: fixture("Screenshot_20260101-120000.png"))
    #expect(r.ts == "2026-01-01T12:00:00")
    #expect(r.tsSource == .filename)
}

@Test func populatesSceneRawUnfiltered() async {
    let r = await Extractor().extract(url: fixture("Screenshot_20260101-120000.png"))
    // Raw capture is persisted; the filtered projection is derived on read.
    #expect(!r.sceneRaw.isEmpty)
}

@Test func aMissingFileYieldsAnErrorRecordRatherThanCrashing() async {
    let r = await Extractor().extract(url: URL(fileURLWithPath: "/nonexistent/nope.png"))
    #expect(r.error != nil)
}
