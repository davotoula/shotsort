import Testing
import Foundation
@testable import ShotsortCore

private func tax(_ names: [String]) -> Taxonomy {
    Taxonomy(version: 1, filterVersion: 3,
             categories: names.map { Category(name: $0, desc: "d", examples: []) })
}

@Test func acceptsAValidTaxonomy() throws {
    try TaxonomyStore.validate(tax(["News & Current Affairs", "Travel", "Unsorted"]))
}

@Test func rejectsMissingUnsorted() {
    #expect(throws: TaxonomyError.missingUnsorted) {
        try TaxonomyStore.validate(tax(["News", "Travel"]))
    }
}

@Test func rejectsPathSeparators() {
    #expect(throws: (any Error).self) {
        try TaxonomyStore.validate(tax(["News / Current Affairs", "Unsorted"]))
    }
    #expect(throws: (any Error).self) {
        try TaxonomyStore.validate(tax(["News:Affairs", "Unsorted"]))
    }
}

@Test func rejectsLeadingDotAndReservedName() {
    #expect(throws: (any Error).self) {
        try TaxonomyStore.validate(tax([".hidden", "Unsorted"]))
    }
    #expect(throws: (any Error).self) {
        try TaxonomyStore.validate(tax([".shotsort", "Unsorted"]))
    }
}

@Test func rejectsEmptyWhitespaceAndOverlongNames() {
    #expect(throws: (any Error).self) { try TaxonomyStore.validate(tax(["", "Unsorted"])) }
    #expect(throws: (any Error).self) { try TaxonomyStore.validate(tax(["   ", "Unsorted"])) }
    #expect(throws: (any Error).self) { try TaxonomyStore.validate(tax([" News", "Unsorted"])) }
    #expect(throws: (any Error).self) {
        try TaxonomyStore.validate(tax([String(repeating: "a", count: 65), "Unsorted"]))
    }
}

@Test func rejectsCaseInsensitiveCollision() {
    // APFS is case-insensitive: News and news are one directory.
    #expect(throws: (any Error).self) {
        try TaxonomyStore.validate(tax(["News", "news", "Unsorted"]))
    }
}

@Test func rejectsUnicodeNormalisationCollision() {
    // APFS is normalisation-insensitive. These render identically in any editor.
    let nfc = "Malm\u{00F6}"          // o-with-diaeresis, precomposed
    let nfd = "Malmo\u{0308}"         // o + combining diaeresis
    // Swift's String == is defined over Unicode canonical equivalence, so
    // nfc == nfd is *always* true even though these are genuinely distinct
    // scalar sequences (that's the whole reason APFS-style folding matters
    // here). Compare unicodeScalars to confirm the literals themselves
    // weren't accidentally written identically at the source level.
    #expect(Array(nfc.unicodeScalars) != Array(nfd.unicodeScalars))
    #expect(throws: (any Error).self) {
        try TaxonomyStore.validate(tax([nfc, nfd, "Unsorted"]))
    }
    // Pins the normalisation step itself. Swift's String equality is already
    // canonical-equivalence-based, so the collision assertion below would pass
    // even with precomposition removed from folded() — this comparison is at
    // scalar level, where it would not.
    #expect(Array(TaxonomyStore.folded(nfc).unicodeScalars)
            == Array(TaxonomyStore.folded(nfd).unicodeScalars))
}

@Test func validationNeverRewritesNames() throws {
    let t = tax(["News & Current Affairs", "Unsorted"])
    try TaxonomyStore.validate(t)
    #expect(t.names == ["News & Current Affairs", "Unsorted"])
}

@Test func saveThenLoadRoundTrips() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString + ".json")
    try TaxonomyStore.save(tax(["News", "Unsorted"]), to: url)
    let back = try TaxonomyStore.load(from: url)
    #expect(back.names == ["News", "Unsorted"])
    #expect(back.filterVersion == 3)
    try? FileManager.default.removeItem(at: url)
}
