import Foundation
import Testing

@testable import BrainCore

@Suite("DatasetSplit")
struct DatasetSplitTests {

    /// Regression test for a real bug. Raw FNV-1a has weak avalanche on its
    /// trailing bytes, so sequential ids hashed in near-sequential order and
    /// `scenario-001…030` all landed on the same side of the split. The
    /// finalizer fixes it; this proves it stays fixed.
    @Test("Sequential ids do not cluster")
    func avalanche() {
        let ids = (1...200).map { String(format: "scenario-%03d", $0) }
        let hashes = ids.map(DatasetSplit.hash)

        // Rank the ids by hash. If avalanche is good, an id's rank is
        // uncorrelated with its sequence number.
        let order = zip(ids.indices, hashes).sorted { $0.1 < $1.1 }.map(\.0)
        let n = Double(order.count)
        let meanRank = (n - 1) / 2
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for (rank, index) in order.enumerated() {
            let a = Double(rank) - meanRank
            let b = Double(index) - meanRank
            covariance += a * b
            varianceA += a * a
            varianceB += b * b
        }
        let correlation = covariance / (varianceA * varianceB).squareRoot()
        #expect(abs(correlation) < 0.2, "hash rank correlates with id sequence: \(correlation)")
    }

    @Test("A one-character change moves roughly half the bits")
    func bitDiffusion() {
        var totalFlipped = 0
        for i in 0..<200 {
            let a = DatasetSplit.hash("scenario-\(i)")
            let b = DatasetSplit.hash("scenario-\(i + 1)")
            totalFlipped += (a ^ b).nonzeroBitCount
        }
        let mean = Double(totalFlipped) / 200
        #expect(mean > 24 && mean < 40, "mean flipped bits \(mean), expected near 32")
    }

    @Test("Assignment is deterministic")
    func deterministic() {
        for id in ["scenario-001", "a", "", "🎉"] {
            let first = DatasetSplit.forSynthetic(id: id)
            for _ in 0..<5 { #expect(DatasetSplit.forSynthetic(id: id) == first) }
        }
    }

    @Test("Stratify gives exact proportions and is order-independent")
    func stratifyProportions() {
        let ids = (1...130).map { "scenario-\($0)" }
        let assigned = DatasetSplit.stratify(ids: ids, testFraction: 0.3)
        #expect(assigned.values.filter { $0 == .test }.count == 39)
        #expect(assigned.values.filter { $0 == .dev }.count == 91)
        // Shuffling the input must not change any assignment.
        #expect(DatasetSplit.stratify(ids: ids.reversed(), testFraction: 0.3) == assigned)
    }

    /// Real captures are weighted toward test, because the test number is what
    /// gets reported and 30 rows proves nothing (`docs/05-targets.md`).
    @Test("Real captures land roughly 50/20/30")
    func realProportions() {
        let ids = (1...3000).map { "capture-\($0)" }
        var counts: [DatasetSplit: Int] = [:]
        for id in ids { counts[DatasetSplit.forReal(id: id), default: 0] += 1 }
        #expect(abs(Double(counts[.train] ?? 0) / 3000 - 0.5) < 0.04)
        #expect(abs(Double(counts[.dev] ?? 0) / 3000 - 0.2) < 0.04)
        #expect(abs(Double(counts[.test] ?? 0) / 3000 - 0.3) < 0.04)
    }
}
