import Foundation
import Testing
@testable import BrainCore

/// The worked examples in `docs/02-scoring-spec.md` are hand-computed and act as
/// an independent oracle: if the implementation and the spec disagree, one of
/// them is wrong and the test says which numbers were expected.
@Suite("Scoring — spec worked examples")
struct ScoringSpecExamples {

    @Test("Effort denominators match the spec table")
    func effortDenominators() {
        let expected: [EffortBucket: Double] = [
            .tiny: 0.589, .small: 1.000, .medium: 1.350, .large: 1.802, .xlarge: 2.256,
        ]
        for (bucket, value) in expected {
            #expect(
                abs(Scoring.effortDenominator(bucket) - value) < 0.001,
                "\(bucket) denominator")
        }
    }

    /// A — "Call plumber", tiny, no due date, U=0, G=0 → 0.850
    @Test("Example A: bare quick task")
    func exampleA() {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let item = Fixtures.item(&gen, "Call plumber", effort: .tiny)
        graph.insert(item)

        let score = Scoring.score(
            item: item, in: graph, now: Fixtures.now,
            calendar: Fixtures.calendar)
        #expect(abs(score.leverage - 0.850) < 0.001)
        #expect(score.unblockedConfirmed == 0)
        #expect(score.duePressure == 0)
    }

    /// B — "Finalize API spec", medium, due in 3 days, U=4, G=2 → 3.248
    @Test("Example B: hub task with a deadline")
    func exampleB() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let hub = Fixtures.item(
            &gen, "Finalize API spec", effort: .medium,
            due: Fixtures.calendar.date(byAdding: .day, value: 3, to: Fixtures.now))
        graph.insert(hub)
        for i in 0..<4 {
            let downstream = Fixtures.item(&gen, "downstream-\(i)")
            graph.insert(downstream)
            try graph.addEdge(
                Fixtures.confirmedEdge(
                    &gen, from: hub.id, to: downstream.id,
                    kind: .blocks))
        }
        for i in 0..<2 {
            let goal = Goal(id: gen.next(), title: "goal-\(i)", createdAt: Fixtures.now)
            graph.insert(goal)
            try graph.addEdge(
                Fixtures.confirmedEdge(
                    &gen, from: hub.id, to: goal.id,
                    kind: .serves))
        }

        let score = Scoring.score(
            item: hub, in: graph, now: Fixtures.now,
            calendar: Fixtures.calendar)
        #expect(score.unblockedConfirmed == 4)
        #expect(score.goalsConfirmed == 2)
        #expect(abs(score.duePressure - (1 - 3.0 / 14.0)) < 0.0001)
        #expect(abs(score.leverage - 3.248) < 0.001)
    }

    /// C — "Rewrite onboarding copy", large, no due, U=1, G=1 → 1.239
    @Test("Example C: half-day task with modest leverage")
    func exampleC() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let item = Fixtures.item(&gen, "Rewrite onboarding copy", effort: .large)
        let downstream = Fixtures.item(&gen, "downstream")
        let goal = Goal(id: gen.next(), title: "goal", createdAt: Fixtures.now)
        graph.insert(item); graph.insert(downstream); graph.insert(goal)
        try graph.addEdge(
            Fixtures.confirmedEdge(&gen, from: item.id, to: downstream.id, kind: .blocks))
        try graph.addEdge(Fixtures.confirmedEdge(&gen, from: item.id, to: goal.id, kind: .serves))

        let score = Scoring.score(
            item: item, in: graph, now: Fixtures.now,
            calendar: Fixtures.calendar)
        #expect(abs(score.leverage - 1.239) < 0.001)
    }

    @Test("Spec ranking holds: B > C > A")
    func specRanking() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()

        let a = Fixtures.item(&gen, "Call plumber", effort: .tiny)
        let b = Fixtures.item(
            &gen, "Finalize API spec", effort: .medium,
            due: Fixtures.calendar.date(byAdding: .day, value: 3, to: Fixtures.now))
        let c = Fixtures.item(&gen, "Rewrite onboarding copy", effort: .large)
        for item in [a, b, c] { graph.insert(item) }

        for i in 0..<4 {
            let d = Fixtures.item(&gen, "b-down-\(i)")
            graph.insert(d)
            try graph.addEdge(Fixtures.confirmedEdge(&gen, from: b.id, to: d.id, kind: .blocks))
        }
        for i in 0..<2 {
            let g = Goal(id: gen.next(), title: "b-goal-\(i)", createdAt: Fixtures.now)
            graph.insert(g)
            try graph.addEdge(Fixtures.confirmedEdge(&gen, from: b.id, to: g.id, kind: .serves))
        }
        let cDown = Fixtures.item(&gen, "c-down")
        let cGoal = Goal(id: gen.next(), title: "c-goal", createdAt: Fixtures.now)
        graph.insert(cDown); graph.insert(cGoal)
        try graph.addEdge(Fixtures.confirmedEdge(&gen, from: c.id, to: cDown.id, kind: .blocks))
        try graph.addEdge(Fixtures.confirmedEdge(&gen, from: c.id, to: cGoal.id, kind: .serves))

        let ranked = Scoring.rank(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        let order = ranked.map(\.itemId)
        #expect(order.firstIndex(of: b.id)! < order.firstIndex(of: c.id)!)
        #expect(order.firstIndex(of: c.id)! < order.firstIndex(of: a.id)!)
    }
}

@Suite("Scoring — due pressure")
struct DuePressureTests {
    @Test("Overdue and due-today both saturate at 1.0")
    func saturates() {
        let yesterday = Fixtures.calendar.date(byAdding: .day, value: -1, to: Fixtures.now)!
        #expect(
            Scoring.duePressure(
                dueAt: yesterday, now: Fixtures.now,
                calendar: Fixtures.calendar) == 1.0)
        #expect(
            Scoring.duePressure(
                dueAt: Fixtures.now, now: Fixtures.now,
                calendar: Fixtures.calendar) == 1.0)
    }

    @Test("Beyond the 14-day horizon, pressure is zero")
    func horizon() {
        let far = Fixtures.calendar.date(byAdding: .day, value: 30, to: Fixtures.now)!
        #expect(
            Scoring.duePressure(
                dueAt: far, now: Fixtures.now,
                calendar: Fixtures.calendar) == 0)
    }

    @Test("No due date means no pressure, not a default deadline")
    func absent() {
        #expect(
            Scoring.duePressure(
                dueAt: nil, now: Fixtures.now,
                calendar: Fixtures.calendar) == 0)
    }

    @Test("Pressure decreases monotonically with distance")
    func monotonic() {
        var previous = 1.1
        for day in 0...14 {
            let due = Fixtures.calendar.date(byAdding: .day, value: day, to: Fixtures.now)!
            let pressure = Scoring.duePressure(
                dueAt: due, now: Fixtures.now,
                calendar: Fixtures.calendar)
            #expect(pressure <= previous, "day \(day)")
            previous = pressure
        }
    }
}
