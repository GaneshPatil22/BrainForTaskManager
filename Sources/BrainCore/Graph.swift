import Foundation

/// How unconfirmed edges are treated when scoring (`docs/02-scoring-spec.md`).
public struct EdgePolicy: Sendable, Hashable {
    /// Weight applied to items reachable *only* via unconfirmed edges.
    /// Default 0 — unconfirmed edges contribute nothing until a user confirms.
    /// Evaluated over {0, 0.25, 0.5} in B4.
    public var alpha: Double
    /// Transitive reachability is capped so one pathological chain cannot
    /// dominate, and so scoring stays bounded on adversarial graphs.
    public var maxDepth: Int

    public init(alpha: Double = 0.0, maxDepth: Int = 5) {
        self.alpha = min(max(alpha, 0), 1)
        self.maxDepth = max(maxDepth, 0)
    }

    public static let `default` = EdgePolicy()
}

public enum GraphError: Error, Equatable, CustomStringConvertible {
    case wouldCreateCycle(from: ULID, to: ULID)
    case selfLoop(ULID)
    case unknownItem(ULID)
    case unknownGoal(ULID)
    case servesMustTargetGoal(ULID)

    public var description: String {
        switch self {
        case .wouldCreateCycle(let f, let t): "edge \(f) blocks \(t) would create a cycle"
        case .selfLoop(let i): "item \(i) cannot link to itself"
        case .unknownItem(let i): "unknown item \(i)"
        case .unknownGoal(let g): "unknown goal \(g)"
        case .servesMustTargetGoal(let t): "`serves` must target a goal, got \(t)"
        }
    }
}

/// The graph of items, goals and edges. Pure value type, no I/O.
///
/// Hard invariant: the `blocks` subgraph is always a DAG. Enforced on insert,
/// deterministically, regardless of which tier proposed the edge, and with no
/// confidence threshold that can override it.
public struct BrainGraph: Sendable {
    public private(set) var items: [ULID: Item] = [:]
    public private(set) var goals: [ULID: Goal] = [:]
    public private(set) var edges: [ULID: Edge] = [:]

    /// Adjacency, maintained on mutation. `blocksOut[a]` = items a blocks.
    private var blocksOut: [ULID: Set<ULID>] = [:]
    private var blocksIn: [ULID: Set<ULID>] = [:]
    private var servesOut: [ULID: Set<ULID>] = [:]
    /// Edge ids keyed by (from, to, kind) so confirmation state is recoverable.
    private var confirmedPair: Set<Pair> = []

    private struct Pair: Hashable, Sendable {
        let from: ULID, to: ULID, kind: EdgeKind
    }

    public init() {}

    // MARK: - Mutation

    public mutating func insert(_ item: Item) { items[item.id] = item }
    public mutating func insert(_ goal: Goal) { goals[goal.id] = goal }

    /// Adds an edge, rejecting anything that would break an invariant.
    @discardableResult
    public mutating func addEdge(_ edge: Edge) throws -> Edge {
        guard edge.from != edge.to else { throw GraphError.selfLoop(edge.from) }
        guard items[edge.from] != nil else { throw GraphError.unknownItem(edge.from) }

        switch edge.kind {
        case .serves:
            guard goals[edge.to] != nil else { throw GraphError.servesMustTargetGoal(edge.to) }
        case .blocks, .relates, .duplicate:
            guard items[edge.to] != nil else { throw GraphError.unknownItem(edge.to) }
        }

        if edge.kind == .blocks, wouldCreateCycle(from: edge.from, to: edge.to) {
            throw GraphError.wouldCreateCycle(from: edge.from, to: edge.to)
        }

        edges[edge.id] = edge
        switch edge.kind {
        case .blocks:
            blocksOut[edge.from, default: []].insert(edge.to)
            blocksIn[edge.to, default: []].insert(edge.from)
        case .serves:
            servesOut[edge.from, default: []].insert(edge.to)
        case .relates, .duplicate:
            break  // symmetric, navigational, no scoring weight
        }
        if edge.confirmed {
            confirmedPair.insert(Pair(from: edge.from, to: edge.to, kind: edge.kind))
        }
        return edge
    }

    public mutating func removeEdge(id: ULID) {
        guard let edge = edges.removeValue(forKey: id) else { return }
        switch edge.kind {
        case .blocks:
            blocksOut[edge.from]?.remove(edge.to)
            blocksIn[edge.to]?.remove(edge.from)
        case .serves:
            servesOut[edge.from]?.remove(edge.to)
        case .relates, .duplicate:
            break
        }
        // Another edge may assert the same confirmed pair; only drop if none remains.
        let pair = Pair(from: edge.from, to: edge.to, kind: edge.kind)
        if !edges.values.contains(where: {
            $0.confirmed && $0.from == pair.from && $0.to == pair.to && $0.kind == pair.kind
        }) {
            confirmedPair.remove(pair)
        }
    }

    // MARK: - Cycle safety

    /// True if `to` can already reach `from` through `blocks` edges — in which
    /// case adding `from blocks to` would close a cycle.
    ///
    /// Considers *all* `blocks` edges regardless of confirmation: an unconfirmed
    /// edge may be confirmed later, and a graph that becomes cyclic on
    /// confirmation is not a graph we want to be able to build.
    public func wouldCreateCycle(from: ULID, to: ULID) -> Bool {
        if from == to { return true }
        var seen: Set<ULID> = [to]
        var stack = [to]
        while let node = stack.popLast() {
            for next in blocksOut[node] ?? [] {
                if next == from { return true }
                if seen.insert(next).inserted { stack.append(next) }
            }
        }
        return false
    }

    /// Verifies the DAG invariant over the whole graph. Used by property tests.
    public func hasCycle() -> Bool {
        var state: [ULID: Int] = [:]  // 0 unvisited, 1 in-stack, 2 done
        func visit(_ node: ULID) -> Bool {
            switch state[node] ?? 0 {
            case 1: return true
            case 2: return false
            default: break
            }
            state[node] = 1
            for next in (blocksOut[node] ?? []).sorted() where visit(next) { return true }
            state[node] = 2
            return false
        }
        for node in items.keys.sorted() where visit(node) { return true }
        return false
    }

    // MARK: - Reachability

    private func isConfirmed(_ from: ULID, _ to: ULID, _ kind: EdgeKind) -> Bool {
        confirmedPair.contains(Pair(from: from, to: to, kind: kind))
    }

    /// Distinct **open** items transitively unblocked by `id`, depth-capped.
    /// Excludes `id` itself.
    ///
    /// - Parameter confirmedOnly: when true, traverses confirmed edges only.
    public func transitivelyUnblocked(
        from id: ULID, confirmedOnly: Bool,
        maxDepth: Int
    ) -> Set<ULID> {
        var reached: Set<ULID> = []
        var seen: Set<ULID> = [id]
        var frontier: [ULID] = [id]
        var depth = 0

        while !frontier.isEmpty && depth < maxDepth {
            var next: [ULID] = []
            for node in frontier {
                for target in (blocksOut[node] ?? []).sorted() {
                    if confirmedOnly && !isConfirmed(node, target, .blocks) { continue }
                    guard seen.insert(target).inserted else { continue }
                    if items[target]?.status.isOpen == true { reached.insert(target) }
                    next.append(target)
                }
            }
            frontier = next
            depth += 1
        }
        return reached
    }

    /// Goals served by `id` itself or by anything it transitively unblocks.
    ///
    /// Only `active` goals count. Pass `on:` to also drop **lapsed** period
    /// goals — last month's goal should stop inflating today's scores
    /// (`GoalPeriod`, `docs/15-planner.md`). Omitting it keeps the original
    /// behaviour exactly, which is why it is defaulted: a goal with no period
    /// never lapses, so every existing dataset scores identically either way.
    public func goalsServed(
        by id: ULID, confirmedOnly: Bool, maxDepth: Int, on day: CalendarDay? = nil
    ) -> Set<ULID> {
        func counts(_ goalId: ULID) -> Bool {
            guard let goal = goals[goalId] else { return false }
            guard let day else { return goal.status == .active }
            return goal.counts(on: day)
        }
        var sources: Set<ULID> = [id]
        sources.formUnion(
            transitivelyUnblocked(
                from: id, confirmedOnly: confirmedOnly,
                maxDepth: maxDepth))
        var result: Set<ULID> = []
        for source in sources {
            for goal in servesOut[source] ?? [] {
                if confirmedOnly && !isConfirmed(source, goal, .serves) { continue }
                if counts(goal) { result.insert(goal) }
            }
            // A goal set directly on the item counts too.
            if let direct = items[source]?.goalId.value, counts(direct) {
                result.insert(direct)
            }
        }
        return result
    }

    /// Goals belonging to one month or quarter, oldest id first.
    public func goals(in period: GoalPeriod) -> [Goal] {
        goals.values.filter { $0.period == period }.sorted { $0.id < $1.id }
    }

    /// Month goals that roll up into `goalId`. Only the ones that legitimately
    /// can: a child naming a parent it does not fit inside is a bad write, and
    /// is left out rather than silently counted.
    public func children(of goalId: ULID) -> [Goal] {
        guard let parent = goals[goalId] else { return [] }
        return goals.values
            .filter { $0.parentId == goalId && $0.canRollUp(into: parent) }
            .sorted { $0.id < $1.id }
    }

    /// Open items that must finish before `id` can start.
    public func blockers(of id: ULID) -> [ULID] {
        (blocksIn[id] ?? []).filter { items[$0]?.status.isOpen == true }.sorted()
    }

    /// Items `id` directly blocks.
    public func directlyBlocks(_ id: ULID) -> [ULID] {
        (blocksOut[id] ?? []).sorted()
    }

    public var openItems: [Item] {
        items.values.filter { $0.status.isOpen }.sorted { $0.id < $1.id }
    }
}
