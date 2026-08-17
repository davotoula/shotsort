import Testing
import Foundation
@testable import ShotsortCore

@Test func indexRecordRoundTripsThroughJSON() throws {
    let r = IndexRecord(
        file: "Screenshot_20260420-135611.png",
        ts: "2026-04-20T13:56:11",
        tsSource: .filename,
        ocr: "Departures From Malmö Centralstation",
        chars: 412, blocks: 37, density: 0.31,
        sceneRaw: [SceneObservation(identifier: "screenshot", confidence: 0.94),
                   SceneObservation(identifier: "map", confidence: 0.38)],
        faces: 0, faceAreaMax: 0.0, domains: [], error: nil)

    let data = try JSONEncoder().encode(r)
    let back = try JSONDecoder().decode(IndexRecord.self, from: data)
    #expect(back.file == r.file)
    #expect(back.sceneRaw.count == 2)
    #expect(back.sceneRaw[0].identifier == "screenshot")
    #expect(back.tsSource == .filename)
}

@Test func manifestRecordEncodesOpAsString() throws {
    let m = ManifestRecord(op: .revert, file: "a.png",
                           from: "/o/News/a.png", to: "/i/a.png",
                           at: "2026-08-08T14:19:04")
    let json = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
    #expect(json.contains("\"revert\""))
}

@Test func taxonomyExposesNamesInDeclarationOrder() {
    let t = Taxonomy(version: 1, filterVersion: 3, categories: [
        Category(name: "News", desc: "d", examples: []),
        Category(name: "Unsorted", desc: "d", examples: []),
    ])
    #expect(t.names == ["News", "Unsorted"])
}
