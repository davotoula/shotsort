import Foundation

public struct ClassifyRunner {
    private let paths: Paths
    private let responder: CategoryResponder
    private let checkAvailability: Bool

    /// `responder` is injectable so the resume-and-invalidate logic can be
    /// tested without a model; `checkAvailability` is off in tests because
    /// Apple Intelligence state is not a property of this code.
    public init(paths: Paths,
                responder: CategoryResponder = OnDeviceResponder(),
                checkAvailability: Bool = true) {
        self.paths = paths
        self.responder = responder
        self.checkAvailability = checkAvailability
    }

    /// Resumable within a run, and correctly invalidated across a taxonomy
    /// change. A label is reusable only if it was produced against BOTH the
    /// current taxonomy and the current filter constants.
    ///
    /// Skipping on filename alone would be correct within a run and wrong
    /// across the spec's documented loop (undo -> edit taxonomy -> classify
    /// -> apply): every file would already be in labels.jsonl, classify would
    /// process zero records, and apply would silently re-apply the previous
    /// taxonomy's answers while appearing to work.
    /// `limit` bounds how many records this invocation classifies. The stage
    /// is resumable, so a limited run is a prefix of a full one — which is
    /// what makes the 50-image smoke run possible without seeding the label
    /// file with synthetic rows.
    ///
    /// **The prefix property depends on stable ordering.** `GroupPlanner.plan`
    /// orders its output deterministically — groups in planner order, then
    /// singles by filename — and this loop walks groups then singles in that
    /// order, so "the first N eligible records" names the same set on every
    /// invocation. Task 15's restore step relies on it directly:
    /// after the taxonomy is restored, `reusable` is empty and the first 50
    /// non-reusable records are the same 50 classified earlier. If either
    /// side ever became unordered, the round trip would silently classify a
    /// different 50 and the check would still appear to pass.
    public func run(verify: Bool = false, limit: Int? = nil,
                    onProgress: ((ProgressUpdate) -> Void)? = nil)
        async throws -> Int {
        try Preflight.run()
        if checkAvailability { try ModelAvailability.check() }

        // Each input is loaded exactly once and handed to the pure form.
        let taxonomy = try TaxonomyStore.load(from: paths.taxonomy)
        let index = try JSONLStore<IndexRecord>(url: paths.index).readAll()
        let labelStore = JSONLStore<LabelRecord>(url: paths.labels)
        let work = Self.pending(taxonomy: taxonomy, index: index,
                                labels: try labelStore.readAll())
        let reusable = work.reusable

        // Only STALE files mean "changed". A file that has never been
        // labelled is ordinary work, not evidence of a taxonomy edit —
        // counting the whole index here would print
        // "reclassifying 1444 records" on a plain resume after
        // `classify --limit 50`, with nothing having changed at all.
        if work.stale > 0 {
            // State what this invocation will actually do when --limit is in
            // force, so the banner and the closing "classified N records" do
            // not print adjacently with two different numbers and no
            // explanation of why they differ.
            let thisRun = min(limit ?? work.total, work.total)
            if thisRun < work.stale {
                print("taxonomy or filter changed — \(work.stale) stale, "
                      + "classifying \(thisRun) this run")
            } else {
                print("taxonomy or filter changed — reclassifying \(work.stale) records")
            }
        }

        let classifier = Classifier(taxonomy: taxonomy, responder: responder)
        let (groups, singles) = GroupPlanner.plan(index)

        // A group is due when ANY member needs a label. Deciding it
        // supersedes EVERY member's row (append-only file, newest row per
        // file wins), so "one group, one label" survives resumes and
        // taxonomy edits instead of freezing a member on a stale answer.
        let dueGroups = groups.filter { g in
            g.members.contains { !reusable.contains($0.file) }
        }
        let dueSingles = singles.filter { !reusable.contains($0.file) }

        // Progress counts records, not model calls — the user is waiting on
        // 1,494 files, not on however many calls they collapse into. Counts
        // are collection-relative: `done` includes work recorded before this
        // process started, so a --supervise restart resumes the bar rather
        // than reopening it at zero.
        let plannedTotal = dueGroups.reduce(0) { $0 + $1.members.count }
                         + dueSingles.count
        // Renamed from `total`: `ceiling` below is `baseline + runBudget`,
        // and a local called `total` there would read as
        // `ProgressUpdate.total` — which is index.count — while meaning
        // something else entirely.
        let runBudget = min(limit ?? plannedTotal, plannedTotal)
        let baseline = index.count - plannedTotal

        var count = 0
        // Members of a fallen-back group that already hold a reusable label
        // and so are never reprocessed. `plannedTotal` counts every member of
        // a due group — right for the group path, which relabels them all —
        // but the fallback path queues only the non-reusable ones, so without
        // this credit a completed run ends short of the total.
        //
        // Kept out of `count` deliberately: that is the run's return value
        // and the `--limit` budget, and this is work this invocation did not
        // do.
        var credited = 0
        // Members of groups the model refused twice: individual answers beat
        // a blanket Unsorted for a large group, at per-image scatter risk.
        var fallback: [IndexRecord] = []

        func report() {
            onProgress?(ProgressUpdate(done: baseline + count + credited,
                                       total: index.count,
                                       ceiling: baseline + runBudget))
        }

        // Paint once before the first model call. Measured on the real
        // collection: a resumed `classify` spends ~11s inside its first
        // on-device call — cold start, almost entirely off-CPU — and until
        // that call RETURNS nothing calls `onProgress` at all. The run
        // therefore opened with a 10-30s silence, which is the hang this
        // display exists to rule out, relocated to the start of the run.
        // Guarded on `runBudget`: a no-op run, and `--limit 0`, still report
        // nothing.
        if runBudget > 0 { report() }

        for group in dueGroups {
            // Never split a group: half a group under one label and half
            // under the next run's label is the inconsistency this design
            // exists to remove. Skip, not break: a later smaller group may
            // still fit the remaining budget.
            if let limit, count + group.members.count > limit { continue }
            // A scene group's Unsorted verdict is the model saying the shared
            // evidence names no source — the grouping failed, so members get
            // individual answers instead of a wholesale stamp. (Measured: 19
            // scene groups had stamped 173 records Unsorted; per-image had
            // sorted 164 of them.) A domain group's Unsorted stands: a domain
            // IS a source, and its verdict is repairable by one rename.
            guard let category = await classifier.groupCategory(group),
                  !(group.kind == .scene && category == Taxonomy.unsortedName)
            else {
                let due = group.members.filter { !reusable.contains($0.file) }
                credited += group.members.count - due.count
                fallback.append(contentsOf: due)
                continue
            }
            var agreed: Bool?
            var alternate: String?
            if verify {
                alternate = await classifier.groupCategory(group,
                                                           variant: .alternate)
                // nil alternate means the probe refused twice — verification
                // did not complete, which is not the same claim as "it
                // completed and disagreed". Collapsing the two would stamp a
                // permanent false disagreement on every member of every
                // group whose alternate probe merely failed to answer.
                agreed = alternate.map { $0 == category }
            }
            // One appendAll per group: a crash never leaves a group
            // half-labelled.
            try labelStore.appendAll(group.members.map { member in
                LabelRecord(file: member.file, category: category,
                            reason: "group-model", modelConfidence: nil,
                            filterVersion: SceneFilter.filterVersion,
                            taxonomySignature: taxonomy.signature,
                            verifyAgreed: agreed, verifyAlternate: alternate)
            })
            count += group.members.count
            report()
        }

        for record in dueSingles + fallback {
            if let limit, count >= limit { break }
            var label = await classifier.classify(record)
            if verify, label.reason == "model" {
                // A genuinely different phrasing, not a repeat. classify()
                // already builds a fresh session per call, which removes
                // transcript bias — and the responder decodes greedily, so an
                // identical re-ask would agree ~100% by construction. (Under
                // the earlier default temperature sampling that claim was
                // false — measured 44% — because a repeat drew again from the
                // label distribution.) The alternate phrasing is what makes
                // this measure robustness rather than decoding determinism.
                let second = await classifier.classify(record, variant: .alternate)
                label = LabelRecord(file: label.file, category: label.category,
                                    reason: label.reason,
                                    modelConfidence: label.modelConfidence,
                                    filterVersion: label.filterVersion,
                                    taxonomySignature: label.taxonomySignature,
                                    verifyAgreed: second.category == label.category,
                                    verifyAlternate: second.category)
            }
            try labelStore.append(label)
            count += 1
            report()
        }
        return count
    }

    /// What a run would do, split by *why* — returned rather than only
    /// printed so the distinction is assertable in a test.
    public struct Pending: Equatable, Sendable {
        /// Files in the index with no label at all. Ordinary work.
        public let neverLabelled: Int
        /// Files whose newest label was produced under a different taxonomy
        /// or filter. This is the only population that means "changed".
        public let stale: Int
        /// Files whose newest label is still valid.
        public let reusable: Set<String>
        public var total: Int { neverLabelled + stale }
    }

    /// Pure form. `run` already holds all three inputs, so it calls this
    /// rather than the loading convenience below — otherwise extracting
    /// `pending` silently undoes the read consolidation it followed, costing
    /// a second `TaxonomyStore.load` (which re-runs `validate`) and a second
    /// full index read on every invocation.
    static func pending(taxonomy: Taxonomy, index: [IndexRecord],
                        labels: [LabelRecord]) -> Pending {
        let signature = taxonomy.signature

        // Superseded rows stay in the append-only file, so fold to the newest
        // record per file — a file is reusable only if its NEWEST label
        // matches the current taxonomy and filter.
        var newest: [String: LabelRecord] = [:]
        for l in labels { newest[l.file] = l }

        let reusable = Set(newest.values
            .filter { $0.taxonomySignature == signature
                   && $0.filterVersion == SceneFilter.filterVersion }
            .map(\.file))

        let stale = newest.keys.filter { !reusable.contains($0) }.count
        let neverLabelled = index.filter { newest[$0.file] == nil }.count
        return Pending(neverLabelled: neverLabelled, stale: stale,
                       reusable: reusable)
    }

    /// Loading convenience for callers that hold nothing yet.
    public func pending() throws -> Pending {
        Self.pending(
            taxonomy: try TaxonomyStore.load(from: paths.taxonomy),
            index: try JSONLStore<IndexRecord>(url: paths.index).readAll(),
            labels: try JSONLStore<LabelRecord>(url: paths.labels).readAll())
    }

    /// The labels `apply` should act on: last record per file wins, so a
    /// reclassification supersedes the row it replaced.
    public func currentLabels() throws -> [LabelRecord] {
        var latest: [String: LabelRecord] = [:]
        for l in try JSONLStore<LabelRecord>(url: paths.labels).readAll() {
            latest[l.file] = l
        }
        return latest.values.sorted { $0.file < $1.file }
    }
}
