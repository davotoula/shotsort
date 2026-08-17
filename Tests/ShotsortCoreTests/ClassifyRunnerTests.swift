import Testing
import Foundation
@testable import ShotsortCore

private struct Fixed: CategoryResponder {
    let reply: String
    func category(for prompt: String, allowed: [ShotsortCore.Category]) async throws -> String {
        allowed.map { $0.name }.contains(reply) ? reply : Taxonomy.unsortedName
    }
}

/// Returns a different category depending on prompt variant, so tests can
/// exercise --verify's disagreement path. `.alternate`'s rendering is
/// distinguished by content — see `Classifier.promptText(for:variant:)`.
private struct VariantAware: CategoryResponder {
    let primary: String
    let alternate: String
    func category(for prompt: String, allowed: [ShotsortCore.Category]) async throws -> String {
        let reply = prompt.contains("Which single category") ? alternate : primary
        return allowed.map { $0.name }.contains(reply) ? reply : Taxonomy.unsortedName
    }
}

private func bed() throws -> Paths {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    let paths = Paths(inbox: root.appendingPathComponent("ss"),
                      output: root.appendingPathComponent("ss-sorted"))
    try FileManager.default.createDirectory(at: paths.inbox,
                                            withIntermediateDirectories: true)
    try paths.ensureState()
    try JSONLStore<IndexRecord>(url: paths.index).append(
        IndexRecord(file: "a.png", ts: "t", tsSource: .filename,
                    ocr: "bank of england interest rates", chars: 30,
                    blocks: 3, density: 0.4, sceneRaw: [], faces: 0,
                    faceAreaMax: 0, domains: ["news.sky.com"], error: nil))
    return paths
}

private func writeTaxonomy(_ names: [String], to paths: Paths) throws {
    try TaxonomyStore.save(
        Taxonomy(version: 1, filterVersion: SceneFilter.filterVersion,
                 categories: names.map { Category(name: $0, desc: "d", examples: []) }),
        to: paths.taxonomy)
}

@Test func aSecondRunAgainstTheSameTaxonomyIsANoOp() async throws {
    let paths = try bed()
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    let runner = ClassifyRunner(paths: paths, responder: Fixed(reply: "News"),
                                checkAvailability: false)
    #expect(try await runner.run() == 1)
    #expect(try await runner.run() == 0)
}

@Test func editingTheTaxonomyReclassifies() async throws {
    // The spec's documented loop is undo -> edit taxonomy -> classify ->
    // apply. Skipping on filename alone would classify zero records here and
    // let apply silently replay the old category.
    let paths = try bed()
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    _ = try await ClassifyRunner(paths: paths, responder: Fixed(reply: "News"),
                                 checkAvailability: false).run()

    try writeTaxonomy(["Finance", "Unsorted"], to: paths)
    let reclassified = try await ClassifyRunner(
        paths: paths, responder: Fixed(reply: "Finance"),
        checkAvailability: false).run()
    #expect(reclassified == 1)

    let current = try ClassifyRunner(paths: paths).currentLabels()
    #expect(current.count == 1)
    #expect(current[0].category == "Finance")
}

@Test func staleAndNeverLabelledArePopulationsNotOneNumber() async throws {
    // Two index records so the two populations can differ. With a single
    // record, "stale files" and "index files not reusable" are numerically
    // identical and a test cannot tell the definitions apart — which is how
    // a count over the whole index survived review as a files-not-records fix.
    let paths = try bed()
    try JSONLStore<IndexRecord>(url: paths.index).append(
        IndexRecord(file: "b.png", ts: "t", tsSource: .filename,
                    ocr: "unrelated text here", chars: 19, blocks: 2,
                    density: 0.3, sceneRaw: [], faces: 0, faceAreaMax: 0,
                    domains: ["example.com"], error: nil))

    try writeTaxonomy(["News", "Unsorted"], to: paths)
    // Label only a.png, leaving b.png never-labelled.
    _ = try await ClassifyRunner(paths: paths, responder: Fixed(reply: "News"),
                                 checkAvailability: false).run(limit: 1)

    // No taxonomy change: b.png is ordinary work, nothing is stale.
    var work = try ClassifyRunner(paths: paths).pending()
    #expect(work.stale == 0)
    #expect(work.neverLabelled == 1)

    try writeTaxonomy(["Finance", "Unsorted"], to: paths)
    work = try ClassifyRunner(paths: paths).pending()
    // a.png is stale; b.png is still merely unlabelled. Counting the index
    // would report 2 here and print "taxonomy changed" for both.
    #expect(work.stale == 1)
    #expect(work.neverLabelled == 1)
    #expect(work.total == 2)
}

@Test func theReclassifyCountIsInFilesNotRecords() async throws {
    // labels.jsonl is append-only, so after one cycle a file owns two
    // records. Counting records would print 100 on the second pass through a
    // 50-file loop — and Task 15 Step 8 reads this number to decide whether
    // the loop is alive, so the drifting figure is the one that would
    // falsify the check.
    let paths = try bed()
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    _ = try await ClassifyRunner(paths: paths, responder: Fixed(reply: "News"),
                                 checkAvailability: false).run()

    try writeTaxonomy(["Finance", "Unsorted"], to: paths)
    _ = try await ClassifyRunner(paths: paths, responder: Fixed(reply: "Finance"),
                                 checkAvailability: false).run()

    // Third taxonomy, second reclassify: two records now exist for one file.
    try writeTaxonomy(["Markets", "Unsorted"], to: paths)
    let n = try await ClassifyRunner(paths: paths, responder: Fixed(reply: "Markets"),
                                     checkAvailability: false).run()
    #expect(n == 1)
    #expect(try JSONLStore<LabelRecord>(url: paths.labels).readAll().count == 3)
    #expect(try ClassifyRunner(paths: paths).currentLabels().count == 1)
}

@Test func currentLabelsFoldsToTheNewestRecordPerFile() throws {
    let paths = try bed()
    let store = JSONLStore<LabelRecord>(url: paths.labels)
    try store.append(LabelRecord(file: "a.png", category: "News", reason: "model",
                                 modelConfidence: nil, filterVersion: 3,
                                 taxonomySignature: "old", verifyAgreed: nil))
    try store.append(LabelRecord(file: "a.png", category: "Finance", reason: "model",
                                 modelConfidence: nil, filterVersion: 3,
                                 taxonomySignature: "new", verifyAgreed: nil))
    let current = try ClassifyRunner(paths: paths).currentLabels()
    #expect(current.count == 1)
    #expect(current[0].category == "Finance")
}

@Test func verifyRecordsTheAlternateAnswer() async throws {
    // The boolean alone can't distinguish adjacent disagreement (taxonomy
    // problem) from wild disagreement (model instability) — the alternate
    // category is what makes that diagnosis possible.
    let paths = try bed()
    try writeTaxonomy(["Finance", "Personal", "Unsorted"], to: paths)
    let runner = ClassifyRunner(
        paths: paths,
        responder: VariantAware(primary: "Finance", alternate: "Personal"),
        checkAvailability: false)
    #expect(try await runner.run(verify: true) == 1)

    let current = try runner.currentLabels()
    #expect(current.count == 1)
    #expect(current[0].category == "Finance")
    #expect(current[0].verifyAgreed == false)
    #expect(current[0].verifyAlternate == "Personal")
}

@Test func verifyAlternateIsNilWhenVerifyIsOff() async throws {
    let paths = try bed()
    try writeTaxonomy(["Finance", "Personal", "Unsorted"], to: paths)
    let runner = ClassifyRunner(
        paths: paths,
        responder: VariantAware(primary: "Finance", alternate: "Personal"),
        checkAvailability: false)
    #expect(try await runner.run(verify: false) == 1)

    let current = try runner.currentLabels()
    #expect(current.count == 1)
    #expect(current[0].verifyAgreed == nil)
    #expect(current[0].verifyAlternate == nil)
}

@Test func oldLabelRecordsWithoutTheFieldStillDecode() throws {
    // Pins backward compatibility rather than assuming it: JSONLStore.readAll
    // throws on an undecodable INTERIOR line (only the final line tolerates a
    // partial write), so two hand-written pre-change lines exercise the real
    // failure mode a stale labels.jsonl would hit.
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("jsonl")
    let line1 = #"{"category":"Finance","file":"a.png","filterVersion":3,"modelConfidence":null,"reason":"model","taxonomySignature":"sig","verifyAgreed":true}"#
    let line2 = #"{"category":"News","file":"b.png","filterVersion":3,"modelConfidence":null,"reason":"model","taxonomySignature":"sig","verifyAgreed":false}"#
    try (line1 + "\n" + line2 + "\n").write(to: url, atomically: true, encoding: .utf8)

    let records = try JSONLStore<LabelRecord>(url: url).readAll()
    #expect(records.count == 2)
    #expect(records[0].verifyAlternate == nil)
    #expect(records[1].verifyAlternate == nil)
    try? FileManager.default.removeItem(at: url)
}

/// Counts calls and answers group prompts and per-image prompts alike.
private actor CountingResponder: CategoryResponder {
    let reply: String
    private(set) var calls = 0
    init(reply: String) { self.reply = reply }
    func category(for prompt: String, allowed: [ShotsortCore.Category]) async throws -> String {
        calls += 1
        return allowed.map { $0.name }.contains(reply) ? reply : Taxonomy.unsortedName
    }
    func callCount() -> Int { calls }
}

/// Refuses group prompts (both variants), answers per-image prompts.
private actor GroupRefusingResponder: CategoryResponder {
    struct Refused: Error {}
    let reply: String
    private(set) var calls = 0
    init(reply: String) { self.reply = reply }
    func category(for prompt: String, allowed: [ShotsortCore.Category]) async throws -> String {
        calls += 1
        if prompt.contains("share one source:") || prompt.contains("Source evidence:") {
            throw Refused()
        }
        return allowed.map { $0.name }.contains(reply) ? reply : Taxonomy.unsortedName
    }
    func callCount() -> Int { calls }
}

private func addIndexRecord(_ file: String, domain: String?, to paths: Paths) throws {
    try JSONLStore<IndexRecord>(url: paths.index).append(
        IndexRecord(file: file, ts: "t", tsSource: .filename,
                    ocr: "more text for \(file)", chars: 30, blocks: 3,
                    density: 0.4, sceneRaw: [], faces: 0, faceAreaMax: 0,
                    domains: domain.map { [$0] } ?? [], error: nil))
}

@Test func aGroupIsDecidedByOneCallAndSharesTheLabel() async throws {
    // bed() seeds a.png with domain news.sky.com; a second record from the
    // same domain makes a Tier-1 group of two.
    let paths = try bed()
    try addIndexRecord("a2.png", domain: "news.sky.com", to: paths)
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    let spy = CountingResponder(reply: "News")
    let n = try await ClassifyRunner(paths: paths, responder: spy,
                                     checkAvailability: false).run()
    #expect(n == 2)
    #expect(await spy.callCount() == 1)

    let current = try ClassifyRunner(paths: paths).currentLabels()
    #expect(current.count == 2)
    #expect(current.allSatisfy { $0.category == "News" })
    #expect(current.allSatisfy { $0.reason == "group-model" })
}

@Test func limitNeverSplitsAGroup() async throws {
    // A 2-member group cannot fit in a 1-record budget; it defers whole
    // rather than labelling half a group.
    let paths = try bed()
    try addIndexRecord("a2.png", domain: "news.sky.com", to: paths)
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    let n = try await ClassifyRunner(paths: paths,
                                     responder: CountingResponder(reply: "News"),
                                     checkAvailability: false).run(limit: 1)
    #expect(n == 0)
}

@Test func aNewMemberRedecidesTheWholeGroup() async throws {
    // One group, one label — across runs. a.png is labelled alone (as a
    // domain singleton); when a2.png arrives the pair is a due group and the
    // fresh answer supersedes a.png's old row too.
    let paths = try bed()
    try writeTaxonomy(["News", "Finance", "Unsorted"], to: paths)
    _ = try await ClassifyRunner(paths: paths, responder: Fixed(reply: "News"),
                                 checkAvailability: false).run()

    try addIndexRecord("a2.png", domain: "news.sky.com", to: paths)
    let n = try await ClassifyRunner(paths: paths, responder: Fixed(reply: "Finance"),
                                     checkAvailability: false).run()
    #expect(n == 2)

    let current = try ClassifyRunner(paths: paths).currentLabels()
    #expect(current.count == 2)
    #expect(current.allSatisfy { $0.category == "Finance" })
    #expect(current.allSatisfy { $0.reason == "group-model" })
}

@Test func aRefusedGroupFallsBackToPerImage() async throws {
    let paths = try bed()
    try addIndexRecord("a2.png", domain: "news.sky.com", to: paths)
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    let spy = GroupRefusingResponder(reply: "News")
    let n = try await ClassifyRunner(paths: paths, responder: spy,
                                     checkAvailability: false).run()
    #expect(n == 2)
    // 2 refused group attempts (6-sample + 3-sample) + 2 per-image calls.
    #expect(await spy.callCount() == 4)

    let current = try ClassifyRunner(paths: paths).currentLabels()
    #expect(current.count == 2)
    #expect(current.allSatisfy { $0.category == "News" })
    #expect(current.allSatisfy { $0.reason == "model" })
}

@Test func groupVerifyStampsEveryMember() async throws {
    // VariantAware answers by prompt marker; the group alternate prompt uses
    // the same "Which single category" phrasing as the per-image alternate.
    let paths = try bed()
    try addIndexRecord("a2.png", domain: "news.sky.com", to: paths)
    try writeTaxonomy(["News", "Finance", "Unsorted"], to: paths)
    let runner = ClassifyRunner(
        paths: paths,
        responder: VariantAware(primary: "News", alternate: "Finance"),
        checkAvailability: false)
    #expect(try await runner.run(verify: true) == 2)

    let current = try runner.currentLabels()
    #expect(current.count == 2)
    #expect(current.allSatisfy { $0.category == "News" })
    #expect(current.allSatisfy { $0.verifyAgreed == false })
    #expect(current.allSatisfy { $0.verifyAlternate == "Finance" })
}

/// Group primary succeeds; group alternate refuses on both sample counts
/// (`groupCategory` retries at `groupRetrySampleCount`, same variant both
/// times). Distinguishes "verification didn't complete" from "verification
/// disagreed".
private struct GroupAlternateThrows: CategoryResponder {
    struct Refused: Error {}
    let primary: String
    func category(for prompt: String, allowed: [ShotsortCore.Category]) async throws -> String {
        if prompt.contains("Source evidence:") { throw Refused() }
        return allowed.map { $0.name }.contains(primary) ? primary : Taxonomy.unsortedName
    }
}

@Test func groupVerifyIncompleteRecordsNilNotDisagreement() async throws {
    // The alternate probe refuses twice (both sample counts), so
    // groupCategory(variant: .alternate) returns nil. That must not be
    // stamped as verifyAgreed == false — nil means verification didn't
    // complete, false means it completed and disagreed.
    let paths = try bed()
    try addIndexRecord("a2.png", domain: "news.sky.com", to: paths)
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    let runner = ClassifyRunner(
        paths: paths,
        responder: GroupAlternateThrows(primary: "News"),
        checkAvailability: false)
    #expect(try await runner.run(verify: true) == 2)

    let current = try runner.currentLabels()
    #expect(current.count == 2)
    #expect(current.allSatisfy { $0.category == "News" })
    #expect(current.allSatisfy { $0.reason == "group-model" })
    #expect(current.allSatisfy { $0.verifyAgreed == nil })
    #expect(current.allSatisfy { $0.verifyAlternate == nil })
}

@Test func limitSkipsAFullGroupButStillLabelsASmallerDueSingle() async throws {
    // Pins the skip-not-break behaviour at the group-loop budget check: a
    // group that doesn't fit the remaining limit is skipped, not a reason to
    // stop the loop — a later single can still fit.
    let paths = try bed()
    try addIndexRecord("a2.png", domain: "news.sky.com", to: paths)
    try addIndexRecord("solo.png", domain: nil, to: paths)
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    let n = try await ClassifyRunner(paths: paths,
                                     responder: Fixed(reply: "News"),
                                     checkAvailability: false).run(limit: 1)
    #expect(n == 1)

    let current = try ClassifyRunner(paths: paths).currentLabels()
    #expect(current.count == 1)
    #expect(current[0].file == "solo.png")
    #expect(current[0].reason == "model")
}

@Test func limitSkipsAFullGroupAndStillLabelsALaterSmallerGroup() async throws {
    // Discriminates continue from break at the group-loop budget check,
    // which limitSkipsAFullGroupButStillLabelsASmallerDueSingle does not: a
    // domainless single always runs in the separate singles loop regardless
    // of how the group loop terminates, so that test passes under both
    // `continue` and `break`. Two groups in the SAME loop are needed: a
    // 3-member "news.sky.com" group (via bed() + two more members) sorts
    // alphabetically before a 2-member "zzz.example" group. limit: 2 can't
    // fit the first group, so it must be skipped rather than aborting the
    // loop, for the second, smaller group to still be reached and labelled.
    let paths = try bed()
    try addIndexRecord("a2.png", domain: "news.sky.com", to: paths)
    try addIndexRecord("a3.png", domain: "news.sky.com", to: paths)
    try addIndexRecord("b1.png", domain: "zzz.example", to: paths)
    try addIndexRecord("b2.png", domain: "zzz.example", to: paths)
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    let n = try await ClassifyRunner(paths: paths,
                                     responder: Fixed(reply: "News"),
                                     checkAvailability: false).run(limit: 2)
    #expect(n == 2)

    let current = try ClassifyRunner(paths: paths).currentLabels()
    #expect(Set(current.map(\.file)) == ["b1.png", "b2.png"])
    #expect(current.allSatisfy { $0.category == "News" })
    #expect(current.allSatisfy { $0.reason == "group-model" })
}

private func addSceneRecord(_ file: String, scene: String, to paths: Paths) throws {
    try JSONLStore<IndexRecord>(url: paths.index).append(
        IndexRecord(file: file, ts: "t", tsSource: .filename,
                    ocr: "scene text for \(file)", chars: 30, blocks: 3,
                    density: 0.1,
                    sceneRaw: [SceneObservation(identifier: scene, confidence: 0.8)],
                    faces: 0, faceAreaMax: 0, domains: [], error: nil))
}

/// Answers group prompts with one reply and per-image prompts with another,
/// so tests can distinguish a stamped group verdict from a fallback.
private struct SplitReply: CategoryResponder {
    let group: String
    let perImage: String
    func category(for prompt: String, allowed: [ShotsortCore.Category]) async throws -> String {
        let reply = prompt.contains("share one source:")
            || prompt.contains("Source evidence:") ? group : perImage
        return allowed.map { $0.name }.contains(reply) ? reply : Taxonomy.unsortedName
    }
}

@Test func aSceneGroupVerdictOfUnsortedFallsBackToPerImage() async throws {
    // Measured on the real index: 173 records across 19 scene groups were
    // stamped Unsorted wholesale, while per-image had sorted 164 of them.
    // A scene group's shared evidence is weak; when the model looks at it
    // and says "no one category", that is the grouping failing, not the
    // members being unsortable — so the members get individual answers.
    let paths = try bed()
    try addSceneRecord("m1.png", scene: "chart", to: paths)
    try addSceneRecord("m2.png", scene: "chart", to: paths)
    try addSceneRecord("m3.png", scene: "chart", to: paths)
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    _ = try await ClassifyRunner(paths: paths,
                                 responder: SplitReply(group: "Unsorted",
                                                       perImage: "News"),
                                 checkAvailability: false).run()

    let scene = try ClassifyRunner(paths: paths).currentLabels()
        .filter { $0.file.hasPrefix("m") }
    #expect(scene.count == 3)
    #expect(scene.allSatisfy { $0.category == "News" })
    #expect(scene.allSatisfy { $0.reason == "model" })
}

@Test func aDomainGroupVerdictOfUnsortedIsStamped() async throws {
    // A domain IS a source; its Unsorted is a real judgment (one rename
    // fixes it), not a failed grouping. Only scene groups fall back.
    let paths = try bed()
    try addIndexRecord("a2.png", domain: "news.sky.com", to: paths)
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    _ = try await ClassifyRunner(paths: paths,
                                 responder: SplitReply(group: "Unsorted",
                                                       perImage: "News"),
                                 checkAvailability: false).run()

    let current = try ClassifyRunner(paths: paths).currentLabels()
    #expect(current.count == 2)
    #expect(current.allSatisfy { $0.category == "Unsorted" })
    #expect(current.allSatisfy { $0.reason == "group-model" })
}

@Test func progressCountsRecordsAndReachesTheTotal() async throws {
    // A 2-member group plus one domainless single: 3 records, 2 writes.
    let paths = try bed()
    try addIndexRecord("a2.png", domain: "news.sky.com", to: paths)
    try addIndexRecord("solo.png", domain: nil, to: paths)
    try writeTaxonomy(["News", "Unsorted"], to: paths)

    var seen: [ProgressUpdate] = []
    let n = try await ClassifyRunner(paths: paths,
                                     responder: Fixed(reply: "News"),
                                     checkAvailability: false)
        .run(onProgress: { seen.append($0) })
    #expect(n == 3)
    // Leading 0 is the opening paint, before the first model call.
    #expect(seen.map(\.done) == [0, 2, 3])
    // Fresh index, no limit: the baseline is 0 and the run can reach it all.
    #expect(seen.allSatisfy { $0.total == 3 && $0.ceiling == 3 })
}

@Test func aFallbackGroupWithReusableMembersStillReachesTheTotal() async throws {
    // Extract more screenshots from a source already classified, then
    // reclassify. The group refused once and its members took individual
    // labels, so they are reusable; the new member is not. plannedTotal
    // counts all three, but the fallback path requeues only the new one —
    // without crediting the other two, a fully-completed run ends at 1/3.
    let paths = try bed()
    try addIndexRecord("a2.png", domain: "news.sky.com", to: paths)
    try writeTaxonomy(["News", "Unsorted"], to: paths)

    let first = try await ClassifyRunner(
        paths: paths, responder: GroupRefusingResponder(reply: "News"),
        checkAvailability: false).run()
    #expect(first == 2)

    try addIndexRecord("a3.png", domain: "news.sky.com", to: paths)
    var calls: [ProgressUpdate] = []
    let second = try await ClassifyRunner(
        paths: paths, responder: GroupRefusingResponder(reply: "News"),
        checkAvailability: false).run(onProgress: { calls.append($0) })

    // One record classified this run, two credited as already labelled.
    #expect(second == 1)
    #expect(calls.last == ProgressUpdate(done: 3, total: 3, ceiling: 3))
}

@Test func aLimitedRunReportsACeilingBelowTheTotal() async throws {
    // Three distinct domains means three singles and no groups. --limit 1
    // stops after one, so the ETA must be computed against 1, not 3.
    let paths = try bed()
    try addIndexRecord("b.png", domain: "example.com", to: paths)
    try addIndexRecord("c.png", domain: "other.com", to: paths)
    try writeTaxonomy(["News", "Unsorted"], to: paths)

    var calls: [ProgressUpdate] = []
    _ = try await ClassifyRunner(paths: paths, responder: Fixed(reply: "News"),
                                 checkAvailability: false)
        .run(limit: 1, onProgress: { calls.append($0) })

    #expect(calls == [ProgressUpdate(done: 0, total: 3, ceiling: 1),
                      ProgressUpdate(done: 1, total: 3, ceiling: 1)])
}

@Test func aNoOpRunReportsNoProgressAtAll() async throws {
    // The opening paint must not fire when there is nothing to do. A
    // fully-classified collection prints its summary line and nothing else,
    // and `ProgressReporter.finish()` stays a no-op because nothing was
    // emitted — the behaviour the bare counter had before the bar existed.
    let paths = try bed()
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    _ = try await ClassifyRunner(paths: paths, responder: Fixed(reply: "News"),
                                 checkAvailability: false).run()

    var calls: [ProgressUpdate] = []
    let second = try await ClassifyRunner(paths: paths,
                                          responder: Fixed(reply: "News"),
                                          checkAvailability: false)
        .run(onProgress: { calls.append($0) })

    #expect(second == 0)
    #expect(calls.isEmpty)
}

@Test func aResumedRunCountsAgainstTheWholeIndex() async throws {
    // Two records already labelled and not due, one new: baseline is 2. An
    // implementation that dropped baseline would report done 1 and ceiling
    // 1 — the bar reopening at zero on every resume, which is exactly what
    // collection-relative counting exists to prevent.
    let paths = try bed()
    try addIndexRecord("b.png", domain: "example.com", to: paths)
    try writeTaxonomy(["News", "Unsorted"], to: paths)
    _ = try await ClassifyRunner(paths: paths, responder: Fixed(reply: "News"),
                                 checkAvailability: false).run()

    try addIndexRecord("c.png", domain: "other.com", to: paths)
    var calls: [ProgressUpdate] = []
    let n = try await ClassifyRunner(paths: paths, responder: Fixed(reply: "News"),
                                     checkAvailability: false)
        .run(onProgress: { calls.append($0) })

    #expect(n == 1)
    // The opening paint carries the baseline: a resumed run shows where the
    // collection already stands, immediately, instead of a blank terminal
    // until the first ~11s model call returns.
    #expect(calls == [ProgressUpdate(done: 2, total: 3, ceiling: 3),
                      ProgressUpdate(done: 3, total: 3, ceiling: 3)])
}

@Test func taxonomySignatureIsStableAcrossProcessesAndOrderings() {
    let a = Taxonomy(version: 1, filterVersion: 3, categories: [
        Category(name: "News", desc: "d", examples: []),
        Category(name: "Unsorted", desc: "d", examples: []),
    ])
    let b = Taxonomy(version: 1, filterVersion: 3, categories: [
        Category(name: "Unsorted", desc: "d", examples: []),
        Category(name: "News", desc: "d", examples: []),
    ])
    // Reordering is not a taxonomy change. A per-process seeded hash would
    // also break this by differing between runs.
    #expect(a.signature == b.signature)
    #expect(!a.signature.isEmpty)
}
