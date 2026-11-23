import Foundation
import Testing
@testable import BrainCore

@Suite("Graph — cycle safety")
struct CycleTests {

    @Test("A direct back-edge is rejected")
    func directCycle() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let a = Fixtures.item(&gen, "a"), b = Fixtures.item(&gen, "b")
        graph.insert(a); graph.insert(b)
        try graph.addEdge(Fixtures.confirmedEdge(&gen, from: a.id, to: b.id, kind: .blocks))

        #expect(throws: GraphError.wouldCreateCycle(from: b.id, to: a.id)) {
            try graph.addEdge(Fixtures.confirmedEdge(&gen, from: b.id, to: a.id, kind: .blocks))
        }
        #expect(!graph.hasCycle())
    }

    @Test("A long back-edge is rejected")
    func transitiveCycle() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let items = (0..<6).map { Fixtures.item(&gen, "n\($0)") }
        for item in items { graph.insert(item) }
        for i in 0..<5 {
            try graph.addEdge(
                Fixtures.confirmedEdge(
                    &gen, from: items[i].id,
                    to: items[i + 1].id, kind: .blocks))
        }
        #expect(throws: GraphError.self) {
            try graph.addEdge(
                Fixtures.confirmedEdge(
                    &gen, from: items[5].id,
                    to: items[0].id, kind: .blocks))
        }
        #expect(!graph.hasCycle())
    }

    @Test("Self-loops are rejected")
    func selfLoop() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let a = Fixtures.item(&gen, "a")
        graph.insert(a)
        #expect(throws: GraphError.selfLoop(a.id)) {
            try graph.addEdge(Fixtures.confirmedEdge(&gen, from: a.id, to: a.id, kind: .blocks))
        }
    }

    /// An unconfirmed edge may be confirmed later. A graph that becomes cyclic
    /// on confirmation is not a graph we want to be able to build.
    @Test("Unconfirmed edges still count for cycle detection")
    func unconfirmedCountsForCycles() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let a = Fixtures.item(&gen, "a"), b = Fixtures.item(&gen, "b")
        graph.insert(a); graph.insert(b)
        try graph.addEdge(Fixtures.aiEdge(&gen, from: a.id, to: b.id, kind: .blocks))

        #expect(throws: GraphError.self) {
            try graph.addEdge(Fixtures.confirmedEdge(&gen, from: b.id, to: a.id, kind: .blocks))
        }
    }

    @Test("Cycle rejection ignores confidence entirely")
    func confidenceCannotOverride() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let a = Fixtures.item(&gen, "a"), b = Fixtures.item(&gen, "b")
        graph.insert(a); graph.insert(b)
        try graph.addEdge(Fixtures.confirmedEdge(&gen, from: a.id, to: b.id, kind: .blocks))

        let certain = Edge(
            id: gen.next(), from: b.id, to: a.id, kind: .blocks,
            confidence: 1.0, source: .t2Model, confirmed: false)
        #expect(throws: GraphError.self) { try graph.addEdge(certain) }
    }

    @Test("`relates` and `duplicate` are symmetric and may cycle freely")
    func symmetricKindsAreUnconstrained() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let a = Fixtures.item(&gen, "a"), b = Fixtures.item(&gen, "b")
        graph.insert(a); graph.insert(b)
        try graph.addEdge(Fixtures.confirmedEdge(&gen, from: a.id, to: b.id, kind: .relates))
        try graph.addEdge(Fixtures.confirmedEdge(&gen, from: b.id, to: a.id, kind: .relates))
        #expect(!graph.hasCycle())
    }
}

@Suite("Graph — reachability")
struct ReachabilityTests {

    @Test("Transitive unblocking follows chains")
    func chain() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let items = (0..<4).map { Fixtures.item(&gen, "n\($0)") }
        for item in items { graph.insert(item) }
        for i in 0..<3 {
            try graph.addEdge(
                Fixtures.confirmedEdge(
                    &gen, from: items[i].id,
                    to: items[i + 1].id, kind: .blocks))
        }
        let reached = graph.transitivelyUnblocked(
            from: items[0].id, confirmedOnly: true,
            maxDepth: 5)
        #expect(reached.count == 3)
        #expect(!reached.contains(items[0].id), "must exclude itself")
    }

    @Test("Depth cap bounds reachability")
    func depthCap() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let items = (0..<10).map { Fixtures.item(&gen, "n\($0)") }
        for item in items { graph.insert(item) }
        for i in 0..<9 {
            try graph.addEdge(
                Fixtures.confirmedEdge(
                    &gen, from: items[i].id,
                    to: items[i + 1].id, kind: .blocks))
        }
        #expect(
            graph.transitivelyUnblocked(
                from: items[0].id, confirmedOnly: true,
                maxDepth: 3
            ).count == 3)
        #expect(
            graph.transitivelyUnblocked(
                from: items[0].id, confirmedOnly: true,
                maxDepth: 5
            ).count == 5)
    }

    @Test("Done items are not counted as unblocked")
    func doneExcluded() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let a = Fixtures.item(&gen, "a")
        let doneItem = Fixtures.item(&gen, "done", status: .done)
        let openItem = Fixtures.item(&gen, "open")
        for item in [a, doneItem, openItem] { graph.insert(item) }
        try graph.addEdge(Fixtures.confirmedEdge(&gen, from: a.id, to: doneItem.id, kind: .blocks))
        try graph.addEdge(Fixtures.confirmedEdge(&gen, from: a.id, to: openItem.id, kind: .blocks))

        let reached = graph.transitivelyUnblocked(from: a.id, confirmedOnly: true, maxDepth: 5)
        #expect(reached == [openItem.id])
    }

    /// With alpha = 0 (the default), AI suggestions contribute nothing to a
    /// score until a human confirms them.
    @Test("Unconfirmed edges are excluded when confirmedOnly")
    func unconfirmedExcluded() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let a = Fixtures.item(&gen, "a"), b = Fixtures.item(&gen, "b"), c = Fixtures.item(&gen, "c")
        for item in [a, b, c] { graph.insert(item) }
        try graph.addEdge(Fixtures.confirmedEdge(&gen, from: a.id, to: b.id, kind: .blocks))
        try graph.addEdge(Fixtures.aiEdge(&gen, from: a.id, to: c.id, kind: .blocks))

        #expect(graph.transitivelyUnblocked(from: a.id, confirmedOnly: true, maxDepth: 5) == [b.id])
        #expect(
            graph.transitivelyUnblocked(from: a.id, confirmedOnly: false, maxDepth: 5).count == 2)
    }

    @Test("Blockers list only open items")
    func blockers() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let target = Fixtures.item(&gen, "target")
        let openBlocker = Fixtures.item(&gen, "open-blocker")
        let doneBlocker = Fixtures.item(&gen, "done-blocker", status: .done)
        for item in [target, openBlocker, doneBlocker] { graph.insert(item) }
        try graph.addEdge(
            Fixtures.confirmedEdge(&gen, from: openBlocker.id, to: target.id, kind: .blocks))
        try graph.addEdge(
            Fixtures.confirmedEdge(&gen, from: doneBlocker.id, to: target.id, kind: .blocks))

        #expect(graph.blockers(of: target.id) == [openBlocker.id])
    }
}

@Suite("Graph — invariants enforced at construction")
struct ConstructionInvariantTests {
    @Test("`serves` must point at a goal, never an item")
    func servesTargetsGoal() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let a = Fixtures.item(&gen, "a"), b = Fixtures.item(&gen, "b")
        graph.insert(a); graph.insert(b)
        #expect(throws: GraphError.self) {
            try graph.addEdge(Fixtures.confirmedEdge(&gen, from: a.id, to: b.id, kind: .serves))
        }
    }

    @Test("Edges to unknown items are rejected")
    func unknownItem() throws {
        var gen = Fixtures.generator()
        var graph = BrainGraph()
        let a = Fixtures.item(&gen, "a")
        graph.insert(a)
        let ghost = gen.next()
        #expect(throws: GraphError.unknownItem(ghost)) {
            try graph.addEdge(Fixtures.confirmedEdge(&gen, from: a.id, to: ghost, kind: .blocks))
        }
    }
}
