import Foundation
import Vision

/// Runs three Vision requests per image using the async ImageProcessingRequest
/// structs. The legacy VNImageRequestHandler.perform is synchronous and would
/// occupy a cooperative thread for the duration of each call.
public struct Extractor: Sendable {
    public init() {}

    public func extract(url: URL) async -> IndexRecord {
        let name = url.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = (attrs?[.modificationDate] as? Date)
            ?? Date(timeIntervalSince1970: 0)
        let size = (attrs?[.size] as? Int) ?? 0
        let (ts, tsSource) = Timestamp.parse(filename: name, mtime: mtime)

        do {
            async let textTask = RecognizeTextRequest().perform(on: url)
            async let sceneTask = ClassifyImageRequest().perform(on: url)
            async let faceTask = DetectFaceRectanglesRequest().perform(on: url)

            let textObs = try await textTask
            let sceneObs = try await sceneTask
            let faceObs = try await faceTask

            let ocr = textObs.map(\.transcript).joined(separator: "\n")

            // Fraction of the frame covered by text, in normalised units.
            let density = min(1.0, textObs.reduce(0.0) {
                $0 + Double($1.boundingBox.width * $1.boundingBox.height)
            })

            // Face *area*, not count: feed avatars register as faces, so
            // count alone does not mean "photograph of people".
            let faceAreaMax = faceObs.reduce(0.0) {
                max($0, Double($1.boundingBox.width * $1.boundingBox.height))
            }

            let raw = sceneObs
                .sorted { $0.confidence > $1.confidence }
                .prefix(20)
                .map { SceneObservation(identifier: $0.identifier,
                                        confidence: $0.confidence) }

            return IndexRecord(
                file: name, ts: ts, tsSource: tsSource,
                mtime: mtime.timeIntervalSince1970, size: size, ocr: ocr,
                chars: ocr.count, blocks: textObs.count, density: density,
                sceneRaw: Array(raw), faces: faceObs.count,
                faceAreaMax: faceAreaMax,
                domains: Domains.harvest(from: ocr), error: nil)
        } catch {
            // A corrupt or truncated PNG costs one record, not the run.
            return IndexRecord(file: name, ts: ts, tsSource: tsSource,
                               mtime: mtime.timeIntervalSince1970, size: size,
                               ocr: "", chars: 0, blocks: 0, density: 0,
                               sceneRaw: [], faces: 0, faceAreaMax: 0,
                               domains: [], error: "\(error)")
        }
    }
}

/// Drives extraction over the inbox, skipping anything already indexed.
public struct ExtractRunner {
    private let paths: Paths
    private let store: JSONLStore<IndexRecord>

    public init(paths: Paths) {
        self.paths = paths
        self.store = JSONLStore<IndexRecord>(url: paths.index)
    }

    public func run(concurrency: Int = 8,
                    onProgress: ((ProgressUpdate) -> Void)? = nil)
        async throws -> (processed: Int, skipped: Int) {
        // Preflight must run before this stage touches any file: it validates
        // the scene denylist against Vision's real vocabulary, and that check
        // should fail loudly before we so much as create a directory.
        try Preflight.run()

        // Stage 1 is the first writer, so it owns creating the state directory.
        try paths.ensureState()

        // Resume key is path + mtime + size, not filename alone: a replaced
        // file keeps its name and must be re-extracted.
        let already = Set(try store.readAll().map(\.resumeKey))

        let candidates = try FileManager.default
            .contentsOfDirectory(atPath: paths.inbox.path)
            .filter { $0.lowercased().hasSuffix(".png") }
            .sorted()

        let todo = candidates.filter { name in
            let url = paths.inbox.appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? Int) ?? 0
            return !already.contains(IndexRecord.resumeKey(file: name, mtime: mtime, size: size))
        }

        // Deliberately not `already.count`: `already` is the set of resume
        // keys read from the index, which can include records for files no
        // longer present in the inbox. As a progress baseline that would put
        // `done` above the true total, and as the reported `skipped` it
        // inflates the summary line for the identical reason.
        let baseline = candidates.count - todo.count

        // Paint once before the first image. Nothing calls `onProgress` until
        // a whole batch completes, and the first Vision request pays a warm-up
        // cost, so the run would open with a silence indistinguishable from
        // the hang this display exists to rule out. Guarded on `todo`: a run
        // with nothing to do still reports nothing at all.
        if !todo.isEmpty {
            onProgress?(ProgressUpdate(done: baseline,
                                       total: candidates.count,
                                       ceiling: candidates.count))
        }

        var processed = 0
        var cursor = 0

        while cursor < todo.count {
            let slice = Array(todo[cursor..<min(cursor + concurrency, todo.count)])
            let records = await withTaskGroup(of: IndexRecord.self) { group in
                for n in slice {
                    let url = paths.inbox.appendingPathComponent(n)
                    group.addTask { await Extractor().extract(url: url) }
                }
                var out: [IndexRecord] = []
                for await r in group { out.append(r) }
                return out
            }
            // Flushed once per batch of `concurrency`, so a kill loses at most
            // the batch in flight — with the default of 8, a kill during image
            // 1,200 preserves at least 1,193 results, not exactly 1,199.
            try store.appendAll(records.sorted { $0.file < $1.file })
            processed += records.count
            cursor += concurrency
            onProgress?(ProgressUpdate(done: baseline + processed,
                                       total: candidates.count,
                                       ceiling: candidates.count))
        }
        return (processed, baseline)
    }
}
