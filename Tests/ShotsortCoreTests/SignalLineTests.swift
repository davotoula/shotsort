import Testing
@testable import ShotsortCore

private func record(faces: Int = 0, faceAreaMax: Double = 0,
                    domains: [String] = [],
                    sceneRaw: [SceneObservation] = []) -> IndexRecord {
    IndexRecord(file: "a.png", ts: "t", tsSource: .filename, ocr: "",
                chars: 0, blocks: 0, density: 0, sceneRaw: sceneRaw,
                faces: faces, faceAreaMax: faceAreaMax,
                domains: domains, error: nil)
}

@Test func faceBandsAreOrderedAndThresholdedOnce() {
    #expect(FaceBand.of(faceAreaMax: 0.0) == .absent)
    #expect(FaceBand.of(faceAreaMax: 0.01) == .tiny)
    #expect(FaceBand.of(faceAreaMax: 0.10) == .small)
    #expect(FaceBand.of(faceAreaMax: 0.40) == .large)
    #expect(FaceBand.tiny < FaceBand.small)
}

@Test func zeroFacesRenderWithoutACount() {
    #expect(FaceBand.of(faceAreaMax: 0).describe(count: 0) == "0")
    #expect(FaceBand.of(faceAreaMax: 0.40).describe(count: 2) == "2 large")
}

@Test func renderCarriesScenesFacesAndDomains() {
    let line = SignalLine.render(for: record(
        faces: 2, faceAreaMax: 0.35,
        sceneRaw: [SceneObservation(identifier: "people", confidence: 0.91),
                   SceneObservation(identifier: "car", confidence: 0.91)]))
    #expect(line.contains("people"))
    #expect(line.contains("car"))
    #expect(line.contains("2 large"))
}

@Test func absentSignalsRenderAsAnEmDash() {
    #expect(SignalLine.render(for: record()).contains("scenes: —"))
    #expect(SignalLine.render(for: record()).contains("domains: —"))
}
