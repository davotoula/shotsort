import Testing
import Foundation
import Synchronization
@testable import ShotsortCore

/// Counts attempts across concurrent contexts. The watchdog's operation is
/// `@Sendable`, so a plain `var` capture cannot record how often it ran.
private final class Attempts: Sendable {
    private let n = Mutex(0)
    func next() -> Int { n.withLock { $0 += 1; return $0 } }
    var count: Int { n.withLock { $0 } }
}

/// Deadlines here are real time, kept two orders of magnitude apart from the
/// simulated work (5ms work vs 200ms deadline, 50ms deadline vs 10s wedge) so
/// scheduler jitter cannot flip an outcome.
private let deadline: TimeInterval = 0.05

@Test func aPromptCallThatBeatsTheDeadlineReturnsItsValue() async throws {
    let attempts = Attempts()
    let value = try await ModelWatchdog.run(deadline: 0.2) {
        _ = attempts.next()
        try await Task.sleep(for: .milliseconds(5))
        return "answer"
    }
    #expect(value == "answer")
    #expect(attempts.count == 1)
}

@Test func aWedgedCallIsAbandonedAndTheRetryAnswers() async throws {
    // The measured failure: `respond` sporadically parks for minutes inside
    // the safety pre-pass while a FRESH request answers in seconds. So the
    // watchdog must abandon the wedged attempt — not await its cancellation,
    // which the framework may ignore — and ask again.
    let attempts = Attempts()
    let value = try await ModelWatchdog.run(deadline: deadline) {
        if attempts.next() == 1 {
            try? await Task.sleep(for: .seconds(10))  // ignores cancellation
        }
        return "answer"
    }
    #expect(value == "answer")
    #expect(attempts.count == 2)
}

@Test func twoWedgedAttemptsThrowRatherThanWaitForever() async {
    let attempts = Attempts()
    let started = Date()
    await #expect(throws: ModelCallTimedOut.self) {
        try await ModelWatchdog.run(deadline: deadline) {
            _ = attempts.next()
            try? await Task.sleep(for: .seconds(10))
            return "never"
        }
    }
    #expect(attempts.count == 2)
    // Both deadlines plus generous scheduling slack — nowhere near the 10s
    // wedge, which is the property under test.
    #expect(Date().timeIntervalSince(started) < 2)
}

private struct Refusal: Error, Equatable {}

@Test func aRealErrorPropagatesWithoutASecondAttempt() async {
    // Guardrail refusals and schema misses are answers, not wedges. The
    // retry-with-fewer-samples policy for those lives in `groupCategory`;
    // retrying them here as well would double every refused group's cost.
    let attempts = Attempts()
    await #expect(throws: Refusal.self) {
        try await ModelWatchdog.run(deadline: 0.2) { () -> String in
            _ = attempts.next()
            throw Refusal()
        }
    }
    #expect(attempts.count == 1)
}
