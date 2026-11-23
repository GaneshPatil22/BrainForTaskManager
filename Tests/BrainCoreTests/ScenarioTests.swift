import Foundation
import Testing
@testable import BrainCore

/// Hand-built graphs where the right answer is known by inspection, not by
/// running the formula. These are the seed of `datasets/scenarios/` in B2; the
/// JSON format mirrors what these build in Swift.
@Suite("Scenarios — known correct answers")
struct ScenarioTests {

    /// A medium task that unblocks five others should beat a pile of trivia.
    /// This is the product's core claim: "kills 2-3 birds".
    @Test("S1 — the hub beats a pile of errands")
    func hubWins() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()

        let hub = Fixtures.item(&gen, "Finalize data model", effort: .medium)
        graph.insert(hub)
        for i in 0..<5 {
            let downstream = Fixtures.item(&gen, "depends-\(i)", effort: .small)
            graph.insert(downstream)
            try graph.addEdge(
                Fixtures.confirmedEdge(
                    &gen, from: hub.id, to: downstream.id,
                    kind: .blocks))
        }
        for i in 0..<5 {
            graph.insert(Fixtures.item(&gen, "errand-\(i)", effort: .tiny))
        }

        let outputs = Brain.compute(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        #expect(outputs.next?.item.id == hub.id)
        #expect(outputs.next?.reason.contains("Unblocks 5 tasks") == true)
    }

    /// The bug this test was written to catch: a blocked item can legitimately
    /// rank first, but must never be offered as the thing to do next.
    ///
    /// Constructing this case is instructive. A blocker transitively reaches
    /// everything its dependent reaches, *plus* the dependent itself, so it
    /// almost always outranks it — the formula naturally promotes unblockers,
    /// which is the behaviour we want. The exception is effort and deadline
    /// asymmetry: a two-minute form due today, stuck behind a multi-day
    /// document hunt.
    @Test("S2 — `next` is never something the user cannot start")
    func nextIsAlwaysStartable() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()

        let gather = Fixtures.item(&gen, "Gather all documents", effort: .xlarge)
        let submit = Fixtures.item(
            &gen, "Submit the form", effort: .tiny,
            due: Fixtures.now)
        graph.insert(gather); graph.insert(submit)
        try graph.addEdge(
            Fixtures.confirmedEdge(
                &gen, from: gather.id, to: submit.id,
                kind: .blocks))

        let outputs = Brain.compute(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)

        #expect(
            outputs.ranked.first?.item.id == submit.id,
            "the blocked item genuinely ranks first — tiny effort, due today")
        #expect(
            outputs.next?.item.id == gather.id,
            "but `next` must be the thing that can actually be started")
        #expect(outputs.startable.map(\.item.id) == [gather.id])
        #expect(
            outputs.blocked.first { $0.item.id == submit.id }?.blockers.map(\.id)
                == [gather.id])
        #expect(
            outputs.quickWins.isEmpty,
            "the only quick-effort item is blocked, so there is no quick win")
    }

    /// Deadline pressure must be able to beat raw leverage when it is close.
    @Test("S3 — an imminent deadline overtakes a slightly better hub")
    func deadlineOvertakes() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()

        let overdue = Fixtures.item(
            &gen, "File GST return", effort: .small,
            due: Fixtures.calendar.date(
                byAdding: .day, value: -1,
                to: Fixtures.now))
        let hub = Fixtures.item(&gen, "Refactor auth", effort: .large)
        graph.insert(overdue); graph.insert(hub)
        for i in 0..<2 {
            let downstream = Fixtures.item(&gen, "auth-dep-\(i)")
            graph.insert(downstream)
            try graph.addEdge(
                Fixtures.confirmedEdge(
                    &gen, from: hub.id, to: downstream.id,
                    kind: .blocks))
        }

        let outputs = Brain.compute(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        #expect(outputs.next?.item.id == overdue.id)
        #expect(outputs.next?.reason.contains("overdue by 1 day") == true)
    }

    /// Quick wins must be genuinely quick AND not worthless.
    @Test("S4 — quick wins are low-effort and above the median")
    func quickWins() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()

        let worthwhile = Fixtures.item(
            &gen, "Send the invoice", effort: .tiny,
            due: Fixtures.calendar.date(
                byAdding: .day, value: 1,
                to: Fixtures.now))
        graph.insert(worthwhile)
        // Several heavy items drag the median down; none should be a quick win.
        for i in 0..<4 {
            graph.insert(Fixtures.item(&gen, "heavy-\(i)", effort: .xlarge))
        }

        let outputs = Brain.compute(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        #expect(outputs.quickWins.map(\.item.id) == [worthwhile.id])
    }

    /// The product promise that most depends on the graph being right.
    @Test("S5 — a chain reports the correct blocker at each step")
    func chain() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let titles = ["Pick a domain", "Set up DNS", "Issue TLS cert", "Deploy"]
        let items = titles.map { Fixtures.item(&gen, $0, effort: .small) }
        for item in items { graph.insert(item) }
        for i in 0..<3 {
            try graph.addEdge(
                Fixtures.confirmedEdge(
                    &gen, from: items[i].id,
                    to: items[i + 1].id, kind: .blocks))
        }

        let outputs = Brain.compute(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
        #expect(
            outputs.next?.item.title == "Pick a domain",
            "only the head of the chain is startable")
        #expect(outputs.blocked.count == 3)
        for blocked in outputs.blocked {
            #expect(blocked.blockers.count == 1, "each step waits on exactly its predecessor")
        }
        #expect(outputs.next?.reason.contains("Unblocks 3 tasks") == true)
    }

    /// AI suggestions must not change what the user is told until confirmed.
    @Test("S6 — unconfirmed AI links do not alter the recommendation")
    func unconfirmedDoesNotLeak() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()

        let quiet = Fixtures.item(&gen, "Write README", effort: .small)
        let other = Fixtures.item(&gen, "Buy milk", effort: .tiny)
        graph.insert(quiet); graph.insert(other)
        let baseline = Brain.compute(
            graph: graph, now: Fixtures.now,
            calendar: Fixtures.calendar
        ).next?.item.id

        // A model proposes that "Write README" unblocks six things. Unconfirmed.
        for i in 0..<6 {
            let guess = Fixtures.item(&gen, "ai-guess-\(i)")
            graph.insert(guess)
            try graph.addEdge(Fixtures.aiEdge(&gen, from: quiet.id, to: guess.id, kind: .blocks))
        }
        let after = Brain.compute(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)

        #expect(after.next?.item.id == baseline, "unconfirmed suggestions must not move the needle")
        #expect(
            after.ranked.first { $0.item.id == quiet.id }?.reason.contains("Unblocks") == false,
            "the reason must not claim unblocking on unconfirmed evidence")
    }

    /// An empty brain should say so, not crash or invent something.
    @Test("S7 — an empty graph produces empty output, not a guess")
    func empty() {
        let outputs = Brain.compute(
            graph: BrainGraph(), now: Fixtures.now,
            calendar: Fixtures.calendar)
        #expect(outputs.next == nil)
        #expect(outputs.ranked.isEmpty)
        #expect(outputs.quickWins.isEmpty)
        #expect(outputs.blocked.isEmpty)
    }

    /// Everything blocked by something else means nothing is startable — which
    /// cannot happen in a DAG, and this test proves the DAG guarantee holds.
    @Test("S8 — a DAG always has at least one startable item")
    func dagAlwaysHasARoot() throws {
        for seed in PropertyTests.seeds {
            let (graph, _) = Fixtures.randomGraph(seed: seed, itemCount: 30, edgeAttempts: 200)
            let outputs = Brain.compute(
                graph: graph, now: Fixtures.now,
                calendar: Fixtures.calendar)
            if !outputs.ranked.isEmpty {
                #expect(
                    outputs.next != nil,
                    "seed \(seed): open items exist but nothing is startable")
            }
        }
    }
}
