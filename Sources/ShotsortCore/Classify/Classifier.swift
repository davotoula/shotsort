import Foundation
import FoundationModels

public enum ClassifyError: Error, Equatable {
    case categoryNotInTaxonomy(String)
}

/// Abstracts the model call so classification plumbing can be tested without
/// asserting model output, which is non-deterministic and would be flaky.
public protocol CategoryResponder: Sendable {
    func category(for prompt: String, allowed: [Category]) async throws -> String
}

/// A fresh LanguageModelSession per call, never one for the run. A shared
/// transcript would accumulate across 1,494 classifications and abort with
/// exceededContextWindowSize partway through, would let a guardrail refusal
/// colour later images, and would bias --verify toward agreeing with its own
/// prior answer.
public struct OnDeviceResponder: CategoryResponder {
    public init() {}

    /// Each description is capped when building the catalogue. `desc` is
    /// user-edited taxonomy.json content, not a compile-time constant, so an
    /// absurdly long or missing description must not be able to blow the
    /// ~4k-token on-device context budget (16 categories x unbounded desc
    /// would dwarf the 800-char OCR snippet). 120 characters is enough to
    /// convey what a category means without risking that budget. The name is
    /// never truncated: it is the literal value the model must return.
    static let maxDescChars = 120

    /// Extracted so the shape of the instructions the model receives is
    /// directly testable without invoking `LanguageModelSession`, which
    /// requires Apple Intelligence and would make the test flaky/unavailable
    /// in CI.
    static func catalogue(_ allowed: [Category]) -> String {
        allowed
            .map { category in
                let desc = category.desc.count > maxDescChars
                    ? String(category.desc.prefix(maxDescChars))
                    : category.desc
                return "- \(category.name): \(desc)"
            }
            .joined(separator: "\n")
    }

    /// Extracted so a test can pin that only names — never descriptions —
    /// reach the schema's anyOf set, without invoking the real model.
    static func names(for allowed: [Category]) -> [String] {
        allowed.map(\.name)
    }

    /// Generous against the measured call, tight against the measured wedge:
    /// a warm classify answer takes 2-5s, a cold first call ~19s, and a
    /// wedged one parks for minutes.
    static let callDeadline: TimeInterval = 30

    public func category(for prompt: String, allowed: [Category]) async throws -> String {
        // The session is built INSIDE the watchdog's operation, so the retry
        // after an abandoned wedge starts from a fresh session rather than
        // re-awaiting whatever state wedged the first one.
        try await ModelWatchdog.run(deadline: Self.callDeadline) {
            let session = LanguageModelSession(instructions: """
                You file screenshots into exactly one category.
                The categories and what each means:
                \(Self.catalogue(allowed))
                Choose the single best fit. Do not default to the broadest category \
                when the evidence is weak — prefer Unsorted over a poor fit.
                """)
            // String conforms to Generable, so it anchors a runtime anyOf set.
            // The taxonomy is user-edited after compilation, so @Generable — a
            // compile-time macro — cannot express this. Built from names only —
            // the constrained decoding contract is unchanged, and the model
            // still cannot return a name outside the set.
            let schema = GenerationSchema(type: String.self,
                                          description: "One screenshot category",
                                          anyOf: Self.names(for: allowed))
            // Greedy, not the default temperature sampling. Classification wants
            // the argmax label, not a draw from the label distribution: measured
            // on the real index, default sampling self-agreed only 44% on an
            // identical re-ask (16 categories; 51% at 7), which is decoder noise,
            // not evidence. Greedy removes the variance — it cannot add accuracy,
            // but it makes every answer reproducible and every later measurement
            // meaningful.
            let response = try await session.respond(
                to: prompt, schema: schema,
                options: GenerationOptions(sampling: .greedy))
            return try response.content.value(String.self)
        }
    }
}

public struct Classifier {
    public static let maxOCRChars = 800
    /// Samples shown in a group prompt. 6 members x ~250 chars plus the
    /// category catalogue sits well inside the ~4k-token window.
    public static let groupSampleCount = 6
    /// The retry shows fewer members: one poisonous member's text is the
    /// likely cause of a group refusal.
    public static let groupRetrySampleCount = 3

    private let taxonomy: Taxonomy
    private let responder: CategoryResponder

    public init(taxonomy: Taxonomy, responder: CategoryResponder) {
        self.taxonomy = taxonomy
        self.responder = responder
    }

    /// `variant` selects the phrasing. `.primary` is the normal path;
    /// `.alternate` exists so --verify re-asks a genuinely different question
    /// rather than measuring decoder sampling noise.
    public enum PromptVariant: Sendable {
        case primary
        case alternate
    }

    public func promptText(for r: IndexRecord,
                           variant: PromptVariant = .primary) -> String {
        // One renderer, shared with the proposer — see SignalLine.
        let signal = SignalLine.render(for: r)
        let snippet = String(r.ocr.prefix(Self.maxOCRChars))
        switch variant {
        case .primary:
            return "\(signal) \(snippet)"
        case .alternate:
            return "Screenshot evidence: \(signal)\nVisible text: \(snippet)\n"
                + "Which single category does this screenshot belong to?"
        }
    }

    public func groupPrompt(for group: ClassifyGroup, samples: Int,
                            variant: PromptVariant = .primary) -> String {
        // Sampler's snippet length, not the per-image maxOCRChars: several
        // members share one context window.
        let lines = group.members.prefix(samples).map { r in
            "- \(SignalLine.render(for: r)) \(String(r.ocr.prefix(Sampler.snippetChars)))"
        }.joined(separator: "\n")
        switch variant {
        case .primary:
            return "\(group.members.count) screenshots share one source: "
                + "\(group.evidence).\nSamples:\n\(lines)\n"
                + "Choose the single category that best fits this source."
        case .alternate:
            return "Source evidence: \(group.evidence) "
                + "(\(group.members.count) screenshots).\nSamples:\n\(lines)\n"
                + "Which single category does this source belong to?"
        }
    }

    /// One answer for the whole group, or nil when the model could not give
    /// one (two failed attempts, or constrained decoding missed the set).
    /// The runner owns LabelRecords: returning the bare category keeps this
    /// testable against a stub responder without duplicating label plumbing,
    /// and lets the runner route refused groups to the per-image path.
    public func groupCategory(_ group: ClassifyGroup,
                              variant: PromptVariant = .primary) async -> String? {
        for samples in [Self.groupSampleCount, Self.groupRetrySampleCount] {
            do {
                let name = try await responder.category(
                    for: groupPrompt(for: group, samples: samples,
                                     variant: variant),
                    allowed: taxonomy.categories)
                guard taxonomy.names.contains(name) else { return nil }
                return name
            } catch {
                continue
            }
        }
        return nil
    }

    public func classify(_ r: IndexRecord,
                         variant: PromptVariant = .primary) async -> LabelRecord {
        func label(_ category: String, _ reason: String) -> LabelRecord {
            LabelRecord(file: r.file, category: category, reason: reason,
                        modelConfidence: nil,
                        filterVersion: SceneFilter.filterVersion,
                        taxonomySignature: taxonomy.signature,
                        verifyAgreed: nil)
        }

        if SignalGate.hasNoSignal(r) {
            return label(Taxonomy.unsortedName, "no-signal")
        }

        do {
            let name = try await responder.category(
                for: promptText(for: r, variant: variant),
                allowed: taxonomy.categories)
            // Total by construction, not by pattern matching. A miss means
            // constrained decoding failed, so it surfaces rather than being
            // repaired into the nearest plausible name.
            guard taxonomy.names.contains(name) else {
                return label(Taxonomy.unsortedName, "schema-miss")
            }
            return label(name, "model")
        } catch is ModelAvailabilityError {
            // Distinguished from a refusal: Task 15 reads the reason histogram
            // as its diagnostic, so a wiring or availability fault must not
            // report as a model guardrail.
            return label(Taxonomy.unsortedName, "model-unavailable")
        } catch {
            // A refusal costs one image, never the batch.
            return label(Taxonomy.unsortedName, "guardrail")
        }
    }
}
