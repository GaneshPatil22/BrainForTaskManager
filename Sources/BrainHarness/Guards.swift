import BrainCore
import Foundation

/// Which guards are on. Each is individually toggleable so B4 can add them one
/// at a time and report each one's measured effect (`docs/07-harness-spec.md`).
///
/// Guards 5 (deterministic dates) and 6 (cycle rejection) are absent by
/// design: they are correctness invariants enforced in `BrainCore`, not
/// features to measure. A configuration where a model supplies a date or
/// creates a cycle is not one we want to be able to run.
public struct GuardConfig: Sendable, Hashable {
    public var idWhitelist = true
    public var schema = true
    public var abstention = true
    public var crossCheck = true
    public var piiStrip = true
    public var claimCheck = true

    public init() {}
    public static let all = GuardConfig()
    public static var none: GuardConfig {
        var config = GuardConfig()
        config.idWhitelist = false
        config.schema = false
        config.abstention = false
        config.crossCheck = false
        config.piiStrip = false
        config.claimCheck = false
        return config
    }
}

/// Which guard rejected something, for the scorecard's per-guard breakdown.
public enum GuardName: String, Sendable, CaseIterable {
    case idWhitelist, schema, abstention, crossCheck, piiStrip, claimCheck
}

public struct GuardOutcome: Sendable {
    public let accepted: String?
    public let fired: [GuardName]
    public let reason: String?

    public static func pass(_ value: String?) -> GuardOutcome {
        GuardOutcome(accepted: value, fired: [], reason: nil)
    }
    public static func reject(_ guardName: GuardName, _ reason: String) -> GuardOutcome {
        GuardOutcome(accepted: nil, fired: [guardName], reason: reason)
    }
}

public enum Guards {

    // MARK: - Guard 1: ID whitelist

    /// Rejects any answer outside the set the model was given.
    ///
    /// This is why the hallucinated-ID target is **exactly 0** rather than
    /// "low": the check is set membership in code, not a property of the model.
    /// `docs/04-scorecard.md` fails the gate on any non-zero value.
    public static func idWhitelist(
        answer: String?, allowed: [String], enabled: Bool = true
    ) -> GuardOutcome {
        guard let answer, !answer.isEmpty else { return .pass(nil) }
        guard enabled else { return .pass(answer) }
        guard allowed.contains(answer) else {
            return .reject(.idWhitelist, "answer \"\(answer)\" is not in the candidate set")
        }
        return .pass(answer)
    }

    // MARK: - Guard 3: schema / enum validation

    /// Rejects anything that is not one of the permitted values, after
    /// normalising whitespace and case.
    ///
    /// Models wrap answers in prose, quotes and markdown. Normalising first
    /// means a correct answer in a slightly wrong shape is accepted rather
    /// than thrown away, while anything genuinely outside the set still fails.
    public static func schema(
        raw: String, allowed: [String], enabled: Bool = true
    ) -> GuardOutcome {
        guard enabled else { return .pass(raw) }
        let cleaned =
            raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;:*_[](){}"))
            .lowercased()
        if cleaned.isEmpty || cleaned == "unknown" || cleaned == "none" || cleaned == "null" {
            return .pass(nil)
        }
        if let exact = allowed.first(where: { $0.lowercased() == cleaned }) {
            return .pass(exact)
        }
        // A single permitted value appearing as a whole word in a wordy answer.
        let matches = allowed.filter { candidate in
            cleaned.range(
                of: "\\b\(NSRegularExpression.escapedPattern(for: candidate.lowercased()))\\b",
                options: .regularExpression) != nil
        }
        if matches.count == 1 { return .pass(matches[0]) }
        return .reject(.schema, "output \"\(raw.prefix(60))\" is not one permitted value")
    }

    // MARK: - Guard 4: abstention

    /// Below the threshold, discard the answer. The eval rewards abstaining
    /// over a wrong guess, so a low-confidence answer is worth less than none.
    public static func abstention(
        answer: String?, confidence: Double, threshold: Double, enabled: Bool = true
    ) -> GuardOutcome {
        guard enabled, let answer else { return .pass(answer) }
        guard confidence >= threshold else {
            return .reject(
                .abstention,
                String(format: "confidence %.2f below threshold %.2f", confidence, threshold))
        }
        return .pass(answer)
    }

    // MARK: - Guard 7: cross-check

    /// Two tiers agreeing accepts; disagreeing leaves it unconfirmed.
    ///
    /// Returns the agreed value, or nil. nil is not a failure — it means the
    /// edge stays unconfirmed and the user decides, which is the product
    /// behaviour we want anyway.
    public static func crossCheck(
        _ first: String?, _ second: String?, enabled: Bool = true
    ) -> GuardOutcome {
        guard enabled else { return .pass(first) }
        guard let first, let second else { return .pass(nil) }
        guard first == second else {
            return .reject(.crossCheck, "tiers disagree: \"\(first)\" vs \"\(second)\"")
        }
        return .pass(first)
    }

    // MARK: - Guard 10: PII strip

    /// Redacts phone numbers, emails, amounts, OTPs and card-like digit runs
    /// before anything leaves the machine.
    ///
    /// Free-tier terms permit content to be used for product improvement
    /// (ADR-0002). This costs nothing and materially improves what the T&C can
    /// honestly say.
    public static func stripPII(_ text: String, enabled: Bool = true) -> (String, Bool) {
        guard enabled else { return (text, false) }
        var output = text
        let rules: [(String, String)] = [
            // Email before phone: an address can contain digit runs.
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
            (#"(?:\+?\d{1,3}[ -]?)?(?:\d{5}[ -]?\d{5}|\d{10})\b"#, "[phone]"),
            (#"\b\d{4}[ -]?\d{4}[ -]?\d{4}\b"#, "[id-number]"),
            (#"(?:₹|rs\.?|inr)\s?\d[\d,]*(?:\.\d+)?"#, "[amount]"),
            // Bare Indian shorthand: "50K", "1.5k", "2 lakh", "3cr". Added
            // after B4 measured the guard against 300 real captures and found
            // it redacted **nothing** — every amount Ganesh writes is in this
            // form, and none carries a currency marker. A guard that never
            // fires on real data is not a guard.
            (#"\b\d+(?:\.\d+)?\s?(?:k|lakh|lacs?|lakhs?|cr|crores?)\b"#, "[amount]"),
            (#"\b(?:otp|pin|cvv)\s*(?:is|:)?\s*\d{3,8}\b"#, "[otp]"),
        ]
        for (pattern, replacement) in rules {
            guard
                let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            output = regex.stringByReplacingMatches(
                in: output, range: NSRange(output.startIndex..., in: output),
                withTemplate: replacement)
        }
        return (output, output != text)
    }

    // MARK: - Guard 12: claim check

    /// A rephrased explanation may only restate facts the graph already holds.
    ///
    /// Checks every number in the rephrasing against the numbers in the
    /// template. A model that turns "unblocks 3 tasks" into "unblocks 5 tasks"
    /// is discarded and the template is shown instead.
    public static func claimCheck(
        rephrased: String, facts: String, enabled: Bool = true
    ) -> GuardOutcome {
        guard enabled else { return .pass(rephrased) }
        let numbers: (String) -> Set<String> = { text in
            Set(
                text.split(whereSeparator: { !$0.isNumber }).map(String.init)
                    .filter { !$0.isEmpty })
        }
        let invented = numbers(rephrased).subtracting(numbers(facts))
        guard invented.isEmpty else {
            return .reject(
                .claimCheck,
                "rephrasing invents numbers not in the facts: \(invented.sorted().joined(separator: ", "))"
            )
        }
        return .pass(rephrased)
    }
}
