import Foundation
import ShotsortCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("shotsort: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: shotsort <extract|diagnose|propose|classify|apply|undo> "
         + "[--inbox PATH] [--output PATH] "
         + "[--commit] [--verify] [--limit N] [--concurrency N] [--supervise]")
}

/// Reads one `--flag PATH` value. Loud like `--concurrency`, not silent
/// like `--limit`: these are the tool's first string-valued flags, and
/// every quiet failure here — a missing value, an empty "$DIR", a
/// =-joined form firstIndex cannot see, a second occurrence, a stray
/// dash-argument — would send a later `apply --commit` at whatever
/// directory the user happens to be in.
func pathValue(_ flag: String, in args: [String]) -> String? {
    if let joined = args.first(where: { $0.hasPrefix(flag + "=") }) {
        fail("use \(flag) PATH, not \(joined)")
    }
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard args.lastIndex(of: flag) == i else {
        fail("\(flag) given more than once")
    }
    // `dropFirst(i + 1).first` is total where `args[i + 1]` needs a bounds
    // guard, so "no value at all" arrives as "" and falls into the same
    // `isEmpty` clause as an empty `$DIR` — one message, one rule each.
    let value = args.dropFirst(i + 1).first ?? ""
    guard !value.isEmpty, !value.hasPrefix("-") else {
        fail("\(flag) requires a path")
    }
    return value
}

let paths = Paths.resolve(inbox: pathValue("--inbox", in: args),
                          output: pathValue("--output", in: args))

/// Number of records currently in the index, 0 if it does not exist yet or
/// cannot be read. Used by `--supervise` to tell "made progress" from
/// "stuck" across a crashed child.
func extractIndexCount(_ paths: Paths) -> Int {
    (try? JSONLStore<IndexRecord>(url: paths.index).readAll().count) ?? 0
}

/// The first inbox PNG (in the same sorted order `ExtractRunner` uses) that
/// is not yet represented in the index. When a child dies without making
/// progress, this is the likely culprit to report.
func firstUnindexedFile(_ paths: Paths) -> String? {
    let already = (try? JSONLStore<IndexRecord>(url: paths.index).readAll()) ?? []
    let alreadyKeys = Set(already.map(\.resumeKey))
    let candidates = (try? FileManager.default
        .contentsOfDirectory(atPath: paths.inbox.path)
        .filter { $0.lowercased().hasSuffix(".png") }
        .sorted()) ?? []
    for name in candidates {
        let url = paths.inbox.appendingPathComponent(name)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int) ?? 0
        if !alreadyKeys.contains(IndexRecord.resumeKey(file: name, mtime: mtime, size: size)) {
            return name
        }
    }
    return nil
}

/// Runs extraction once in-process, rendering progress to stderr so a long
/// run does not look like a hang.
func runExtract(paths: Paths, concurrency: Int) async throws {
    let reporter = ProgressReporter(label: "extracting")
    let result: (processed: Int, skipped: Int)
    // The `do` scope makes `defer` fire BEFORE the summary below, and on the
    // throw path too. Without it a mid-run failure reaches the top-level
    // catch and `fail()` writes its message straight onto the unterminated
    // bar line — the same collision the supervisor has to avoid, with no
    // supervisor involved.
    do {
        defer { reporter.finish() }
        result = try await ExtractRunner(paths: paths).run(
            concurrency: concurrency, onProgress: reporter.update)
    }
    print("extracted \(result.processed), skipped \(result.skipped) already indexed")
}

/// Supervisor messages go to stderr, not stdout: they are progress
/// diagnostics interleaved with the child's progress bar, which is on stderr
/// too. As `print`s they shared a stream with the bar only for as long as
/// both happened to point at one terminal — redirect stdout and they diverge.
///
/// `afterPartialLine` covers the case where a crashed child abandoned its bar
/// mid-line and this message is the next thing written.
func note(_ message: String, afterPartialLine: Bool = false) {
    let lead = afterPartialLine ? "\n" : ""
    FileHandle.standardError.write(Data("\(lead)supervise: \(message)\n".utf8))
}

/// Re-invokes this same executable as a child, repeatedly, to survive the
/// SIGSEGV inside Apple's Vision framework that an in-process retry cannot
/// (a signal kills the whole process, retry loop included). `extract` is
/// resumable and append-only, so a crashed child that made progress just
/// needs to be restarted; a crashed child that made NO progress is stuck on
/// something real and must not be retried silently.
func runSupervisedExtract(paths: Paths, args: [String]) throws {
    guard let exe = Bundle.main.executableURL else {
        fail("supervise: could not resolve the path to the shotsort executable")
    }
    // Forward everything the user passed except --supervise itself — keeping
    // that flag would make the child re-supervise itself, and its child
    // re-supervise itself, forking indefinitely.
    let childArgs = args.filter { $0 != "--supervise" }

    let maxRestarts = 50
    var restarts = 0
    var before = extractIndexCount(paths)
    note("\(before) records already indexed; starting child")

    while true {
        let process = Process()
        process.executableURL = exe
        process.arguments = childArgs
        // No standardOutput/standardError/standardInput assigned: Process
        // inherits the parent's file handles, so the child's progress
        // output and summary line are visible directly.
        do {
            try process.run()
        } catch {
            fail("supervise: failed to launch child: \(error)")
        }
        process.waitUntilExit()

        let after = extractIndexCount(paths)

        if process.terminationReason == .exit && process.terminationStatus == 0 {
            note("extraction complete — \(after) records indexed "
                 + "(\(restarts) restart\(restarts == 1 ? "" : "s"))")
            return
        }

        if process.terminationReason == .uncaughtSignal {
            let signal = process.terminationStatus
            if after > before {
                // Flaky framework crash, but real progress was made: exactly
                // the case this supervisor exists for. Loop.
                restarts += 1
                note("child crashed on signal \(signal) after making progress "
                     + "(\(before) -> \(after) records); restarting "
                     + "(\(restarts)/\(maxRestarts))", afterPartialLine: true)
                if restarts >= maxRestarts {
                    fail("supervise: hit the restart cap (\(maxRestarts)) "
                         + "without finishing; \(after) records indexed so far")
                }
                before = after
                continue
            } else {
                // Crashed WITHOUT making progress: not flaky, stuck. Do not
                // loop — that would mask a genuinely poisoned image as the
                // Vision flakiness this supervisor is meant to absorb.
                let culprit = firstUnindexedFile(paths)
                    ?? "(could not determine — inbox listing failed)"
                fail("supervise: extraction is STUCK, not flaky — the child "
                     + "crashed on signal \(signal) without indexing any new "
                     + "records (still \(after)). Likely culprit: \(culprit)")
            }
        } else {
            // Exited nonzero on its own (not a signal) — a real error, not
            // the Vision crash this supervisor works around. Do not loop.
            fail("supervise: child exited with status "
                 + "\(process.terminationStatus) (not a crash) — see its "
                 + "output above")
        }
    }
}

do {
    switch command {
    case "extract":
        // Default 2, and 2 specifically. Apple's Vision framework segfaults
        // under concurrent load — `objc_retain` from `TextRecognition`,
        // reproduced in a standalone probe with no project code. The cause is
        // the Apple Neural Engine session limit of 2 that Apple DTS has named,
        // so 2 is a documented boundary rather than a lucky value.
        //
        // Measured over the real 1,494-image collection:
        //   width 1  survived      width 2  survived (5m05s)
        //   width 4  crashed       width 8  crashed
        //
        // A cap makes the crash unlikely, not impossible — the race is inside
        // Apple's code — so --supervise stays worth using on long runs.
        var concurrency = 2
        if let i = args.firstIndex(of: "--concurrency") {
            guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 1 else {
                fail("--concurrency requires an integer of 1 or more")
            }
            concurrency = n
        }

        if args.contains("--supervise") {
            try runSupervisedExtract(paths: paths, args: args)
        } else {
            try await runExtract(paths: paths, concurrency: concurrency)
        }

    case "propose":
        try Preflight.run()
        try ModelAvailability.check()
        let index = try JSONLStore<IndexRecord>(url: paths.index).readAll()
        guard !index.isEmpty else { fail("index is empty — run extract first") }
        let result = try await Proposer(proposer: OnDeviceProposer())
            .run(records: index)
        try TaxonomyStore.save(result.taxonomy, to: paths.taxonomy)
        if result.reduction == .deterministicFallback {
            FileHandle.standardError.write(Data(
                ("warning: model consolidation failed twice; this draft is "
                + "unconsolidated candidate names ranked by recurrence — "
                + "expect duplicates and over-specific entries\n").utf8))
        }
        print("proposed \(result.taxonomy.categories.count) categories:")
        for c in result.taxonomy.categories { print("  \(c.name) — \(c.desc)") }
        print("\nedit \(paths.taxonomy.path) then run: shotsort classify")

    case "classify":
        var limit: Int?
        if let i = args.firstIndex(of: "--limit"), i + 1 < args.count {
            limit = Int(args[i + 1])
        }
        let reporter = ProgressReporter(label: "classifying")
        let n: Int
        // As in runExtract: the `do` scope fires `finish()` before the
        // summary and on the throw path both.
        do {
            defer { reporter.finish() }
            n = try await ClassifyRunner(paths: paths)
                .run(verify: args.contains("--verify"), limit: limit,
                     onProgress: reporter.update)
        }
        print("classified \(n) records")

    case "diagnose":
        try Preflight.run()
        // Uses the real SceneFilter and SignalGate rather than reimplementing
        // their constants, so the calibration diagnostic cannot drift from
        // the code it is calibrating.
        let index = try JSONLStore<IndexRecord>(url: paths.index).readAll()
        guard !index.isEmpty else { fail("index is empty — run extract first") }
        let n = index.count
        func pct(_ k: Int) -> String { "\(k) (\(k * 100 / n)%)" }
        print("records              : \(n)")
        print("filterVersion        : \(SceneFilter.filterVersion)")
        print("confidenceFloor      : \(SceneFilter.confidenceFloor)")
        print("confidenceEpsilon    : \(SceneFilter.confidenceEpsilon)")
        print("genericLabels        : \(SceneFilter.genericLabels.sorted())")
        print("scenes empty         : "
              + pct(index.filter { SceneFilter.scenes(from: $0.sceneRaw).isEmpty }.count)
              + "   [design predicts ~60%]")
        print("chars < 12           : \(pct(index.filter { $0.chars < 12 }.count))")
        print("face signal usable   : "
              + pct(index.filter {
                    FaceBand.of(faceAreaMax: $0.faceAreaMax).isUsableSignal }.count))
        print("has domains          : \(pct(index.filter { !$0.domains.isEmpty }.count))")
        print("extract errors       : \(pct(index.filter { $0.error != nil }.count))")
        print("no-signal gate hits  : "
              + pct(index.filter(SignalGate.hasNoSignal).count))

    case "apply":
        // currentLabels folds to the last record per file, so a
        // reclassification supersedes the row it replaced rather than
        // apply seeing both.
        let labels = try ClassifyRunner(paths: paths).currentLabels()
        guard !labels.isEmpty else { fail("no labels — run classify first") }
        let applier = Applier(paths: paths)
        // Dry-run is the default; moving requires an explicit --commit.
        let rows = args.contains("--commit")
            ? try applier.commit(labels: labels)
            : try applier.plan(labels: labels)

        var counts: [String: Int] = [:]
        for r in rows { counts[r.category, default: 0] += 1 }
        for (category, n) in counts.sorted(by: { $0.key < $1.key }) {
            let samples = rows.filter { $0.category == category }
                .prefix(2).map(\.file).joined(separator: ", ")
            print(String(format: "%6d  %@  (%@)", n, category, samples))
        }
        let errors = rows.filter { $0.action == .error }
        if !errors.isEmpty {
            print("\n\(errors.count) errors:")
            for e in errors.prefix(20) { print("  \(e.file)") }
        }
        if !args.contains("--commit") {
            print("\ndry run — nothing moved. re-run with --commit")
        }

    case "undo":
        let restored = try Applier(paths: paths).undo()
        print("returned \(restored) files to \(paths.inbox.path)")

    default:
        fail("unknown command: \(command)")
    }
} catch {
    fail("\(error)")
}
