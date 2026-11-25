import BrainCore
import Foundation

/// Shared, fully deterministic test scaffolding. Nothing here touches the clock
/// or the system RNG — every test is reproducible from its seed.
enum Fixtures {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!

    static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    /// Monday, 23 Nov 2026, 10:00 IST. Fixed so weekday arithmetic is checkable.
    static let now: Date = {
        var comps = DateComponents(year: 2026, month: 11, day: 23, hour: 10, minute: 0)
        comps.timeZone = zone
        return calendar.date(from: comps)!
    }()

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 23, _ min: Int = 59) -> Date {
        var comps = DateComponents(year: y, month: m, day: d, hour: h, minute: min)
        comps.timeZone = zone
        return calendar.date(from: comps)!
    }

    static func generator(seed: UInt64 = 1) -> ULIDGenerator {
        ULIDGenerator(seed: seed, clock: { UInt64(now.timeIntervalSince1970 * 1000) })
    }

    /// `type` defaults to nil — *unknown*, which is what the pipeline produces
    /// while a T3 question is unanswered, and which still ranks.
    static func item(
        _ gen: inout ULIDGenerator, _ title: String,
        effort: EffortBucket = .unknown,
        due: Date? = nil,
        status: ItemStatus = .open,
        type: ItemType? = nil
    ) -> Item {
        Item(
            id: gen.next(), title: title,
            type: type.map { Classified($0, confidence: 1, tier: .user) } ?? .unknown(),
            status: status,
            effort: Classified(effort, confidence: 1, tier: .user),
            dueAt: due.map { Classified($0, confidence: 1, tier: .t0) } ?? .unknown(),
            createdAt: now)
    }

    static func confirmedEdge(
        _ gen: inout ULIDGenerator, from: ULID, to: ULID,
        kind: EdgeKind
    ) -> Edge {
        Edge(id: gen.next(), from: from, to: to, kind: kind, source: .user, confirmed: true)
    }

    static func aiEdge(
        _ gen: inout ULIDGenerator, from: ULID, to: ULID,
        kind: EdgeKind
    ) -> Edge {
        Edge(
            id: gen.next(), from: from, to: to, kind: kind, confidence: 0.7,
            source: .t2Model, confirmed: false)
    }

    /// Builds a random but reproducible graph. Used by the property tests.
    static func randomGraph(seed: UInt64, itemCount: Int, edgeAttempts: Int)
        -> (graph: BrainGraph, generator: ULIDGenerator)
    {
        var gen = generator(seed: seed)
        var rng = SplitMix64(seed: seed &* 31 &+ 7)
        var graph = BrainGraph()

        let buckets = EffortBucket.allCases
        var ids: [ULID] = []
        for i in 0..<itemCount {
            let bucket = buckets[Int(rng.next() % UInt64(buckets.count))]
            let hasDue = rng.next() % 3 == 0
            let offset = Int(rng.next() % 20) - 5
            let item = item(
                &gen, "item-\(i)", effort: bucket,
                due: hasDue ? calendar.date(byAdding: .day, value: offset, to: now) : nil,
                status: rng.next() % 10 == 0 ? .done : .open)
            graph.insert(item)
            ids.append(item.id)
        }
        let goal = Goal(id: gen.next(), title: "goal", createdAt: now)
        graph.insert(goal)

        for _ in 0..<edgeAttempts {
            let a = ids[Int(rng.next() % UInt64(ids.count))]
            let b = ids[Int(rng.next() % UInt64(ids.count))]
            let confirmed = rng.next() % 2 == 0
            let kind: EdgeKind = rng.next() % 5 == 0 ? .serves : .blocks
            let edge =
                kind == .serves
                ? Edge(
                    id: gen.next(), from: a, to: goal.id, kind: .serves,
                    source: confirmed ? .user : .t2Model, confirmed: confirmed)
                : Edge(
                    id: gen.next(), from: a, to: b, kind: .blocks,
                    source: confirmed ? .user : .t2Model, confirmed: confirmed)
            // Rejections are expected and are the point — see the cycle property test.
            try? graph.addEdge(edge)
        }
        return (graph, gen)
    }
}
