import Foundation

/// One measured number, or an honest admission that it is not measured yet.
///
/// `value == nil` is the important case. A metric we cannot yet compute prints
/// as `not measured` and never as `0.000`, because a zero that looks like a
/// result is worse than no result at all.
public struct Metric: Codable, Sendable {
    public enum Unit: String, Codable, Sendable {
        case percent, ratio, count, milliseconds, boolean
    }

    public let name: String
    public let value: Double?
    public let unit: Unit
    /// Why it is not measured, or what bounds it. Printed alongside.
    public var note: String?
    /// Any breach fails the gate at any tolerance. Used for the invariants.
    public var mustNotExceed: Double?
    /// Allowed regression before the gate fails, in this metric's unit.
    public var tolerance: Double?
    public var higherIsBetter: Bool
    /// Sample size behind the number, so a small n cannot look authoritative.
    public var sampleSize: Int?

    /// Explicit init so call sites can order arguments for readability; the
    /// memberwise one would force declaration order on every metric.
    public init(
        name: String, value: Double?, unit: Unit,
        tolerance: Double? = nil, mustNotExceed: Double? = nil,
        higherIsBetter: Bool = true, sampleSize: Int? = nil, note: String? = nil
    ) {
        self.name = name
        self.value = value
        self.unit = unit
        self.note = note
        self.mustNotExceed = mustNotExceed
        self.tolerance = tolerance
        self.higherIsBetter = higherIsBetter
        self.sampleSize = sampleSize
    }

    public var isMeasured: Bool { value != nil }

    public func formatted() -> String {
        guard let value else { return "not measured" }
        switch unit {
        case .percent: return String(format: "%.1f%%", value * 100)
        case .ratio: return String(format: "%.4f", value)
        case .count: return String(format: "%.0f", value)
        case .milliseconds: return String(format: "%.1f ms", value)
        case .boolean: return value == 1 ? "yes" : "NO"
        }
    }
}

public struct Section: Codable, Sendable {
    public let name: String
    public var metrics: [Metric]

    public init(name: String, metrics: [Metric]) {
        self.name = name
        self.metrics = metrics
    }
}

/// The whole run. Serialised to `eval/baselines/<split>.json` when promoted,
/// and compared against that baseline by the gate.
public struct Scorecard: Codable, Sendable {
    public let runId: String
    public let generatedAt: String
    public let dataset: String
    public let split: String
    /// Which inputs were actually present, with counts. Printed at the top so a
    /// run against a partial dataset cannot be mistaken for a full one.
    public let sets: [String: Int]
    public var sections: [Section]

    public init(
        runId: String, generatedAt: String, dataset: String, split: String,
        sets: [String: Int], sections: [Section]
    ) {
        self.runId = runId
        self.generatedAt = generatedAt
        self.dataset = dataset
        self.split = split
        self.sets = sets
        self.sections = sections
    }

    public func metric(_ section: String, _ name: String) -> Metric? {
        sections.first { $0.name == section }?.metrics.first { $0.name == name }
    }

    // MARK: - Rendering

    public func render(baseline: Scorecard?) -> String {
        var out = ""
        out += "\nBRAIN SCORECARD            dataset \(dataset) · split \(split) · \(generatedAt)\n"
        out += "run \(runId)\n"
        out +=
            "sets: "
            + sets.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            .joined(separator: " · ") + "\n"

        for section in sections {
            out += "\n\(section.name.uppercased())\n"
            for metric in section.metrics {
                let delta = Self.delta(metric, baseline?.metric(section.name, metric.name))
                var line = String(
                    format: "  %-26@ %14@ %9@",
                    metric.name as NSString,
                    metric.formatted() as NSString,
                    delta as NSString)
                if let n = metric.sampleSize { line += "  n=\(n)" }
                if let note = metric.note { line += "  \(note)" }
                out += line + "\n"
            }
        }

        let unmeasured = sections.flatMap(\.metrics).filter { !$0.isMeasured }.count
        if unmeasured > 0 {
            out += "\n\(unmeasured) metric\(unmeasured == 1 ? "" : "s") not measured yet — "
            out += "the notes say which phase each arrives in.\n"
        }
        return out
    }

    private static func delta(_ metric: Metric, _ base: Metric?) -> String {
        guard let value = metric.value, let baseValue = base?.value else { return "—" }
        let change = value - baseValue
        guard abs(change) > 1e-9 else { return "=" }
        let sign = change > 0 ? "+" : ""
        switch metric.unit {
        case .percent: return String(format: "%@%.1fpp", sign, change * 100)
        case .milliseconds: return String(format: "%@%.1f", sign, change)
        default: return String(format: "%@%.4f", sign, change)
        }
    }

    // MARK: - Gate

    public struct GateResult {
        public var failures: [String] = []
        public var improvements: [String] = []
        public var isPass: Bool { failures.isEmpty }
    }

    /// Compares against a stored baseline. Improvements never fail, and never
    /// silently update the baseline — promoting one is a separate, deliberate,
    /// committed act (`docs/04-scorecard.md`).
    public func gate(against baseline: Scorecard) -> GateResult {
        var result = GateResult()
        for section in sections {
            for metric in section.metrics {
                guard let value = metric.value else { continue }

                if let ceiling = metric.mustNotExceed, value > ceiling {
                    result.failures.append(
                        "\(section.name)/\(metric.name): \(metric.formatted()) exceeds hard limit "
                            + "\(ceiling) — an invariant, not a tolerance")
                    continue
                }
                guard let base = baseline.metric(section.name, metric.name)?.value,
                    let tolerance = metric.tolerance
                else { continue }

                let change = metric.higherIsBetter ? value - base : base - value
                if change < -tolerance {
                    // A metric can move because the code changed or because the
                    // *sample* changed. Conflating the two turns the gate into
                    // noise, so say which it is rather than cry regression at a
                    // bigger, more honest denominator.
                    let baseN = baseline.metric(section.name, metric.name)?.sampleSize
                    var reason =
                        "\(section.name)/\(metric.name): \(metric.formatted()) vs baseline "
                        + "\(String(format: "%.4f", base)) — beyond tolerance \(tolerance)"
                    if let n = metric.sampleSize, let baseN,
                        abs(Double(n - baseN)) / Double(max(baseN, 1)) > 0.2
                    {
                        reason +=
                            " [SAMPLE CHANGED n=\(baseN)→\(n): likely not a code regression — "
                            + "re-promote the baseline if the larger sample is the better number]"
                    }
                    result.failures.append(reason)
                } else if change > tolerance {
                    result.improvements.append("\(section.name)/\(metric.name)")
                }
            }
        }
        return result
    }
}
