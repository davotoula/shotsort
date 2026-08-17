import Testing
@testable import ShotsortCore

private func record(chars: Int = 0, domains: [String] = [],
                    faceAreaMax: Double = 0,
                    sceneRaw: [SceneObservation] = []) -> IndexRecord {
    IndexRecord(file: "a.png", ts: "t", tsSource: .filename,
                ocr: String(repeating: "x", count: chars),
                chars: chars, blocks: 0, density: 0,
                sceneRaw: sceneRaw, faces: 0, faceAreaMax: faceAreaMax,
                domains: domains, error: nil)
}

@Test func firesWhenEverySignalIsAbsent() {
    #expect(SignalGate.hasNoSignal(record()))
}

@Test func textAloneIsEnoughToConsultTheModel() {
    #expect(!SignalGate.hasNoSignal(record(chars: 400)))
}

@Test func aDomainAloneIsEnough() {
    #expect(!SignalGate.hasNoSignal(record(domains: ["news.sky.com"])))
}

@Test func aLargeFaceAloneIsEnough() {
    // The video call: no text, but a face filling much of the frame.
    #expect(!SignalGate.hasNoSignal(record(faceAreaMax: 0.30)))
}

@Test func aTinyAvatarFaceIsNotEnough() {
    // Feed avatars register as faces; area is what separates the cases.
    #expect(SignalGate.hasNoSignal(record(faceAreaMax: 0.01)))
}

@Test func aSurvivingSceneLabelIsEnough() {
    #expect(!SignalGate.hasNoSignal(record(
        sceneRaw: [SceneObservation(identifier: "map", confidence: 0.9)])))
}

@Test func aDenylistedSceneLabelIsNotEnough() {
    // The gate reads the filtered projection, not the raw observations.
    // ClassifyImageRequest labels every image, so reading raw output would
    // make this conjunct permanently false and the AND never satisfiable.
    #expect(SignalGate.hasNoSignal(record(
        sceneRaw: [SceneObservation(identifier: "screenshot", confidence: 0.99)])))
}
