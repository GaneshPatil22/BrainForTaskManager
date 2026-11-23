import Foundation

/// Which split a dataset row belongs to.
///
/// Assignment is a **pure function of the row's id**, never random and never
/// chosen by hand. Two consequences that matter:
///
/// - Adding new rows never reshuffles existing ones, so baselines stay
///   comparable across months (`docs/03-dataset-schema.md`).
/// - Nobody — human or model — picks which rows land in `test`. That is what
///   makes the held-out number meaningful.
public enum DatasetSplit: String, Sendable, Codable, CaseIterable {
    case train, dev, test

    /// Stable, well-spread, dependency-free. Splitting needs those three
    /// properties and not cryptographic ones, so FNV-1a rather than SHA-256.
    public static func hash(_ id: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(id.utf8) {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return value
    }

    /// Synthetic data: 70 / 20 / 10. Abundant, so the train split carries volume.
    public static func forSynthetic(id: String) -> DatasetSplit {
        switch hash(id) % 10 {
        case 0...6: .train
        case 7...8: .dev
        default: .test
        }
    }

    /// Real captures: 50 / 20 / 30, weighted toward test because the test
    /// number is what gets reported and 30 rows proves nothing
    /// (`docs/05-targets.md`).
    public static func forReal(id: String) -> DatasetSplit {
        switch hash(id) % 10 {
        case 0...4: .train
        case 5...6: .dev
        default: .test
        }
    }

    /// Hand-ranked scenarios: **dev / test only, 70 / 30.** There is nothing to
    /// train on here — these are ground truth for evaluation.
    ///
    /// `dev` is what weights and rules may be tuned against. `test` is looked at
    /// only at a phase gate. Without that separation, tuning the formula until
    /// it matches every scenario would be marking our own homework, and the
    /// resulting agreement figure would mean nothing.
    ///
    /// **Stratified rather than per-id**, because a per-id hash on 30 scenarios
    /// landed 24/6, and a 6-scenario held-out set carries a ±24 point interval —
    /// too wide to be worth having. Sorting by hash and cutting at 70% gives the
    /// exact proportion at any n, while still being a pure function of the ids:
    /// nobody picks which scenarios are held out.
    ///
    /// The trade-off is that adding scenarios can move an existing one across
    /// the boundary. That is acceptable only while the test set has never been
    /// looked at. **Once a test result is reported at a phase gate the split
    /// freezes** — which is why `brain split` stamps the assignment into the
    /// files and never overwrites an existing stamp without `--restamp`.
    public static func stratify(ids: [String], testFraction: Double = 0.3)
        -> [String: DatasetSplit]
    {
        // Sort by hash, tie-broken by id, so the order is total and reproducible.
        let ordered = ids.sorted { a, b in
            let (ha, hb) = (hash(a), hash(b))
            return ha == hb ? a < b : ha < hb
        }
        let testCount = Int((Double(ordered.count) * testFraction).rounded())
        var result: [String: DatasetSplit] = [:]
        for (index, id) in ordered.enumerated() {
            result[id] = index < testCount ? .test : .dev
        }
        return result
    }
}
