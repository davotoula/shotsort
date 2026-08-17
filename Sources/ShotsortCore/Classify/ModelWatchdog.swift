import Foundation
import Synchronization

/// Both attempts at a model call exceeded the deadline. Callers treat it
/// like any other model failure — group calls fall back to per-image, single
/// calls label and move on — so one wedged request costs seconds, not the run.
public struct ModelCallTimedOut: Error, Equatable {}

/// Bounds a model call that may never return.
///
/// Measured on the real collection: `LanguageModelSession.respond`
/// sporadically parks for minutes — zero CPU on both sides, the task
/// suspended inside the SensitiveContentAnalysisML pre-pass — while a fresh
/// request issued during the stall answers in seconds. The wedge is
/// per-request state in the framework, so the remedy is per-request too:
/// abandon the call at the deadline and ask again from scratch.
enum ModelWatchdog {
    /// One retry: the evidence says a fresh request almost always answers,
    /// and a second consecutive wedge should surface as a failure rather
    /// than buy a third silent deadline.
    static let attempts = 2

    /// Races `operation` against the deadline and retries a timeout once.
    /// Genuine errors — refusals, schema misses — propagate on the first
    /// throw: they are answers, and `groupCategory` already owns the policy
    /// for retrying those with fewer samples.
    static func run<T: Sendable>(deadline: TimeInterval,
                                 operation: @Sendable @escaping () async throws -> T)
        async throws -> T {
        for attempt in 1...attempts {
            do {
                return try await race(deadline: deadline, operation: operation)
            } catch is ModelCallTimedOut where attempt < attempts {
                continue
            }
        }
        throw ModelCallTimedOut()
    }

    /// Unstructured on purpose. A task-group race would await its children on
    /// scope exit, so if `respond` ignored cancellation — and the observed
    /// stalls suggest it can — the "timeout" would still block until the
    /// wedge resolved. Abandonment means resuming the caller at the deadline
    /// and letting the orphaned attempt finish whenever it does, its result
    /// discarded by the once-guard.
    private static func race<T: Sendable>(
        deadline: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            let once: @Sendable (Result<T, Error>) -> Void = { result in
                let first: Bool = resumed.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(with: result) }
            }
            Task {
                do { once(.success(try await operation())) }
                catch { once(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(deadline))
                once(.failure(ModelCallTimedOut()))
            }
        }
    }
}
