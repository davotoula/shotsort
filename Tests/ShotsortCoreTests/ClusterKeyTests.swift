import Testing
@testable import ShotsortCore

private func record(domains: [String] = [], faceAreaMax: Double = 0,
                    density: Double = 0,
                    sceneRaw: [SceneObservation] = []) -> IndexRecord {
    IndexRecord(file: "a.png", ts: "t", tsSource: .filename, ocr: "",
                chars: 0, blocks: 0, density: density, sceneRaw: sceneRaw,
                faces: 0, faceAreaMax: faceAreaMax, domains: domains, error: nil)
}

@Test func absentSceneIsAnExplicitValueNotUndefined() {
    // Measured: scenes is empty for 60% of the collection.
    #expect(ClusterKey.of(record()).topScene == "none")
}

@Test func topSceneUsesTheFilteredProjection() {
    let k = ClusterKey.of(record(sceneRaw: [
        SceneObservation(identifier: "screenshot", confidence: 0.99),
        SceneObservation(identifier: "map", confidence: 0.80),
    ]))
    #expect(k.topScene == "map")
}

@Test func topSceneIsStableUnderReorderedEqualConfidences() {
    let a = ClusterKey.of(record(sceneRaw: [
        SceneObservation(identifier: "people", confidence: 0.91),
        SceneObservation(identifier: "adult", confidence: 0.91),
    ]))
    let b = ClusterKey.of(record(sceneRaw: [
        SceneObservation(identifier: "adult", confidence: 0.91),
        SceneObservation(identifier: "people", confidence: 0.91),
    ]))
    #expect(a == b)
}

@Test func faceBandsComeFromTheSharedLadder() {
    // Same thresholds the signal line and the no-signal gate use.
    #expect(ClusterKey.of(record(faceAreaMax: 0.0)).faceBand == "absent")
    #expect(ClusterKey.of(record(faceAreaMax: 0.01)).faceBand == "tiny")
    #expect(ClusterKey.of(record(faceAreaMax: 0.10)).faceBand == "small")
    #expect(ClusterKey.of(record(faceAreaMax: 0.40)).faceBand == "large")
}

@Test func clusteringSamplerAndClassifierAgreeOnTheBand() {
    // Three call sites previously each had their own ladder and disagreed at
    // 0.05-0.15. Any future divergence fails here.
    let r = record(faceAreaMax: 0.10)
    #expect(ClusterKey.of(r).faceBand == FaceBand.of(faceAreaMax: 0.10).rawValue)
    #expect(Sampler.signalLine(for: r) == SignalLine.render(for: r))
}

@Test func domainIsTheFirstHarvestedOrNone() {
    #expect(ClusterKey.of(record()).domain == "none")
    #expect(ClusterKey.of(record(domains: ["a.com", "b.com"])).domain == "a.com")
}
