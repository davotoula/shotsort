import Testing
import Foundation
import Vision
@testable import ShotsortCore

private func obs(_ pairs: [(String, Float)]) -> [SceneObservation] {
    pairs.map { SceneObservation(identifier: $0.0, confidence: $0.1) }
}

@Test func dropsObservationsBelowTheConfidenceFloor() {
    #expect(SceneFilter.scenes(from: obs([("map", 0.94), ("cord", 0.10)])) == ["map"])
}

@Test func dropsDenylistedIdentifiers() {
    let out = SceneFilter.scenes(from: obs([("screenshot", 0.98),
                                            ("document", 0.91),
                                            ("map", 0.62)]))
    #expect(out == ["map"])
}

@Test func matchingIsExactNotSubstring() {
    // "newspaper" is among the most informative labels for a collection full
    // of news screenshots. Substring matching on a "paper" entry would lose it.
    #expect(SceneFilter.scenes(from: obs([("newspaper", 0.77)])) == ["newspaper"])
}

@Test func budgetCountsConfidenceGroupsNotObservations() {
    // The 2025-05-26 video call: two concepts across four observations,
    // because parent and child identifiers arrive at identical confidence.
    let out = SceneFilter.scenes(from: obs([
        ("adult", 0.91), ("people", 0.91),
        ("optical_equipment", 0.86), ("eyeglasses", 0.86),
        ("aa", 0.70), ("bb", 0.60), ("cc", 0.50), ("dd", 0.40),
    ]))
    // Five groups kept: 0.91, 0.86, 0.70, 0.60, 0.50. The 0.40 group falls out.
    #expect(out.contains("adult"))
    #expect(out.contains("people"))
    #expect(out.contains("eyeglasses"))
    #expect(out.contains("optical_equipment"))
    #expect(!out.contains("dd"))
}

@Test func siblingsGroupWhenConfidencesAreNearButNotEqual() {
    // Real values measured from the collection. Vision returned this exact
    // pair bit-equal on one image and 4e-5 apart on another, so grouping on
    // exact Float equality would put them in separate slots roughly three
    // times in four — silently degrading the budget to a plain top-5.
    let out = SceneFilter.scenes(from: obs([
        ("people", 0.815922), ("adult", 0.815918),
        ("interior_room", 0.513219), ("nightclub", 0.513184),
        ("aa", 0.44), ("bb", 0.43), ("cc", 0.42), ("dd", 0.41),
    ]))
    // Two near-pairs collapse to two groups, leaving budget for aa/bb/cc.
    #expect(out.prefix(4) == ["adult", "people", "interior_room", "nightclub"])
    #expect(!out.contains("dd"))
}

@Test func distinctConceptsFurtherApartThanEpsilonStaySeparate() {
    let out = SceneFilter.scenes(from: obs([
        ("aa", 0.90), ("bb", 0.80), ("cc", 0.70),
        ("dd", 0.60), ("ee", 0.50), ("ff", 0.40),
    ]))
    // Six groups, budget of five: the lowest falls out.
    #expect(out == ["aa", "bb", "cc", "dd", "ee"])
}

@Test func orderingWithinAGroupIsLexicographic() {
    let a = SceneFilter.scenes(from: obs([("people", 0.91), ("adult", 0.91)]))
    let b = SceneFilter.scenes(from: obs([("adult", 0.91), ("people", 0.91)]))
    // Vision's ordering among equal confidences is not documented as stable,
    // so an unchanged sceneRaw must yield a byte-identical scenes list.
    #expect(a == b)
    #expect(a == ["adult", "people"])
}

@Test func emptyWhenEverythingIsFilteredOut() {
    #expect(SceneFilter.scenes(from: obs([("screenshot", 0.99)])).isEmpty)
    #expect(SceneFilter.scenes(from: []).isEmpty)
}

@Test func denylistValidationFailsOnAnEntryOutsideTheVocabulary() {
    // A denylist entry matching nothing is the same class of defect as a gate
    // that never fires: silent, and invisible until someone audits results.
    #expect(throws: (any Error).self) {
        try SceneFilter.validateDenylist(against: ["screenshot"])
    }
}

@Test func preflightPassesOnTheShippedConstants() throws {
    // Preflight is what the four stages actually call; validateDenylist is
    // the check it runs. Asserting the entry point rather than only the
    // helper means a Preflight that stopped checking anything would fail here.
    try Preflight.run()
}

@Test func everyDenylistEntryExistsInTheRealVisionVocabulary() throws {
    // Asserting against a vocabulary built FROM the denylist would pass for
    // any contents whatsoever — including "text"/"paper"/"pattern", none of
    // which are members. The real 1,303-identifier vocabulary is reachable,
    // and checking against it is the only version of this test that can fail.
    try SceneFilter.validateDenylist(
        against: ClassifyImageRequest().supportedIdentifiers)
}
