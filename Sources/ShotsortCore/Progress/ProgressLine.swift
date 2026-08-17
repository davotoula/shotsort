import Foundation

/// Renders one progress line and nothing else. Pure: no clock, no I/O, no
/// stored state, and no terminal control codes — `\r`, `\u{1B}[K` and
/// newlines belong to `ProgressReporter`. That keeps this output identical on
/// and off a terminal, and keeps its tests free of layout noise.
public enum ProgressLine {
    public enum Style: Sendable {
        /// Full-width form with the bar.
        case bar
        /// Everything except the bar. Used off a terminal and on a narrow one.
        case compact
    }

    public static func render(label: String, done: Int, total: Int,
                              eta: TimeInterval?, style: Style,
                              width: Int) -> String {
        let pct = percent(done: done, total: total)

        switch style {
        case .compact:
            let etaPart = eta.map { " eta \(duration($0))" } ?? ""
            return "\(label) \(done)/\(total) \(pct)%\(etaPart)"

        case .bar:
            let head = "\(label)  ["
            let tail = "]  \(done)/\(total)   \(pct)%"
                + (eta.map { "   eta \(duration($0))" } ?? "")
            // Sized so the whole line lands on `width - 1`. The reporter
            // truncates as well, but truncating a bar that was drawn too wide
            // would cut off the counts and the ETA — the fields worth keeping.
            // Hence a floor of 0 and not, say, 4: a minimum bar width would
            // push the line past `width - 1` on a narrow terminal and feed
            // the truncation it is meant to avoid. It also keeps
            // `String(repeating:count:)` off a negative count.
            let cells = max(0, width - 1 - head.count - tail.count)
            // `render` is public and takes arbitrary `Int`s: a negative
            // `done` would otherwise make `cells * done / total` negative and
            // trap `String(repeating:count:)`, so floor it same as `cells`.
            let filled = total > 0 ? max(0, min(cells, cells * done / total)) : 0
            return head
                + String(repeating: "█", count: filled)
                + String(repeating: "░", count: cells - filled)
                + tail
        }
    }

    /// Floors. Rounding would show 100% at 1493 of 1494, on the one run
    /// where the record still outstanding is the one being waited for.
    /// Shared with `ProgressReporter`, which steps its plain-mode throttle
    /// on this same number — two independent copies could silently desync
    /// the throttle from what the display actually shows.
    static func percent(done: Int, total: Int) -> Int {
        total > 0 ? done * 100 / total : 0
    }

    /// `45s`, `2m41s`, `1h02m`. Never a bare seconds count above a minute —
    /// "eta 161s" makes the reader do arithmetic while they wait.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3600 {
            return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m"
        }
        if s >= 60 {
            return "\(s / 60)m\(String(format: "%02d", s % 60))s"
        }
        return "\(s)s"
    }
}
