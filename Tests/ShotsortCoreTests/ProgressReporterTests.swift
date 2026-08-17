import Testing
import Foundation
@testable import ShotsortCore

/// Captures each individual write, so tests can assert on the terminal
/// control codes as separate events rather than one concatenated blob.
private final class Sink {
    var lines: [String] = []
    func write(_ s: String) { lines.append(s) }
}

/// A hand-wound clock. The reporter never calls a real one.
private final class Clock {
    var t: TimeInterval = 0
    func read() -> TimeInterval { t }
}

/// A mutable width source. The `reporter(...)` helper below closes over a
/// fixed `Int`, which cannot pin re-measurement: a `width()` captured once
/// in `init` would read that same fixed value forever and still pass.
private final class WidthSource {
    var value: Int
    init(_ value: Int) { self.value = value }
    func read() -> Int { value }
}

private func reporter(_ label: String, terminal: Bool, width: Int,
                      _ clock: Clock, _ sink: Sink) -> ProgressReporter {
    // Always gate-closed: this helper closes over a FIXED width, so no
    // resize can occur through it and the walk is unreachable by
    // construction. Tests that need the walk use `resizingReporter`.
    ProgressReporter(label: label, isTerminal: terminal, width: { width },
                     rewraps: false, now: clock.read, sink: sink.write)
}

/// Builds a terminal reporter around a MUTABLE width source, so a resize
/// can happen between two emits. `rewraps` picks which recovery the resize
/// takes: the upward walk, or the conservative fresh-row drop.
private func resizingReporter(_ label: String, _ widthSource: WidthSource,
                              _ clock: Clock, _ sink: Sink,
                              rewraps: Bool = true) -> ProgressReporter {
    ProgressReporter(label: label, isTerminal: true, width: widthSource.read,
                     rewraps: rewraps, now: clock.read, sink: sink.write)
}

@Test func theFirstUpdateOffATerminalEmitsImmediately() {
    // Waiting for the first 5% would leave a redirected run silent for the
    // opening minute — the exact failure plain mode exists to prevent.
    let sink = Sink(), clock = Clock()
    let r = reporter("extracting", terminal: false, width: 80, clock, sink)
    r.update(ProgressUpdate(done: 2, total: 1494, ceiling: 1494))
    #expect(sink.lines == ["extracting 2/1494 0%\n"])
}

@Test func plainModeThrottlesToFivePercentOrThirtySeconds() {
    let sink = Sink(), clock = Clock()
    let r = reporter("extracting", terminal: false, width: 80, clock, sink)

    r.update(ProgressUpdate(done: 2, total: 1494, ceiling: 1494))    // first
    clock.t = 1
    r.update(ProgressUpdate(done: 20, total: 1494, ceiling: 1494))   // 1%, no
    clock.t = 2
    r.update(ProgressUpdate(done: 75, total: 1494, ceiling: 1494))   // 5%, yes
    clock.t = 3
    r.update(ProgressUpdate(done: 76, total: 1494, ceiling: 1494))   // still 5%, no
    clock.t = 40
    r.update(ProgressUpdate(done: 77, total: 1494, ceiling: 1494))   // 38s, yes

    #expect(sink.lines.count == 3)
    #expect(sink.lines[1].hasPrefix("extracting 75/1494 5%"))
    #expect(sink.lines[2].hasPrefix("extracting 77/1494 5%"))
}

@Test func aTerminalRepaintCarriesCarriageReturnAndEraseToEndOfLine() {
    let sink = Sink(), clock = Clock()
    let r = reporter("extracting", terminal: true, width: 80, clock, sink)
    r.update(ProgressUpdate(done: 5, total: 10, ceiling: 10))
    #expect(sink.lines == ["\rextracting  ["
                           + String(repeating: "█", count: 26)
                           + String(repeating: "░", count: 27)
                           + "]  5/10   50%\u{1B}[K"])
}

@Test func terminalRepaintsAreThrottledToAboutTenPerSecond() {
    // Without this, an implementation that repaints on EVERY update passes
    // the whole suite: every other terminal-mode test issues a single
    // update. classify can clear several records in a few milliseconds.
    let sink = Sink(), clock = Clock()
    let r = reporter("extracting", terminal: true, width: 80, clock, sink)

    r.update(ProgressUpdate(done: 5, total: 10, ceiling: 10))   // first, paints
    clock.t = 0.05
    r.update(ProgressUpdate(done: 6, total: 10, ceiling: 10))   // 50ms, coalesced
    clock.t = 0.2
    r.update(ProgressUpdate(done: 7, total: 10, ceiling: 10))   // 200ms, paints

    #expect(sink.lines.count == 2)
    #expect(sink.lines[1].contains("7/10"))
}

@Test func widthIsReMeasuredOnEveryRepaintRatherThanCapturedOnce() {
    // A five-minute run through a window resize is ordinary, and `emit`
    // re-measures `width()` on every repaint so the line does not wrap for
    // the rest of the run once the terminal narrows. The `reporter(...)`
    // helper cannot pin this — it closes over a fixed `Int`, so an
    // implementation that captured `let w = width()` once in `init` would
    // still pass every test built through it. This one wires a width
    // source that changes between two emits instead.
    let sink = Sink(), clock = Clock(), widthSource = WidthSource(80)
    let r = resizingReporter("extracting", widthSource, clock, sink,
                             rewraps: false)

    r.update(ProgressUpdate(done: 5, total: 10, ceiling: 10))
    #expect(sink.lines == ["\rextracting  ["
                           + String(repeating: "█", count: 26)
                           + String(repeating: "░", count: 27)
                           + "]  5/10   50%\u{1B}[K"])

    widthSource.value = 20
    clock.t = 0.2   // past the 0.1s repaint throttle
    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))

    #expect(sink.lines.count == 2)
    // Compact form "extracting 1494/1494 100%" truncated to width - 1 = 19
    // chars, exactly as `aNarrowTerminalTruncatesEvenTheCompactForm` asserts
    // truncation below. The leading erase-and-newline is the resize handling
    // pinned by `aWidthChangeErasesItsRowThenStartsTheBarOnAFreshRow`.
    #expect(sink.lines[1] == "\r\u{1B}[2K\n\rextracting 1494/149\u{1B}[K")
}

@Test func aWidthChangeErasesItsRowThenStartsTheBarOnAFreshRow() {
    // Observed on a real 1,494-record classify run: dragging the window
    // narrower reflows the line already on screen across several rows, `\r`
    // returns only to the last of them, and every row above keeps its
    // fragment for the rest of the run. Widening again splices those
    // fragments into wide rows. `\u{1B}[K` cannot reach them — it erases
    // only the row the cursor is on.
    //
    // The row the cursor IS on is ours, though, and it is the worst of the
    // debris: after a shrink it holds the dead bar's stale count and ETA,
    // and after a grow it holds the entire dead bar. So a resize erases that
    // row (`\r\u{1B}[2K`) before dropping to the fresh one — rows further up
    // stay, because reaching them means guessing the reflow's row count and
    // a high guess erases the user's prompt.
    let sink = Sink(), clock = Clock(), widthSource = WidthSource(80)
    let r = resizingReporter("extracting", widthSource, clock, sink,
                             rewraps: false)

    r.update(ProgressUpdate(done: 1, total: 10, ceiling: 10))
    #expect(sink.lines[0].hasPrefix("\r"))   // first paint: no erase, no newline
    #expect(!sink.lines[0].hasPrefix("\r\u{1B}[2K"))

    widthSource.value = 60
    clock.t = 0.2
    r.update(ProgressUpdate(done: 2, total: 10, ceiling: 10))
    #expect(sink.lines[1].hasPrefix("\r\u{1B}[2K\n\r"))

    // Same width again: the row is undamaged, so no erase and no newline. A
    // bar that dropped a row on every repaint would scroll the terminal.
    clock.t = 0.4
    r.update(ProgressUpdate(done: 3, total: 10, ceiling: 10))
    #expect(sink.lines[2].hasPrefix("\r"))
    #expect(!sink.lines[2].hasPrefix("\r\u{1B}[2K"))
}

@Test func aNarrowTerminalTruncatesEvenTheCompactForm() {
    // The compact form ignores `width` and is a fixed ~26-36 characters, so
    // without a truncating write any terminal under ~37 columns — an ordinary
    // three-way tmux split — wraps on EVERY repaint for the rest of the run.
    let sink = Sink(), clock = Clock()
    let r = reporter("classifying", terminal: true, width: 20, clock, sink)
    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))
    #expect(sink.lines == ["\rclassifying 1494/14\u{1B}[K"])
}

@Test func theEtaUsesTheCeilingNotTheTotal() {
    // A --limit 50 run: 25 records in 30s is 0.833/s, and 25 remain against
    // the ceiling — 30 seconds. Against `total` it would be 1,469 remaining
    // and quote 29m23s, on a run that ends in half a minute.
    let sink = Sink(), clock = Clock()
    let r = reporter("classifying", terminal: false, width: 80, clock, sink)
    r.update(ProgressUpdate(done: 0, total: 1494, ceiling: 50))
    clock.t = 30
    r.update(ProgressUpdate(done: 25, total: 1494, ceiling: 50))
    #expect(sink.lines.last == "classifying 25/1494 1% eta 30s\n")
}

@Test func noEtaBeforeTheWindowSpansTenSeconds() {
    // "Non-zero work" is far too weak a floor: a --supervise restart rebuilds
    // its rate from scratch, and one batch is two records in under half a
    // second.
    let sink = Sink(), clock = Clock()
    let r = reporter("extracting", terminal: false, width: 80, clock, sink)
    r.update(ProgressUpdate(done: 0, total: 1494, ceiling: 1494))
    clock.t = 5
    r.update(ProgressUpdate(done: 200, total: 1494, ceiling: 1494))
    #expect(sink.lines.last == "extracting 200/1494 13%\n")
}

@Test func rateIgnoresTheResumeBaseline() {
    // A resumed run opens at 1,000 done for zero work performed. Deriving
    // rate from done/elapsed would read 34/s and promise 14s; the real rate
    // is 1/s and 464 records remain.
    let sink = Sink(), clock = Clock()
    let r = reporter("extracting", terminal: false, width: 80, clock, sink)
    r.update(ProgressUpdate(done: 1000, total: 1494, ceiling: 1494))
    clock.t = 30
    r.update(ProgressUpdate(done: 1030, total: 1494, ceiling: 1494))
    #expect(sink.lines.last == "extracting 1030/1494 68% eta 7m44s\n")
}

@Test func theTwoMostRecentSamplesSurviveEviction() {
    // With a plain 30s eviction the window would hold one sample after this
    // gap and no rate could be computed — the ETA would vanish exactly when
    // updates are slowest and the estimate is most wanted.
    let sink = Sink(), clock = Clock()
    let r = reporter("extracting", terminal: false, width: 80, clock, sink)
    r.update(ProgressUpdate(done: 0, total: 1494, ceiling: 1494))
    clock.t = 100
    r.update(ProgressUpdate(done: 500, total: 1494, ceiling: 1494))
    #expect(sink.lines.last == "extracting 500/1494 33% eta 3m19s\n")
}

@Test func theRateTracksAStepChangeInThroughput() {
    // classify's shape: every group drains before any single, and a group
    // advances `done` by its whole membership for one model call. Here 10/s
    // for 30s, then 0.5/s. A run-long average would say 5.25/s and quote
    // ~2m10s; the window sees the phase it is actually in.
    let sink = Sink(), clock = Clock()
    let r = reporter("classifying", terminal: false, width: 80, clock, sink)
    for (t, done) in [(0, 0), (10, 100), (20, 200), (30, 300),
                      (40, 305), (50, 310), (60, 315)] {
        clock.t = TimeInterval(t)
        r.update(ProgressUpdate(done: done, total: 1000, ceiling: 1000))
    }
    r.finish()
    #expect(sink.lines.last == "classifying 315/1000 31% eta 22m50s\n")
}

@Test func finishPaintsThroughTheSamePathThenWritesTheNewline() {
    // The final line is usually SHORTER than the one before it — the eta
    // field drops when the window is short — and nothing repaints after it,
    // so a missing erase leaves the tail frozen above the summary print.
    let sink = Sink(), clock = Clock()
    let r = reporter("extracting", terminal: true, width: 80, clock, sink)
    r.update(ProgressUpdate(done: 5, total: 10, ceiling: 10))
    r.finish()
    #expect(sink.lines.count == 3)
    #expect(sink.lines[1].hasPrefix("\r"))
    #expect(sink.lines[1].hasSuffix("\u{1B}[K"))
    #expect(sink.lines[2] == "\n")
}

@Test func finishDoesNotRepeatAnUnchangedFinalLineOffATerminal() {
    // A redirected log must not end with its last line printed twice, byte
    // for byte. `finish` does not call `record`, so the ETA cannot have moved
    // either — there is nothing new to say.
    let sink = Sink(), clock = Clock()
    let r = reporter("extracting", terminal: false, width: 80, clock, sink)
    r.update(ProgressUpdate(done: 2, total: 1494, ceiling: 1494))
    r.finish()
    #expect(sink.lines == ["extracting 2/1494 0%\n"])
}

@Test func finishIsANoOpWhenNothingWasEverEmitted() {
    // Preserves today's behaviour: a no-op run prints no progress at all.
    let sink = Sink(), clock = Clock()
    let r = reporter("extracting", terminal: true, width: 80, clock, sink)
    r.finish()
    #expect(sink.lines.isEmpty)
}

@Test func theRewrapGateIsAnAllowlistOverTheEnvironment() {
    // The two failure directions are not symmetric: a wrong `false` leaves
    // inert fragments (the pre-walk behaviour), a wrong `true` erases the
    // user's prompt. So unlisted terminals must land on `false`, and only
    // Apple_Terminal — the deployment terminal, and the only one whose
    // exact-multiple reflow behaviour was measured — is listed.
    #expect(ProgressReporter.terminalRewraps(
        environment: ["TERM_PROGRAM": "Apple_Terminal"]))
    #expect(ProgressReporter.terminalRewraps(
        environment: ["TERM_PROGRAM": "Apple_Terminal",
                      "TERM": "xterm-256color"]))

    // TERM_PROGRAM leaks through any non-reflowing program that does not
    // overwrite it — tmux inherits the server-starting shell's environment,
    // Emacs term buffers set TERM=eterm-color — so the TERM guards stay
    // even inside an allowlist. `#expect` prints the loop value, so a
    // failure still names which terminal broke.
    for term in ["screen-256color", "tmux-256color", "eterm-color", "dumb"] {
        #expect(!ProgressReporter.terminalRewraps(
            environment: ["TERM_PROGRAM": "Apple_Terminal", "TERM": term]))
    }
    #expect(!ProgressReporter.terminalRewraps(
        environment: ["TERM_PROGRAM": "Apple_Terminal",
                      "TMUX": "/tmp/tmux-501/default,1,0"]))

    // Unmeasured rewrappers stay off until someone runs the same cursor
    // probe against them and pins the result in a test like the one below.
    #expect(!ProgressReporter.terminalRewraps(
        environment: ["TERM_PROGRAM": "iTerm.app"]))
    #expect(!ProgressReporter.terminalRewraps(environment: [:]))
}

// MARK: - The upward walk (gate open)

@Test func aShrinkWalksUpTheDeadBarAndErasesToEndOfScreen() {
    // 79 chars painted at width 80 reflow into ceil(79/20) = 4 rows at
    // width 20; the cursor sits on the last, so three \e[A reach the top
    // and one \e[J erases the whole dead bar. Safe because the bar is by
    // construction the last content on screen while live.
    let sink = Sink(), clock = Clock(), widthSource = WidthSource(80)
    let r = resizingReporter("extracting", widthSource, clock, sink)

    r.update(ProgressUpdate(done: 5, total: 10, ceiling: 10))
    #expect(sink.lines[0] == "\rextracting  ["
            + String(repeating: "█", count: 26)
            + String(repeating: "░", count: 27)
            + "]  5/10   50%\u{1B}[K")   // 79 chars painted

    widthSource.value = 20
    clock.t = 0.2
    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))
    // Width 20 is below compactBelowWidth, so the new line is the compact
    // form truncated to 19 chars, exactly as the truncation test pins.
    #expect(sink.lines[1] == "\r\u{1B}[A\u{1B}[A\u{1B}[A\u{1B}[J"
            + "\rextracting 1494/149\u{1B}[K")
}

@Test func anExactMultipleReflowWalksTheMeasuredRowCount() {
    // A bar paint at width 61 is 60 chars — bar style always lands on
    // width − 1 — and 60 reflowed to width 20 ends flush on the right
    // margin. Measured 2026-08-14 (`\u{1B}[6n` cursor probe): Terminal.app
    // leaves the cursor in pending-wrap ON the last full row, so ceil is
    // exact: ceil(60/20) = 3 rows, 2 × \e[A, no off-by-one.
    let sink = Sink(), clock = Clock(), widthSource = WidthSource(61)
    let r = resizingReporter("extracting", widthSource, clock, sink)

    r.update(ProgressUpdate(done: 5, total: 10, ceiling: 10))
    #expect(sink.lines[0] == "\rextracting  ["
            + String(repeating: "█", count: 17)
            + String(repeating: "░", count: 17)
            + "]  5/10   50%\u{1B}[K")   // 60 chars painted

    widthSource.value = 20
    clock.t = 0.2
    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))
    #expect(sink.lines[1] == "\r\u{1B}[A\u{1B}[A\u{1B}[J"
            + "\rextracting 1494/149\u{1B}[K")
}

@Test func theWalkCountsThePaintedLengthNotTheOldWidth() {
    // The one test that discriminates painted-length from a width − 1
    // shortcut: the compact form at width 40 is 26 chars (no ETA — the
    // clock stays under minimumSpan) while width − 1 is 39, and the two
    // straddle a multiple of the new width: ceil(26/10) = 3 rows
    // (2 × \e[A) versus ceil(39/10) = 4 (3 × \e[A). Bar paints cannot
    // discriminate — bar style is width − 1 by construction.
    let sink = Sink(), clock = Clock(), widthSource = WidthSource(40)
    let r = resizingReporter("classifying", widthSource, clock, sink)

    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))
    #expect(sink.lines[0] == "\rclassifying 1494/1494 100%\u{1B}[K") // 26 chars

    widthSource.value = 10
    clock.t = 0.2
    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))
    #expect(sink.lines[1] == "\r\u{1B}[A\u{1B}[A\u{1B}[J"
            + "\rclassifyi\u{1B}[K")
}

@Test func aGrowErasesInPlaceWithNoUpwardWalk() {
    // The dead line never wrapped — it was painted under the truncation
    // bound of the OLD, narrower width — so rows = 1 and the whole dead
    // bar dies to the single \e[J with no \e[A at all. This is the case
    // the fresh-row fallback handled worst: it left the entire old bar
    // standing.
    let sink = Sink(), clock = Clock(), widthSource = WidthSource(40)
    let r = resizingReporter("classifying", widthSource, clock, sink)

    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))
    #expect(sink.lines[0] == "\rclassifying 1494/1494 100%\u{1B}[K")

    widthSource.value = 80
    clock.t = 0.2
    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))
    #expect(sink.lines[1] == "\r\u{1B}[J"
            + "\rclassifying  ["
            + String(repeating: "█", count: 46)
            + "]  1494/1494   100%\u{1B}[K")
}

@Test func aSecondResizeWalksRowsFromTheResizePaintNotTheOriginal() {
    // The resize repaint must re-record lastPaint. If it did not, a second
    // shrink would walk rows computed from the ORIGINAL 79-char paint —
    // ceil(79/10) = 8 rows, 7 × \e[A — erasing five rows of the user's
    // scrollback above a dead line that only spans three.
    let sink = Sink(), clock = Clock(), widthSource = WidthSource(80)
    let r = resizingReporter("extracting", widthSource, clock, sink)

    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))

    widthSource.value = 40
    clock.t = 0.2
    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))
    // 79 chars into width 40: ceil(79/40) = 2 rows, one \e[A. The new
    // paint is the compact form, 25 chars, under the 39-char bound.
    #expect(sink.lines[1] == "\r\u{1B}[A\u{1B}[J"
            + "\rextracting 1494/1494 100%\u{1B}[K")

    widthSource.value = 10
    clock.t = 0.4
    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))
    // ceil(25/10) = 3 rows from the RESIZE paint's 25 chars, 2 × \e[A.
    #expect(sink.lines[2] == "\r\u{1B}[A\u{1B}[A\u{1B}[J"
            + "\rextractin\u{1B}[K")
}

@Test func aOneColumnTerminalWalksZeroRowsInsteadOfTrapping() {
    // Both clamps are load-bearing, not defensive noise: width 1 paints
    // prefix(0) — zero characters — so lastPaint.length is 0 and an
    // unfloored rows would be 0, making `rows - 1` trap
    // String(repeating:count:) at -1. An unfloored w would divide by zero
    // one line earlier. This pins the whole degenerate path: erase in
    // place, walk nowhere, paint the truncated line.
    let sink = Sink(), clock = Clock(), widthSource = WidthSource(1)
    let r = resizingReporter("extracting", widthSource, clock, sink)

    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))
    #expect(sink.lines[0] == "\r\u{1B}[K")   // width 1: nothing fits

    widthSource.value = 5
    clock.t = 0.2
    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))
    #expect(sink.lines[1] == "\r\u{1B}[J\rextr\u{1B}[K")
}

@Test func finishCleansUpATrailingResizeOnTheWayOut() {
    // This falls out for free because finish() repaints through emit. Pin it: a resize between the last update and
    // finish() must walk and erase like any other repaint, then terminate
    // the line.
    let sink = Sink(), clock = Clock(), widthSource = WidthSource(80)
    let r = resizingReporter("extracting", widthSource, clock, sink)

    r.update(ProgressUpdate(done: 1494, total: 1494, ceiling: 1494))

    widthSource.value = 40
    clock.t = 0.2
    r.finish()
    // 79 chars into width 40: ceil(79/40) = 2 rows, one \e[A, then the
    // compact repaint and the closing newline as separate writes.
    #expect(sink.lines[1] == "\r\u{1B}[A\u{1B}[J"
            + "\rextracting 1494/1494 100%\u{1B}[K")
    #expect(sink.lines[2] == "\n")
}
