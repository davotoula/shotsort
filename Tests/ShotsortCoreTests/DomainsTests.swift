import Testing
@testable import ShotsortCore

@Test func harvestsBareDomains() {
    #expect(Domains.harvest(from: "news.sky.com/story/rachel-reeves") == ["news.sky.com"])
}

@Test func harvestsFromFullURLs() {
    #expect(Domains.harvest(from: "see https://utxo.one/feed now") == ["utxo.one"])
}

@Test func deduplicatesAndSortsForStability() {
    #expect(Domains.harvest(from: "b.com and a.com and b.com") == ["a.com", "b.com"])
}

@Test func returnsEmptyWhenThereIsNoDomain() {
    #expect(Domains.harvest(from: "Departures From Malmö Centralstation").isEmpty)
}

@Test func ignoresDecimalNumbersThatLookLikeDomains() {
    #expect(Domains.harvest(from: "lost $4,680,590.31 today").isEmpty)
}

@Test func rejectsFilenamesAndTruncationsAsDomains() {
    // Real offenders harvested from the 1,494-image index (TODO item 9):
    // file names, a source file, and a word truncated across an OCR line
    // break. Domains are the grouping basis, so junk here means junk groups.
    #expect(Domains.harvest(from: "open book.php then coptics.html").isEmpty)
    #expect(Domains.harvest(from: "ChatFileUploadDialog.kt line 40").isEmpty)
    #expect(Domains.harvest(from: "regards alex.mor").isEmpty)
}

@Test func keepsRealTLDsIncludingCountryCodes() {
    #expect(Domains.harvest(from: "skanetrafiken.se and bergfex.at and getalby.com")
            == ["bergfex.at", "getalby.com", "skanetrafiken.se"])
}

@Test func keepsNoveltyTLDsTheCollectionActuallyUses() {
    // The first allowlist cut dropped these real sources — nostr.mom alone
    // carried 8 records, a would-be classification group. The allowlist is
    // curated against the real index, not assumed.
    #expect(Domains.harvest(from: "relay nostr.mom and www.studentinformation.gov.scot")
            == ["nostr.mom", "www.studentinformation.gov.scot"])
}
