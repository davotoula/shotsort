import Testing
import Foundation
@testable import ShotsortCore

private let taxonomy = Taxonomy(version: 1, filterVersion: 3, categories: [
    Category(name: "News", desc: "news", examples: []),
    Category(name: "Unsorted", desc: "fallback", examples: []),
])

private actor Spy: CategoryResponder {
    private(set) var calls = 0
    private(set) var lastPrompt = ""
    private let reply: String
    private let shouldThrow: Bool

    init(reply: String, shouldThrow: Bool = false) {
        self.reply = reply
        self.shouldThrow = shouldThrow
    }

    func category(for prompt: String, allowed: [ShotsortCore.Category]) async throws -> String {
        calls += 1
        lastPrompt = prompt
        if shouldThrow { throw ClassifyError.categoryNotInTaxonomy("guardrail") }
        return reply
    }

    func callCount() -> Int { calls }
    func prompt() -> String { lastPrompt }
}

private func record(chars: Int, ocr: String = "",
                    domains: [String] = []) -> IndexRecord {
    IndexRecord(file: "a.png", ts: "t", tsSource: .filename, ocr: ocr,
                chars: chars, blocks: 1, density: 0.2, sceneRaw: [],
                faces: 0, faceAreaMax: 0, domains: domains, error: nil)
}

@Test func noSignalRecordsSkipTheModelEntirely() async {
    let spy = Spy(reply: "News")
    let label = await Classifier(taxonomy: taxonomy, responder: spy)
        .classify(record(chars: 0))
    #expect(label.category == "Unsorted")
    #expect(label.reason == "no-signal")
    #expect(await spy.callCount() == 0)
}

@Test func aValidCategoryIsRecordedAsModelDerived() async {
    let label = await Classifier(taxonomy: taxonomy, responder: Spy(reply: "News"))
        .classify(record(chars: 400, ocr: "bank of england"))
    #expect(label.category == "News")
    #expect(label.reason == "model")
    #expect(label.filterVersion == SceneFilter.filterVersion)
}

@Test func aCategoryOutsideTheTaxonomyIsNotFuzzyMatched() async {
    // Constrained decoding makes this impossible in practice, so a miss means
    // an invariant broke and must surface rather than be repaired into
    // something plausible.
    let label = await Classifier(taxonomy: taxonomy, responder: Spy(reply: "Newsy"))
        .classify(record(chars: 400, ocr: "x"))
    #expect(label.category == "Unsorted")
    // Distinct from "guardrail": the smoke run reads this histogram as its
    // diagnostic, so a schema fault must not present as a model refusal.
    #expect(label.reason == "schema-miss")
}

@Test func theAlternateVariantAsksADifferentQuestion() {
    let c = Classifier(taxonomy: taxonomy, responder: Spy(reply: "News"))
    let r = record(chars: 40, ocr: "bank of england", domains: ["news.sky.com"])
    let primary = c.promptText(for: r, variant: .primary)
    let alternate = c.promptText(for: r, variant: .alternate)
    // --verify re-asks with .alternate. If the two were identical the
    // agreement rate would measure decoder sampling noise, not robustness,
    // and would read ~100% by construction.
    #expect(primary != alternate)
    #expect(alternate.contains("Which single category"))
}

@Test func aThrowingResponderLandsInUnsortedRatherThanKillingTheRun() async {
    let label = await Classifier(taxonomy: taxonomy,
                                 responder: Spy(reply: "News", shouldThrow: true))
        .classify(record(chars: 400, ocr: "x"))
    #expect(label.category == "Unsorted")
    #expect(label.reason == "guardrail")
}

@Test func truncationIsAppliedBeforeTheCall() async {
    let spy = Spy(reply: "News")
    let long = String(repeating: "z", count: 5000)
    _ = await Classifier(taxonomy: taxonomy, responder: spy)
        .classify(record(chars: long.count, ocr: long))
    #expect(await spy.prompt().count < 1200)
}

@Test func thePromptCarriesTheSignalLine() {
    let text = Classifier(taxonomy: taxonomy, responder: Spy(reply: "News"))
        .promptText(for: record(chars: 20, ocr: "hello",
                                domains: ["news.sky.com"]))
    #expect(text.contains("news.sky.com"))
    #expect(text.contains("faces:"))
}

@Test func theInstructionsCarryEachCategoryDescription() {
    // The bug this change fixes: sixteen bare, undefined category names gave
    // the model nothing to distinguish them by, so it defaulted to whichever
    // felt broadest. The catalogue is what puts the descriptions in front of
    // the model.
    let allowed = [
        Category(name: "Social Media", desc: "Feeds, posts, likes, DMs", examples: []),
        Category(name: "Entertainment", desc: "Streaming video and music playback", examples: []),
        Category(name: "Unsorted", desc: "No clear signal", examples: []),
    ]
    let catalogue = OnDeviceResponder.catalogue(allowed)
    #expect(catalogue.contains("Social Media"))
    #expect(catalogue.contains("Feeds, posts, likes, DMs"))
    #expect(catalogue.contains("Entertainment"))
    #expect(catalogue.contains("Streaming video and music playback"))
}

@Test func longDescriptionsAreTruncatedInTheCatalogue() {
    let longDesc = String(repeating: "x", count: 500)
    let allowed = [Category(name: "Work", desc: longDesc, examples: [])]
    let catalogue = OnDeviceResponder.catalogue(allowed)
    #expect(!catalogue.contains(longDesc))
    #expect(catalogue.contains(String(repeating: "x", count: OnDeviceResponder.maxDescChars)))
    // The name itself is never truncated — it is the literal value the
    // model must echo back.
    #expect(catalogue.contains("- Work:"))
}

@Test func theSchemaStillConstrainsToNamesOnly() {
    let allowed = [
        Category(name: "News", desc: "Breaking stories and headlines", examples: []),
        Category(name: "Unsorted", desc: "No clear signal", examples: []),
    ]
    let names = OnDeviceResponder.names(for: allowed)
    #expect(names == ["News", "Unsorted"])
    // Descriptions must never leak into the set handed to the schema's
    // anyOf, which is what constrains the model's returned value.
    #expect(!names.contains { $0.contains("Breaking") })
    #expect(!names.contains { $0.contains("clear signal") })
}
