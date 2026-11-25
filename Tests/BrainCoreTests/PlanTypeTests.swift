import Foundation
import Testing

@testable import BrainCore

/// Which *types* belong in the plan at all.
///
/// **The bug this suite exists for.** `Scoring.rank` scored every open item
/// whatever its type, so "rust vs go for the backend?" — captured as an idea —
/// could outrank real work, become `next`, and be proposed as the day's big
/// task. Capturing a thought is not committing to act on it, and a tool that
/// treats the two alike punishes you for thinking out loud, which is the one
/// thing the product exists to make cheap.
///
/// Every derived output comes off the ranked list, so one filter in `rank`
/// settles `ranked`, `startable`, `next`, `quickWins` and `blocked` together.
/// These tests assert all five rather than trusting that.
@Suite("Plan membership by type")
struct PlanTypeTests {

    func outputs(_ graph: BrainGraph) -> BrainOutputs {
        Brain.compute(graph: graph, now: Fixtures.now, calendar: Fixtures.calendar)
    }

    @Test(
        "An idea or a note never reaches the plan",
        arguments: [ItemType.idea, .note])
    func excluded(type: ItemType) {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let thought = Fixtures.item(&gen, "rust vs go for the backend?", effort: .tiny, type: type)
        let work = Fixtures.item(&gen, "pay the electricity bill", effort: .tiny, type: .task)
        graph.insert(thought)
        graph.insert(work)

        let plan = outputs(graph)
        #expect(!plan.ranked.contains { $0.item.id == thought.id })
        #expect(!plan.startable.contains { $0.item.id == thought.id })
        #expect(!plan.quickWins.contains { $0.item.id == thought.id })
        #expect(!plan.blocked.contains { $0.item.id == thought.id })
        #expect(plan.next?.item.id != thought.id)
        #expect(plan.next?.item.id == work.id, "the actual work is what is left")
    }

    /// `link` is in on purpose. "Read this" is an action with a real duration,
    /// so it ranks like any other small job. Revisit if saved links turn out
    /// to be hoarded rather than read — that would show as links piling up at
    /// the top of quick wins and being dismissed, which is a measurement.
    @Test(
        "A task, a reminder and a link all reach the plan",
        arguments: [ItemType.task, .reminder, .link])
    func included(type: ItemType) {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let item = Fixtures.item(&gen, "read the swift concurrency post", effort: .tiny, type: type)
        graph.insert(item)

        #expect(outputs(graph).ranked.contains { $0.item.id == item.id })
    }

    /// A capture is never lost. `type` is nil while the ladder abstained and a
    /// T3 question is waiting, and hiding those would mean a capture silently
    /// missing from the plan until the user answers a question they have not
    /// been shown. Showing something dismissible is the recoverable direction.
    @Test("An item whose type is not yet known still ranks")
    func unknownTypeStillRanks() {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let item = Fixtures.item(&gen, "the thing mahesh mentioned", effort: .tiny)
        #expect(item.type.value == nil, "the fixture is genuinely unknown")
        graph.insert(item)

        #expect(outputs(graph).ranked.contains { $0.item.id == item.id })
    }

    /// The escape hatch, and the reason this needs no migration: membership is
    /// computed at rank time from the item's current type, so correcting a
    /// type is all it takes.
    @Test("Changing an idea to a task makes it rank normally")
    func retypingRestoresIt() {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        var item = Fixtures.item(&gen, "build the gym tracker", effort: .small, type: .idea)
        graph.insert(item)
        #expect(outputs(graph).ranked.isEmpty)

        item.type = Classified(.task, confidence: 1, tier: .user)
        graph.insert(item)
        #expect(outputs(graph).ranked.contains { $0.item.id == item.id })
    }

    // MARK: - Still in the graph

    /// The half of the decision that is easy to lose: excluded from the plan
    /// is not excluded from the graph. An open idea that blocks a task still
    /// blocks it, and still shows up as that task's blocker — otherwise
    /// "decide the stack, then build it" would quietly become startable.
    @Test("An idea still blocks a task, and is named as the blocker")
    func ideaStillBlocks() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let decision = Fixtures.item(&gen, "rust vs go for the backend?", type: .idea)
        let work = Fixtures.item(&gen, "scaffold the backend", effort: .small, type: .task)
        graph.insert(decision)
        graph.insert(work)
        try graph.addEdge(
            Fixtures.confirmedEdge(&gen, from: decision.id, to: work.id, kind: .blocks))

        let plan = outputs(graph)
        #expect(plan.blocked.contains { $0.item.id == work.id }, "still blocked by a thought")
        #expect(
            plan.blocked.first { $0.item.id == work.id }?.blockers.contains { $0.id == decision.id }
                == true, "and the thought is named, so the chain is visible")
        #expect(!plan.startable.contains { $0.item.id == work.id })
        #expect(!plan.ranked.contains { $0.item.id == decision.id }, "but it is not itself work")
    }

    @Test("An excluded item stays in the graph for goal links")
    func staysInGraph() {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        var idea = Fixtures.item(&gen, "a better onboarding flow", type: .idea)
        let goal = gen.next()
        idea.goalId = Classified(goal, confidence: 1, tier: .user)
        graph.insert(idea)

        #expect(graph.items[idea.id] != nil, "the plan ignores it; the graph does not")
        #expect(graph.items[idea.id]?.goalId.value == goal)
        #expect(graph.openItems.contains { $0.id == idea.id }, "still open, still counted")
    }

    /// Quick wins take the median leverage over startable candidates, so
    /// excluding ideas changes which items clear the bar. Stated as a test
    /// because it is a real consequence, not an accident: a backlog of
    /// captured thoughts can no longer drag the quick-win threshold down.
    @Test("Captured thoughts no longer move the quick-win bar")
    func thoughtsDoNotMoveTheMedian() {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let work = Fixtures.item(&gen, "pay the electricity bill", effort: .tiny, type: .task)
        graph.insert(work)
        let withoutThoughts = outputs(graph).quickWins.map(\.item.id)

        for index in 0..<5 {
            graph.insert(Fixtures.item(&gen, "a thought \(index)", effort: .tiny, type: .idea))
        }
        #expect(outputs(graph).quickWins.map(\.item.id) == withoutThoughts)
    }
}
