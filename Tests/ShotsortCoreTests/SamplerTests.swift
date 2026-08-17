import Testing
@testable import ShotsortCore

private func synthetic(_ n: Int) -> [IndexRecord] {
    (0..<n).map { i in
        IndexRecord(file: "f\(i).png", ts: "t", tsSource: .filename,
                    ocr: "text \(i)", chars: 40, blocks: 2, density: 0.1,
                    sceneRaw: [SceneObservation(identifier: "scene\(i % 30)",
                                                confidence: 0.8)],
                    faces: 0, faceAreaMax: 0,
                    domains: ["d\(i % 40).com"], error: nil)
    }
}

@Test func sampleRespectsTheHardCap() {
    // 8 per cluster x 12 clusters + 24 long tail = 120.
    #expect(Sampler.sample(synthetic(1500)).count <= 120)
}

@Test func sampleIsDeterministic() {
    let records = synthetic(1500)
    #expect(Sampler.sample(records).map(\.file) == Sampler.sample(records).map(\.file))
}

@Test func smallInputsAreReturnedWhole() {
    #expect(Sampler.sample(synthetic(5)).count == 5)
}

@Test func signalLineCarriesSceneFaceAndDomain() {
    // Without this the large-face/zero-text cluster reaches the proposer as a
    // batch of empty snippets, no "Calls & People" category is ever proposed,
    // and those images land in Unsorted however good the signal was.
    let videoCall = IndexRecord(
        file: "v.png", ts: "t", tsSource: .filename, ocr: "",
        chars: 0, blocks: 0, density: 0,
        sceneRaw: [SceneObservation(identifier: "people", confidence: 0.91),
                   SceneObservation(identifier: "car", confidence: 0.91)],
        faces: 2, faceAreaMax: 0.35, domains: [], error: nil)
    let line = Sampler.signalLine(for: videoCall)
    #expect(line.contains("people"))
    #expect(line.contains("car"))
    #expect(line.contains("large"))
}
