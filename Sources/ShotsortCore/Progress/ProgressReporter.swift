import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Drives one command's progress display.
///
/// A `final class`, not a struct: `update` mutates on every call, and a
/// `mutating` method cannot be passed as `reporter.update` to a runner's
/// `onProgress` — which is how both commands wire it.
public final class ProgressReporter {
    /// Rate is measured over this trailing window rather than the whole run.
    /// `classify` drains every due group before any single, and a group
    /// advances `done` by its whole membership for one model call — so the
    /// run has two throughput phases, and a run-long average is at its most
    /// optimistic exactly at the transition and climbs thereafter. An
    /// estimate that gets worse as the run proceeds is the wrong estimate.
    private static let windowSeconds: TimeInterval = 30
    /// No ETA until the window spans this much of THIS process's work.
    /// "Non-zero work" is too weak a floor for `--supervise`: each restarted
    /// child rebuilds its rate from scratch, and one batch is two records in
    /// under half a second.
    private static let minimumSpan: TimeInterval = 10
    private static let repaintInterval: TimeInterval = 0.1
    private static let plainPercentStep = 5
    private static let plainMaximumGap: TimeInterval = 30
    /// Below this the bar is dropped. The label, counts, percentage and ETA
    /// all survive — the bar is the least valuable field.
    private static let compactBelowWidth = 50

    private let label: String
    private let isTerminal: Bool
    private let width: () -> Int
    private let now: () -> TimeInterval
    private let sink: (String) -> Void
    private let rewraps: Bool

    private var samples: [(at: TimeInterval, done: Int)] = []
    private var last: ProgressUpdate?
    private var lastEmitAt: TimeInterval?
    private var lastEmitPercent: Int?
    private var lastEmitDone: Int?
    /// What the previous repaint put on screen: the width it measured and
    /// the character count it wrote after truncation. One optional, not
    /// two, because the resize test (width changed?) and the upward walk's
    /// row count (how long was the dead line?) must describe the SAME
    /// paint — separate optionals could drift and compute a walk from one
    /// paint against a resize detected on another. All glyphs the bar
    /// paints are width-1, so `length` is also the display-column count.
    /// (`█` U+2588 and `░` U+2591 are East Asian Width *Ambiguous*: under a
    /// treat-ambiguous-as-double-width terminal setting the count understates
    /// the columns and the walk under-erases, which leaves a fragment rather
    /// than touching rows the bar does not own.) Also provided
    /// `label` is ASCII, which both in-tree labels are; a wide-glyph label
    /// would desync count from columns and mis-size the walk.
    private var lastPaint: (width: Int, length: Int)?
    private var emitted = false

    public init(label: String,
                isTerminal: Bool = isatty(STDERR_FILENO) == 1,
                width: @escaping () -> Int = ProgressReporter.stickyTerminalWidth(),
                // Decided once at init, not per repaint: the terminal the
                // process is attached to does not change mid-run.
                rewraps: Bool = ProgressReporter.terminalRewraps(
                    environment: ProcessInfo.processInfo.environment),
                now: @escaping () -> TimeInterval = {
                    ProcessInfo.processInfo.systemUptime
                },
                // A closure literal rather than a named helper: a default
                // argument on a public declaration may only reference public
                // symbols, and this needs no public surface of its own.
                sink: @escaping (String) -> Void = {
                    FileHandle.standardError.write(Data($0.utf8))
                }) {
        self.label = label
        self.isTerminal = isTerminal
        self.width = width
        self.now = now
        self.sink = sink
        self.rewraps = rewraps
    }

    public func update(_ p: ProgressUpdate) {
        let at = now()
        record(at: at, done: p.done)
        last = p
        let percent = Self.percent(p)
        guard shouldEmit(at: at, percent: percent) else { return }
        emit(p, at: at, percent: percent)
    }

    /// Renders the ACTUAL last numbers rather than forcing 100%, so a
    /// `--limit` run that legitimately stopped at 3% ends showing 3%.
    public func finish() {
        guard emitted, let p = last else { return }
        // Off a terminal every emit is a whole new line, so re-emitting an
        // unchanged one just prints the last line of the log twice. On a
        // terminal the extra repaint is invisible and worth keeping: it is
        // what guarantees the true final numbers survive a throttled last
        // update.
        if isTerminal || p.done != lastEmitDone {
            emit(p, at: now(), percent: Self.percent(p))
        }
        // On a terminal the repaint leaves the cursor on the bar's line.
        // Off one, `emit` already terminated it.
        if isTerminal { sink("\n") }
    }

    private static func percent(_ p: ProgressUpdate) -> Int {
        ProgressLine.percent(done: p.done, total: p.total)
    }

    private func shouldEmit(at: TimeInterval, percent: Int) -> Bool {
        // Nothing emitted yet: always paint. Off a terminal this is what
        // keeps a redirected run from looking dead for its first 30 seconds.
        guard let lastEmitAt, let lastEmitPercent else { return true }
        if isTerminal { return at - lastEmitAt >= Self.repaintInterval }
        return percent - lastEmitPercent >= Self.plainPercentStep
            || at - lastEmitAt >= Self.plainMaximumGap
    }

    private func emit(_ p: ProgressUpdate, at: TimeInterval, percent: Int) {
        // Re-measured on every repaint, not sampled once: a five-minute run
        // through a window resize is ordinary, and a stale width leaves the
        // line wrapping, with `\r` returning only to the start of the final
        // screen row and debris accumulating for the rest of the run.
        //
        // Clamped to 1 so truncation, style selection and the walk's row
        // division below all agree on the same floor: `width` is a public
        // injectable, and a hostile 0 would otherwise divide-by-zero the
        // row count while painting nothing.
        let w = max(1, width())
        let style: ProgressLine.Style =
            isTerminal && w >= Self.compactBelowWidth ? .bar : .compact
        let line = ProgressLine.render(label: label, done: p.done,
                                       total: p.total, eta: eta(for: p),
                                       style: style, width: w)
        // Truncation is a guarantee about the WRITE, not about a style:
        // `.compact` ignores `width` and is a fixed ~36 characters, so
        // leaving this to bar sizing alone would wrap on every repaint
        // below ~37 columns — permanent debris, not one stale row.
        //
        // Named so the paint bookkeeping below can record its count. Off a
        // terminal the sink gets the untruncated line instead, so the count
        // recorded there describes a string that was never written —
        // harmless, because only the terminal-only walk ever reads it.
        //
        // No `max(0,)` on the bound: `w` is floored at 1 above, so `w - 1`
        // cannot go negative.
        let painted = String(line.prefix(w - 1))
        if isTerminal {
            // A changed width means the terminal was resized, and the line
            // already on screen was reflowed (Terminal.app) or truncated
            // (tmux, screen) as it happened. Which of the two decides what
            // is erasable: `rewraps` (an environment allowlist — see
            // terminalRewraps) picks between the full upward walk and the
            // conservative fresh-row drop.
            let prefix: String
            if let dead = lastPaint, dead.width != w {
                prefix = rewraps
                    // Reflowed, so the dead bar's row count is knowable and
                    // all of it is erasable — see `walkPrefix`.
                    ? Self.walkPrefix(over: dead.length, at: w)
                    // Truncated, or a terminal the allowlist does not know:
                    // the dead row did not reflow, so erasing the one
                    // reachable row and dropping to a fresh one loses
                    // nothing and touches nothing the bar does not own.
                    : "\r\u{1B}[2K\n"
            } else {
                prefix = ""
            }
            // The trailing \e[K is a no-op on the walk path — \e[J already
            // cleared everything the new bar lands on — but the ordinary
            // non-resize repaint depends on it to erase the tail of a
            // longer previous line. Not dead code.
            sink(prefix + "\r" + painted + "\u{1B}[K")
        } else {
            sink(line + "\n")
        }
        emitted = true
        lastEmitAt = at
        lastEmitPercent = percent
        lastEmitDone = p.done
        lastPaint = (w, painted.count)
    }

    /// Erases a dead bar of `length` characters that the terminal reflowed
    /// to the new `width`, leaving the cursor at column 0 of the row the
    /// live bar should be repainted onto.
    ///
    /// The dead line was `length` width-1 glyphs, so the reflow put it on
    /// ceil(length / width) rows and left the cursor on the last of them
    /// (measured by `\u{1B}[6n` cursor probe: on an exact multiple
    /// Terminal.app leaves the cursor in pending-wrap on the last full row,
    /// not at column 1 of the next, so `ceil` has no off-by-one). Walk to
    /// the top row and erase to end of
    /// screen: `\u{1B}[A` at the screen's top edge is a no-op, and a walk
    /// that clamps there means the dead bar is taller than the screen, so
    /// everything `\u{1B}[J` can see is dead bar anyway.
    ///
    /// The `max` is load-bearing, not defensive noise: a 1-column terminal
    /// paints zero characters, and without the floor `rows - 1` is -1,
    /// which traps `String(repeating:count:)`.
    private static func walkPrefix(over length: Int, at width: Int) -> String {
        let rows = max(1, (length + width - 1) / width)
        return "\r"
            + String(repeating: "\u{1B}[A", count: rows - 1)
            + "\u{1B}[J"
    }

    private func record(at: TimeInterval, done: Int) {
        samples.append((at, done))
        // Evict beyond the window, but never below the two most recent: a
        // single sample yields no rate at all, so the ETA would vanish
        // exactly when updates are slowest and it is most wanted.
        while samples.count > 2, at - samples[0].at > Self.windowSeconds {
            samples.removeFirst()
        }
    }

    private func eta(for p: ProgressUpdate) -> TimeInterval? {
        guard let first = samples.first, let last = samples.last else {
            return nil
        }
        let span = last.at - first.at
        let did = last.done - first.done
        guard span >= Self.minimumSpan, did > 0 else { return nil }
        // Both samples were taken inside this process, so the difference
        // excludes the resume baseline by construction — a resumed run opens
        // at `done` 1,000 for zero work performed, and an absolute
        // done/elapsed rate would read 200/s and promise two seconds.
        //
        // Remaining is measured against `ceiling`, not `total`: under
        // `--limit` the run stops long before the collection is finished.
        let remaining = max(0, p.ceiling - p.done)
        return Double(remaining) * span / Double(did)
    }

    /// Whether the terminal reflows existing lines on resize — the premise
    /// the upward walk in `emit` stands on. An ALLOWLIST, not a denylist:
    /// a wrong `false` leaves inert fragments (the old behaviour), a wrong
    /// `true` erases the user's prompt, so every terminal nobody thought of
    /// must land on the safe verdict.
    ///
    /// Only Apple_Terminal is listed: it is the deployment terminal and the
    /// only one whose exact-multiple reflow behaviour was measured (cursor
    /// probe via `\u{1B}[6n`, 2026-08-14). The TERM guards stay even
    /// inside an allowlist because TERM_PROGRAM leaks through any
    /// non-reflowing program that does not overwrite it: tmux's server
    /// inherits the starting shell's environment, and Emacs term buffers
    /// keep it alongside TERM=eterm-color.
    ///
    /// Public because Task 3's init default argument names it, and a
    /// default argument on a public declaration may only reference public
    /// symbols.
    public static func terminalRewraps(environment: [String: String]) -> Bool {
        guard environment["TERM_PROGRAM"] == "Apple_Terminal",
              environment["TMUX"] == nil else { return false }
        let term = environment["TERM"] ?? ""
        return !["screen", "tmux", "eterm", "dumb"]
            .contains { term.hasPrefix($0) }
    }

    /// Builds a per-reporter width source that is STICKY across ioctl
    /// failures: success updates the reading, failure repeats the last
    /// one, and 80 appears only before any reading has ever succeeded.
    ///
    /// Sticky because the fallback is now load-bearing: under the old
    /// code a fabricated 80 cost a stray newline, but under the upward
    /// walk a fabricated 80 on a 200-column terminal reads as a shrink,
    /// computes ceil(199/80) = 3 and erases two rows the bar does not
    /// own — the exact failure the rewrap gate exists to prevent,
    /// arriving through a different door.
    ///
    /// The mutable capture needs no lock: both call sites deliver
    /// progress from their enclosing sequential context — Extractor
    /// reports after each batch's `for await` drain, ClassifyRunner
    /// between sequential awaits — so the closure is never entered
    /// concurrently.
    ///
    /// Public because the `width` default argument names it, and a
    /// default argument on a public declaration may only reference
    /// public symbols.
    public static func stickyTerminalWidth() -> () -> Int {
        var last = 80
        return {
            var size = winsize()
            if ioctl(STDERR_FILENO, UInt(TIOCGWINSZ), &size) == 0,
               size.ws_col > 0 {
                last = Int(size.ws_col)
            }
            return last
        }
    }
}
