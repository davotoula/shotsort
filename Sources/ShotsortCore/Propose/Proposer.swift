import Foundation
import FoundationModels

public enum ProposeError: Error, Equatable {
    case budgetExceeded(String)
    case tooFewCategories(kept: Int, required: Int)
}

public protocol NameProposer: Sendable {
    func propose(batch: [String]) async throws -> [Category]
    /// One call over the full candidate list: merge near-duplicates and fold
    /// one-off specifics into broader groups. Output is schema-bounded to
    /// 8–15 items when the model is behind it; stubs may misbehave, which is
    /// why Proposer re-guards the output.
    func reduce(candidates: [Category]) async throws -> [Category]
}

/// One session per call, so a long-tail batch cannot bias the batch that
/// follows, and a refused reduction retry starts clean.
///
/// Both calls use guided generation. Free text was tried and is the recorded
/// failure mode of this stage: the model ignored the requested format
/// (markdown lists needed a cleanName scraper) and echoed candidate counts
/// back instead of merging. A decode-time schema removes that class — the
/// model cannot emit list markers into `name`, and cannot return 60
/// categories through an array bounded to 15.
public struct OnDeviceProposer: NameProposer {
    public init() {}

    @Generable
    struct CategoryDraft {
        @Guide(description: "A short, general folder name someone would "
            + "reuse for hundreds of screenshots — 1 to 4 words, a broad "
            + "topic like Finance or Travel, never a description of one "
            + "screenshot")
        var name: String
        @Guide(description: "One line describing what belongs in this folder")
        var desc: String
    }

    @Generable
    struct BatchDrafts {
        @Guide(description: "3 to 6 folder-name proposals", .count(3...6))
        var categories: [CategoryDraft]
    }

    @Generable
    struct TaxonomyDraft {
        // 8 here is not Proposer.reduceFloor — they answer different
        // questions. This lower bound is the fewest categories a reduction
        // may return, enforced by constrained decoding on every reduce()
        // call. Proposer.reduceFloor is the fewest candidates that make
        // attempting that call worthwhile in the first place; see its doc
        // comment for why the two are not the same number.
        @Guide(description: "The merged set of 8 to 15 general categories",
               .count(8...15))
        var categories: [CategoryDraft]
    }

    /// Wider than the classify deadline: these calls generate multi-field
    /// structured drafts, not one constrained name, and a slow-but-live
    /// generation must not be mistaken for a wedge.
    static let callDeadline: TimeInterval = 90

    public func propose(batch: [String]) async throws -> [Category] {
        // Session built inside the watchdog: the retry after an abandoned
        // wedge starts from a fresh session. See ModelWatchdog.
        try await ModelWatchdog.run(deadline: Self.callDeadline) {
            let session = LanguageModelSession(
                instructions: "Propose general folder names for organising a "
                    + "large screenshot collection. Each name must fit hundreds "
                    + "of screenshots, not describe one.")
            let response = try await session.respond(
                to: batch.joined(separator: "\n---\n"),
                generating: BatchDrafts.self)
            return response.content.categories.map {
                Category(name: $0.name, desc: $0.desc, examples: [])
            }
        }
    }

    public func reduce(candidates: [Category]) async throws -> [Category] {
        let list = candidates.map { "\($0.name) — \($0.desc)" }
            .joined(separator: "\n")
        return try await ModelWatchdog.run(deadline: Self.callDeadline) {
            let session = LanguageModelSession(
                instructions: "Merge candidate folder names into a smaller set "
                    + "of general categories. Combine near-duplicates into one "
                    + "name and fold overly specific one-offs into broader "
                    + "groups.")
            let response = try await session.respond(
                to: "Merge these candidate folder names:\n\(list)",
                generating: TaxonomyDraft.self)
            return response.content.categories.map {
                Category(name: $0.name, desc: $0.desc, examples: [])
            }
        }
    }
}

/// How the candidate list was reduced. `deterministicFallback` means the
/// model reduction failed twice and the draft is unconsolidated candidate
/// names ranked by recurrence — main.swift warns on stderr.
public enum ReductionOutcome: Sendable, Equatable {
    case model
    case deterministicFallback
    /// The candidate list was below Proposer.reduceFloor, so reduce() was
    /// never called: at or below Proposer.targetCategories the list already
    /// fits what the pipeline keeps, so truncation alone suffices and a
    /// reduce call could only degrade the result. Not a warning case.
    case notNeeded
}

public struct ProposeResult: Sendable {
    public let taxonomy: Taxonomy
    public let reduction: ReductionOutcome
    public init(taxonomy: Taxonomy, reduction: ReductionOutcome) {
        self.taxonomy = taxonomy
        self.reduction = reduction
    }
}

public struct Proposer {
    public static let batchSize = 12
    public static let maxProposeCalls = 20
    public static let targetCategories = 15
    /// Floor on surviving categories, excluding Unsorted. Without it, a run
    /// whose every candidate was dropped still produces a valid taxonomy
    /// containing only Unsorted. 2, not 1: a taxonomy of one real category
    /// plus Unsorted is a degenerate outcome over a real-sized index — the
    /// proposal stage has essentially failed — and that should raise rather
    /// than be written to disk.
    public static let minCategories = 2
    /// Reduction is attempted only when there are more candidates than the
    /// pipeline will keep. At or below `targetCategories` the list already
    /// fits and truncation alone suffices, so a reduce call could only
    /// degrade it — and near the schema's `.count(8...15)` lower bound it
    /// would force the model to pad the count with invented categories to
    /// satisfy a minimum it cannot otherwise reach.
    public static let reduceFloor = targetCategories + 1

    private let proposer: NameProposer

    public init(proposer: NameProposer) {
        self.proposer = proposer
    }

    /// Fold-dedupe (the comparison APFS performs on filenames) and rank by how
    /// often a spelling recurred across batches, most frequent first, folded
    /// name as the deterministic tie-break. Model output is filtered, not
    /// trusted: an invalid name drops that entry, never the stage.
    static func rankedDeduped(_ candidates: [Category]) -> [Category] {
        struct Group { let key: String; var name: String; var desc: String; var count: Int }
        var order: [String] = []
        var groups: [String: Group] = [:]
        for c in candidates where c.name != Taxonomy.unsortedName {
            guard TaxonomyStore.isValidName(c.name) else { continue }
            let key = TaxonomyStore.folded(c.name)
            if var g = groups[key] {
                g.count += 1
                groups[key] = g
            } else {
                groups[key] = Group(key: key, name: c.name, desc: c.desc, count: 1)
                order.append(key)
            }
        }
        // Sort by count descending, then by folded name ascending. Never rely
        // on dictionary iteration order.
        return order.map { groups[$0]! }
            .sorted { a, b in
                a.count != b.count ? a.count > b.count : a.key < b.key
            }
            .map { Category(name: $0.name, desc: $0.desc, examples: []) }
    }

    public func run(records: [IndexRecord]) async throws -> ProposeResult {
        let samples = Sampler.sample(records).map(Sampler.sampleText)
        var calls = 0

        func budgeted() throws {
            calls += 1
            guard calls <= Self.maxProposeCalls else {
                throw ProposeError.budgetExceeded(
                    "exceeded maxProposeCalls (\(Self.maxProposeCalls))")
            }
        }

        var candidates: [Category] = []
        var cursor = 0
        while cursor < samples.count {
            let batch = Array(samples[cursor..<min(cursor + Self.batchSize,
                                                   samples.count)])
            try budgeted()
            candidates.append(contentsOf: try await proposer.propose(batch: batch))
            cursor += Self.batchSize
        }

        let ranked = Self.rankedDeduped(candidates)

        // Reduction does not draw on the propose-call budget: maxProposeCalls
        // bounds batch generation; reduction is bounded here — at most two
        // calls. Retry once because a guardrail refusal is sampling noise;
        // after a second failure fall back to the ranked candidates rather
        // than aborting, because ~12 successful batch calls precede this
        // point and the taxonomy is hand-edited anyway. main.swift renders
        // the fallback as a stderr warning.
        var reduction: ReductionOutcome
        var deduped: [Category]
        if ranked.count < Self.reduceFloor {
            // At or below what the pipeline keeps: truncation to
            // targetCategories already produces a list this size, so a
            // reduce call could only degrade it — and near the schema's
            // .count(8...15) floor would force the model to pad the count
            // with fabricated categories. Skip the call.
            deduped = ranked
            reduction = .notNeeded
        } else {
            reduction = .model
            do {
                deduped = try await proposer.reduce(candidates: ranked)
            } catch {
                do {
                    deduped = try await proposer.reduce(candidates: ranked)
                } catch {
                    deduped = ranked
                    reduction = .deterministicFallback
                }
            }
        }

        // Post-pass on the reducer's output. NOT rankedDeduped: with every
        // reduced name occurring once, count-ranking would degenerate to
        // alphabetical order — the exact failure this redesign removes. The
        // reducer's order is meaningful (it is what the user sees), so
        // filter and fold in place.
        var seen = Set<String>()
        var vetted: [Category] = []
        for c in deduped where c.name != Taxonomy.unsortedName {
            guard TaxonomyStore.isValidName(c.name) else { continue }
            guard seen.insert(TaxonomyStore.folded(c.name)).inserted else { continue }
            vetted.append(c)
        }
        deduped = Array(vetted.prefix(Self.targetCategories))

        guard deduped.count >= Self.minCategories else {
            throw ProposeError.tooFewCategories(kept: deduped.count,
                                                required: Self.minCategories)
        }

        deduped.append(Category(
            name: Taxonomy.unsortedName,
            desc: "No usable signal, or fits no other category.",
            examples: []))

        let taxonomy = Taxonomy(version: 1,
                                filterVersion: SceneFilter.filterVersion,
                                categories: deduped)
        return ProposeResult(taxonomy: taxonomy, reduction: reduction)
    }
}
