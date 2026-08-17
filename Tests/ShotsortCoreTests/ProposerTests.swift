import Testing
// No `import Foundation` here: this file never uses a Foundation symbol, and
// importing it (as elsewhere in this suite) transitively pulls in ObjC's
// runtime.h, whose `Category` typedef collides with ShotsortCore.Category
// wherever this file names `[Category]` in a type position (conforming to
// NameProposer) rather than as an initializer call — "'Category' is
// ambiguous for type lookup in this context".
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

private actor CountingProposer: NameProposer {
    private(set) var calls = 0
    private let namesPerBatch: Int

    init(namesPerBatch: Int = 3) {
        self.namesPerBatch = namesPerBatch
    }

    func propose(batch: [String]) async throws -> [Category] {
        calls += 1
        let n = calls
        return (0..<namesPerBatch).map {
            Category(name: "Cat\(n)_\($0)", desc: "d", examples: [])
        }
    }

    func reduce(candidates: [Category]) async throws -> [Category] { candidates }

    func callCount() -> Int { calls }
}

@Test func alwaysEmitsUnsorted() async throws {
    let t = try await Proposer(proposer: CountingProposer()).run(records: synthetic(300)).taxonomy
    #expect(t.names.contains("Unsorted"))
}

@Test func outputLoadsCleanlyThroughTaxonomyStore() async throws {
    // The round-trip that would have caught a missing Unsorted injection.
    let t = try await Proposer(proposer: CountingProposer()).run(records: synthetic(300)).taxonomy
    try TaxonomyStore.validate(t)
}

@Test func recordsTheFilterVersion() async throws {
    let t = try await Proposer(proposer: CountingProposer()).run(records: synthetic(300)).taxonomy
    #expect(t.filterVersion == SceneFilter.filterVersion)
}

@Test func staysInsideTheCallBudgetOnALargeIndex() async throws {
    let spy = CountingProposer()
    _ = try await Proposer(proposer: spy).run(records: synthetic(1500))
    #expect(await spy.callCount() <= Proposer.maxProposeCalls)
}

private actor DirtyProposer: NameProposer {
    func propose(batch: [String]) async throws -> [Category] {
        [Category(name: "Travel", desc: "d", examples: []),
         Category(name: "News", desc: "d", examples: []),
         Category(name: "News / Current Affairs", desc: "d", examples: []),
         Category(name: String(repeating: "x", count: 80), desc: "d", examples: []),
         Category(name: ".hidden", desc: "d", examples: [])]
    }

    func reduce(candidates: [Category]) async throws -> [Category] { candidates }
}

@Test func invalidModelNamesAreDroppedNotFatal() async throws {
    // One stray "/" must not discard a whole ~12-call stage. The survivors
    // load cleanly; the offenders are gone.
    let t = try await Proposer(proposer: DirtyProposer()).run(records: synthetic(300)).taxonomy
    try TaxonomyStore.validate(t)
    #expect(!t.names.contains { $0.contains("/") })
    #expect(!t.names.contains { $0.hasPrefix(".") })
    #expect(t.names.contains("Unsorted"))
    #expect(t.names.contains("Travel"))
    #expect(t.names.contains("News"))
}

@Test func aTaxonomyOfOnlyUnsortedIsRejected() async {
    // Every candidate dropped as invalid leaves Unsorted alone, which
    // validate() accepts — non-empty and containing Unsorted. propose would
    // report "proposed 1 categories" and classify would send all 1,494
    // images to Unsorted, with every stage behaving as specified.
    struct AllBad: NameProposer {
        func propose(batch: [String]) async throws -> [Category] {
            [Category(name: "News / Current Affairs", desc: "d", examples: []),
             Category(name: ".hidden", desc: "d", examples: [])]
        }

        func reduce(candidates: [Category]) async throws -> [Category] { candidates }
    }
    await #expect(throws: ProposeError.tooFewCategories(
        kept: 0, required: Proposer.minCategories)) {
        _ = try await Proposer(proposer: AllBad()).run(records: synthetic(300))
    }
}

private struct FixedSetProposer: NameProposer {
    func propose(batch: [String]) async throws -> [Category] {
        [Category(name: "Travel", desc: "d1", examples: []),
         Category(name: "News", desc: "d2", examples: []),
         Category(name: "Shopping", desc: "d3", examples: [])]
    }

    func reduce(candidates: [Category]) async throws -> [Category] { candidates }
}

@Test func consolidationIsDeterministic() async throws {
    // Deterministic reduction (fold-dedupe + frequency rank with a folded-
    // name tie-break) must not depend on dictionary iteration order: two
    // runs over identical input must produce identical output, in the same
    // order.
    let records = synthetic(300)
    let t1 = try await Proposer(proposer: FixedSetProposer()).run(records: records).taxonomy
    let t2 = try await Proposer(proposer: FixedSetProposer()).run(records: records).taxonomy
    #expect(t1.names == t2.names)
}

private actor CommonRareProposer: NameProposer {
    private var calls = 0
    func propose(batch: [String]) async throws -> [Category] {
        calls += 1
        var result = [Category(name: "Common", desc: "d", examples: [])]
        if calls == 1 {
            result.append(Category(name: "Rare", desc: "d", examples: []))
        }
        return result
    }

    func reduce(candidates: [Category]) async throws -> [Category] { candidates }
}

@Test func moreFrequentNamesRankHigher() async throws {
    // A name every batch agrees on should outrank one a single batch
    // proposed once.
    let t = try await Proposer(proposer: CommonRareProposer()).run(records: synthetic(300)).taxonomy
    let names = t.names
    let commonIdx = try #require(names.firstIndex(of: "Common"))
    let rareIdx = try #require(names.firstIndex(of: "Rare"))
    #expect(commonIdx < rareIdx)
}

private struct CaseVariantProposer: NameProposer {
    func propose(batch: [String]) async throws -> [Category] {
        // A second, distinct name so the run clears minCategories — the
        // fold-collapse of Travel/travel is what this test is checking, not
        // the floor guard.
        [Category(name: "Travel", desc: "d", examples: []),
         Category(name: "travel", desc: "d", examples: []),
         Category(name: "News", desc: "d", examples: [])]
    }

    func reduce(candidates: [Category]) async throws -> [Category] { candidates }
}

@Test func namesDifferingOnlyByCaseCollapseToOne() async throws {
    // APFS is case-insensitive by default, so two entries differing only in
    // case are one directory. TaxonomyStore.folded is the fold used to dedupe.
    let t = try await Proposer(proposer: CaseVariantProposer()).run(records: synthetic(300)).taxonomy
    let survivors = t.names.filter { TaxonomyStore.folded($0) == TaxonomyStore.folded("Travel") }
    #expect(survivors.count == 1)
}

private struct MergingReducer: NameProposer {
    func propose(batch: [String]) async throws -> [Category] {
        // Proposer.reduceFloor unique candidates: enough to clear the floor
        // so this test still exercises the reduce() call it is named for.
        (0..<Proposer.reduceFloor).map {
            Category(name: "Candidate \($0)", desc: "d", examples: [])
        }
    }
    func reduce(candidates: [Category]) async throws -> [Category] {
        [Category(name: "Finance", desc: "money things", examples: []),
         Category(name: "Travel", desc: "flights and hotels", examples: [])]
    }
}

@Test func reducerOutputBecomesTheTaxonomy() async throws {
    // The reducer's merged set IS the taxonomy (plus Unsorted), in the
    // reducer's order — not the raw candidates, not re-sorted.
    let result = try await Proposer(proposer: MergingReducer())
        .run(records: synthetic(300))
    #expect(result.reduction == .model)
    #expect(result.taxonomy.names == ["Finance", "Travel", "Unsorted"])
}

private enum StubError: Error { case refused }

private actor FlakyReducer: NameProposer {
    private var reduceCalls = 0
    func propose(batch: [String]) async throws -> [Category] {
        // Proposer.reduceFloor unique candidates: clears the floor so this
        // test still exercises the retry-then-succeed path it is named for.
        (0..<Proposer.reduceFloor).map {
            Category(name: "Candidate \($0)", desc: "d", examples: [])
        }
    }
    func reduce(candidates: [Category]) async throws -> [Category] {
        reduceCalls += 1
        if reduceCalls == 1 { throw StubError.refused }
        return [Category(name: "Merged A", desc: "d", examples: []),
                Category(name: "Merged B", desc: "d", examples: [])]
    }
    func reduceCallCount() -> Int { reduceCalls }
}

@Test func reductionRetriesOnceAfterAFailure() async throws {
    // A guardrail refusal is sampling noise, not a verdict; one retry is
    // cheap. Success on the retry is still a model reduction.
    let spy = FlakyReducer()
    let result = try await Proposer(proposer: spy).run(records: synthetic(300))
    #expect(await spy.reduceCallCount() == 2)
    #expect(result.reduction == .model)
    #expect(result.taxonomy.names.contains("Merged A"))
}

private struct BrokenReducer: NameProposer {
    func propose(batch: [String]) async throws -> [Category] {
        // Proposer.reduceFloor unique candidates: clears the floor so this
        // test still exercises the deterministic-fallback path it is named
        // for. Travel/News anchor the assertions below (the fallback
        // returns the raw candidates, alphabetically ranked by folded name,
        // truncated to targetCategories) — the "Zzz" prefix on the padding
        // keeps it sorting after Travel/News so truncation cannot drop them.
        var names = ["Travel", "News"]
        names += (names.count..<Proposer.reduceFloor).map { "Zzz Candidate \($0)" }
        return names.map { Category(name: $0, desc: "d", examples: []) }
    }
    func reduce(candidates: [Category]) async throws -> [Category] {
        throw StubError.refused
    }
}

@Test func persistentReductionFailureFallsBackDeterministically() async throws {
    // The fallback path runs exactly when the model is misbehaving — the
    // moment it is least observed — so it gets its own test. The stage must
    // still write a draft: unconsolidated beats aborted, because ~12
    // successful batch calls precede this point.
    let result = try await Proposer(proposer: BrokenReducer())
        .run(records: synthetic(300))
    #expect(result.reduction == .deterministicFallback)
    #expect(result.taxonomy.names.contains("Travel"))
    #expect(result.taxonomy.names.contains("News"))
    #expect(result.taxonomy.names.contains("Unsorted"))
    try TaxonomyStore.validate(result.taxonomy)
}

private struct OverCountReducer: NameProposer {
    func propose(batch: [String]) async throws -> [Category] {
        // Proposer.reduceFloor unique candidates: clears the floor so this
        // test still exercises the truncation it is named for.
        (0..<Proposer.reduceFloor).map { Category(name: "Seed \($0)", desc: "d", examples: []) }
    }
    func reduce(candidates: [Category]) async throws -> [Category] {
        (0..<20).map { Category(name: "R\($0)", desc: "d", examples: []) }
    }
}

@Test func reducerOutputIsTruncatedToTheTarget() async throws {
    // The schema bounds the real model to 15, but the seam admits stubs and
    // future implementations; a misbehaving reducer must not crash the
    // pipeline or oversize the taxonomy.
    let result = try await Proposer(proposer: OverCountReducer())
        .run(records: synthetic(300))
    #expect(result.taxonomy.categories.count == Proposer.targetCategories + 1) // +Unsorted
}

private struct DupAndDirtyReducer: NameProposer {
    func propose(batch: [String]) async throws -> [Category] {
        // Proposer.reduceFloor unique candidates: clears the floor so this
        // test still exercises the fold/filter of the reducer's output.
        (0..<Proposer.reduceFloor).map { Category(name: "Seed \($0)", desc: "d", examples: []) }
    }
    func reduce(candidates: [Category]) async throws -> [Category] {
        [Category(name: "Finance", desc: "money", examples: []),
         Category(name: "finance", desc: "money again", examples: []),
         Category(name: "News / Current Affairs", desc: "slash", examples: []),
         Category(name: ".hidden", desc: "dot", examples: []),
         Category(name: "Travel", desc: "trips", examples: [])]
    }
}

@Test func reducerOutputIsFoldedAndValidated() async throws {
    // The schema cannot stop the model emitting Finance twice or a name
    // containing "/". Fold and filter the output exactly as candidate input
    // is folded and filtered — preserving the reducer's order, which is the
    // order the user sees in taxonomy.json.
    let result = try await Proposer(proposer: DupAndDirtyReducer())
        .run(records: synthetic(300))
    #expect(result.reduction == .model)
    #expect(result.taxonomy.names == ["Finance", "Travel", "Unsorted"])
}

private actor SmallCandidateProposer: NameProposer {
    private(set) var reduceCalls = 0
    func propose(batch: [String]) async throws -> [Category] {
        // Every batch agrees on the same 3 names, so ranked-deduped
        // candidates never reach Proposer.reduceFloor regardless of batch
        // count — 3 is far below the floor either side of this change.
        [Category(name: "Travel", desc: "d", examples: []),
         Category(name: "News", desc: "d", examples: []),
         Category(name: "Shopping", desc: "d", examples: [])]
    }

    func reduce(candidates: [Category]) async throws -> [Category] {
        reduceCalls += 1
        return candidates
    }

    func reduceCallCount() -> Int { reduceCalls }
}

@Test func belowReductionFloorSkipsReduceEntirely() async throws {
    // Fewer than Proposer.reduceFloor candidates: reduce() must not be
    // called at all. 3 candidates is far below the floor, so this pins the
    // general skip behaviour rather than the exact boundary — see
    // exactlyTargetCategoriesSkipsReduction below for the boundary itself.
    let spy = SmallCandidateProposer()
    let result = try await Proposer(proposer: spy).run(records: synthetic(300))
    #expect(await spy.reduceCallCount() == 0)
    #expect(result.reduction == .notNeeded)
    #expect(result.taxonomy.names.contains("Travel"))
    #expect(result.taxonomy.names.contains("News"))
    #expect(result.taxonomy.names.contains("Shopping"))
    #expect(result.taxonomy.names.contains("Unsorted"))
}

/// Returns a fixed set of N distinct, valid candidate names on every batch
/// call, so ranked-deduped candidates land at exactly N regardless of how
/// many batches Sampler produces. Exists to pin the reduceFloor boundary
/// precisely, which the hand-picked fixtures above cannot express.
private actor FixedNameSetProposer: NameProposer {
    private(set) var reduceCalls = 0
    private let names: [Category]

    init(count: Int) {
        names = (0..<count).map {
            Category(name: "Boundary \($0)", desc: "d", examples: [])
        }
    }

    func propose(batch: [String]) async throws -> [Category] { names }

    func reduce(candidates: [Category]) async throws -> [Category] {
        reduceCalls += 1
        return candidates
    }

    func reduceCallCount() -> Int { reduceCalls }
}

@Test func exactlyTargetCategoriesSkipsReduction() async throws {
    // Exactly Proposer.targetCategories candidates: the pipeline keeps at
    // most that many anyway, so reduce() must not be called, and all of
    // them must survive truncation into the taxonomy.
    let spy = FixedNameSetProposer(count: Proposer.targetCategories)
    let result = try await Proposer(proposer: spy).run(records: synthetic(300))
    #expect(await spy.reduceCallCount() == 0)
    #expect(result.reduction == .notNeeded)
    // +1 for Unsorted; all targetCategories candidates survived.
    #expect(result.taxonomy.categories.count == Proposer.targetCategories + 1)
}

@Test func oneOverTargetCategoriesTriggersExactlyOneReduceCall() async throws {
    // One more candidate than the pipeline keeps is enough to cross
    // Proposer.reduceFloor and make a single reduce() call worthwhile.
    let spy = FixedNameSetProposer(count: Proposer.targetCategories + 1)
    _ = try await Proposer(proposer: spy).run(records: synthetic(300))
    #expect(await spy.reduceCallCount() == 1)
}
