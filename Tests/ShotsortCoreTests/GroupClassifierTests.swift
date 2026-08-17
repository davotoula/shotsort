import Testing
@testable import ShotsortCore

private struct StubRefusal: Error {}

/// Replays a script of answers/refusals and records every prompt it saw.
private actor ScriptedResponder: CategoryResponder {
    private(set) var prompts: [String] = []
    private var script: [Result<String, StubRefusal>]
    init(_ script: [Result<String, StubRefusal>]) { self.script = script }
    func category(for prompt: String, allowed: [Category]) async throws -> String {
        prompts.append(prompt)
        return try script.removeFirst().get()
    }
    func seen() -> [String] { prompts }
}

private func member(_ file: String, ocr: String = "sample text") -> IndexRecord {
    IndexRecord(file: file, ts: "t", tsSource: .filename, ocr: ocr,
                chars: 40, blocks: 2, density: 0.1, sceneRaw: [], faces: 0,
                faceAreaMax: 0, domains: ["d.com"], error: nil)
}

private func makeTaxonomy(_ names: [String]) -> Taxonomy {
    Taxonomy(version: 1, filterVersion: SceneFilter.filterVersion,
             categories: names.map { Category(name: $0, desc: "d", examples: []) })
}

private func makeGroup(_ n: Int) -> ClassifyGroup {
    ClassifyGroup(evidence: "domain d.com", kind: .domain,
                  members: (0..<n).map { member("f\($0).png") })
}

private func sampleLines(_ prompt: String) -> [String] {
    prompt.split(separator: "\n").filter { $0.hasPrefix("- ") }.map(String.init)
}

@Test func groupPromptCapsSamplesAndNamesEvidence() {
    let c = Classifier(taxonomy: makeTaxonomy(["Travel", "Unsorted"]),
                       responder: ScriptedResponder([]))
    let prompt = c.groupPrompt(for: makeGroup(10),
                               samples: Classifier.groupSampleCount)
    #expect(sampleLines(prompt).count == 6)
    #expect(prompt.contains("domain d.com"))
    #expect(prompt.contains("10 screenshots"))
}

@Test func groupPromptTruncatesLongOCR() {
    let long = String(repeating: "a", count: Sampler.snippetChars + 100) + "ZZZ"
    let g = ClassifyGroup(evidence: "domain d.com", kind: .domain,
                          members: [member("f.png", ocr: long),
                                    member("g.png")])
    let c = Classifier(taxonomy: makeTaxonomy(["Travel", "Unsorted"]),
                       responder: ScriptedResponder([]))
    #expect(!c.groupPrompt(for: g, samples: 6).contains("ZZZ"))
}

@Test func alternateVariantRephrasesWithoutChangingEvidence() {
    let c = Classifier(taxonomy: makeTaxonomy(["Travel", "Unsorted"]),
                       responder: ScriptedResponder([]))
    let primary = c.groupPrompt(for: makeGroup(4), samples: 6)
    let alternate = c.groupPrompt(for: makeGroup(4), samples: 6,
                                  variant: .alternate)
    #expect(primary != alternate)
    #expect(alternate.contains("Which single category does this source belong to?"))
    // Same evidence, same prominence: identical sample lines in both.
    #expect(sampleLines(primary) == sampleLines(alternate))
    #expect(alternate.contains("domain d.com"))
}

@Test func groupCategoryReturnsTheAnswer() async {
    let spy = ScriptedResponder([.success("Travel")])
    let c = Classifier(taxonomy: makeTaxonomy(["Travel", "Unsorted"]),
                       responder: spy)
    let answer = await c.groupCategory(makeGroup(8))
    #expect(answer == "Travel")
    let prompts = await spy.seen()
    #expect(prompts.count == 1)
    #expect(sampleLines(prompts[0]).count == 6)
}

@Test func groupCategoryRetriesOnceWithFewerSamples() async {
    // One poisonous member's text is the likely refusal cause, so the retry
    // shrinks the sample set rather than repeating the identical prompt.
    let spy = ScriptedResponder([.failure(StubRefusal()), .success("Travel")])
    let c = Classifier(taxonomy: makeTaxonomy(["Travel", "Unsorted"]),
                       responder: spy)
    let answer = await c.groupCategory(makeGroup(8))
    #expect(answer == "Travel")
    let prompts = await spy.seen()
    #expect(prompts.count == 2)
    #expect(sampleLines(prompts[1]).count == 3)
}

@Test func groupCategoryGivesUpAfterTwoFailures() async {
    let spy = ScriptedResponder([.failure(StubRefusal()), .failure(StubRefusal())])
    let c = Classifier(taxonomy: makeTaxonomy(["Travel", "Unsorted"]),
                       responder: spy)
    let answer = await c.groupCategory(makeGroup(8))
    #expect(answer == nil)
    #expect(await spy.seen().count == 2)
}

@Test func groupCategoryTreatsASchemaMissAsNoAnswer() async {
    // A name outside the taxonomy means constrained decoding failed; it
    // surfaces as nil rather than being repaired, mirroring the per-image
    // "schema-miss" stance.
    let spy = ScriptedResponder([.success("NotACategory")])
    let c = Classifier(taxonomy: makeTaxonomy(["Travel", "Unsorted"]),
                       responder: spy)
    let answer = await c.groupCategory(makeGroup(8))
    #expect(answer == nil)
    #expect(await spy.seen().count == 1)
}
