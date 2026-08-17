/// One progress observation. Three numbers rather than two: the bar tracks
/// the whole collection, but under `--limit` a run stops long before reaching
/// it, and an ETA derived from `total - done` would quote the time to finish
/// 1,444 records for a run that stops after 50.
public struct ProgressUpdate: Sendable, Equatable {
    /// Work durably recorded before this process started, plus work this
    /// process has done. Collection-relative, so a `--supervise` restart
    /// resumes the bar rather than reopening it at zero.
    public let done: Int
    /// The whole collection. Drives the bar and the percentage.
    public let total: Int
    /// The highest `done` this invocation can reach. Drives the ETA.
    public let ceiling: Int

    public init(done: Int, total: Int, ceiling: Int) {
        self.done = done
        self.total = total
        self.ceiling = ceiling
    }
}
