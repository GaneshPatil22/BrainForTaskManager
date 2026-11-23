import BrainCore
import Foundation

/// A deliberately tiny, human-writable format so Ganesh can use Brain from day
/// one, before any classification exists. Every field is explicit — this file
/// does no inference, it only parses what was written.
///
///     # lines starting with # are comments
///     goal: Ship Brain v1
///
///     Finalize API spec   | medium | due kal        | goal Ship Brain v1
///     Call plumber        | tiny
///     Deploy to prod      | small  | after Finalize API spec
///     Write changelog     | done
///
/// Modifiers, in any order after the title:
///   `tiny|small|medium|large|xlarge`   effort
///   `due <text>`                       parsed by the real T0 DateParser
///   `goal <title>`                     serves that goal
///   `after <title>`                    that item blocks this one
///   `done` | `dropped`                 status
public enum DumpFormat {

    public struct ParseIssue: Sendable {
        public let line: Int
        public let message: String
    }

    public struct Result: Sendable {
        public let graph: BrainGraph
        public let issues: [ParseIssue]
        /// Items and goals in the order they appeared in the file. Dictionaries
        /// lose that, and anything regenerating the file needs it back.
        public let itemOrder: [ULID]
        public let goalOrder: [ULID]
    }

    /// Edges are wired in a second pass so `after` may name an item defined
    /// further down the file.
    private struct PendingEdge {
        let targetTitle: String
        let itemId: ULID
        let kind: EdgeKind
        let line: Int
    }

    public static func parse(
        _ contents: String, now: Date, timeZone: TimeZone,
        seed: UInt64 = 42
    ) -> Result {
        var generator = ULIDGenerator(
            seed: seed,
            clock: {
                UInt64(now.timeIntervalSince1970 * 1000)
            })
        let dateParser = DateParser(timeZone: timeZone)
        let effortParser = EffortParser()
        let dependencyParser = DependencyParser(timeZone: timeZone)
        var graph = BrainGraph()
        var issues: [ParseIssue] = []

        // Titles are the only handle a human has, so they are the lookup key.
        var goalIdsByTitle: [String: ULID] = [:]
        var itemIdsByTitle: [String: ULID] = [:]
        var pending: [PendingEdge] = []
        var itemOrder: [ULID] = []
        /// (line, item, title) for items that declared no `after`, so their
        /// titles can be scanned for blocking phrases once all titles are known.
        var inferredCandidates: [(Int, ULID, String)] = []
        var goalOrder: [ULID] = []

        for (index, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.lowercased().hasPrefix("goal:") {
                let title = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else {
                    issues.append(.init(line: lineNumber, message: "goal with no title"))
                    continue
                }
                let goal = Goal(id: generator.next(), title: title, createdAt: now)
                graph.insert(goal)
                goalIdsByTitle[title.lowercased()] = goal.id
                goalOrder.append(goal.id)
                continue
            }

            let fields = line.components(separatedBy: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let title = fields[0]
            guard !title.isEmpty else {
                issues.append(.init(line: lineNumber, message: "item with no title"))
                continue
            }

            var effort: EffortBucket = .unknown
            var category: Classified<TaskCategory>?
            var status: ItemStatus = .open
            var due: Classified<Date> = .unknown()
            // (kind, target title) collected now, resolved to ids after the item exists.
            var edgeRequests: [(EdgeKind, String)] = []

            for modifier in fields.dropFirst() where !modifier.isEmpty {
                let lower = modifier.lowercased()
                if let bucket = EffortBucket(rawValue: lower), bucket != .unknown {
                    effort = bucket
                } else if lower == "done" {
                    status = .done
                } else if lower == "dropped" {
                    status = .dropped
                } else if lower.hasPrefix("due ") {
                    let text = String(modifier.dropFirst(4))
                    if let parsed = dateParser.parse(text, now: now) {
                        due = Classified(
                            parsed.date, confidence: parsed.confidence,
                            tier: .t0, evidence: parsed.span)
                    } else {
                        issues.append(
                            .init(
                                line: lineNumber,
                                message: "could not parse date: \"\(text)\""))
                    }
                } else if lower.hasPrefix("category ") {
                    let name = String(modifier.dropFirst(9))
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: " ", with: "")
                    if let parsed = TaskCategory.allCases.first(where: {
                        $0.rawValue.lowercased() == name.lowercased()
                    }) {
                        category = Classified(parsed, confidence: 1, tier: .user)
                    } else {
                        issues.append(
                            .init(
                                line: lineNumber,
                                message: "unknown category \"\(name)\" — one of: "
                                    + TaskCategory.allCases.map(\.rawValue).joined(separator: ", "))
                        )
                    }
                } else if lower.hasPrefix("goal ") {
                    edgeRequests.append((.serves, String(modifier.dropFirst(5))))
                } else if lower.hasPrefix("after ") {
                    edgeRequests.append((.blocks, String(modifier.dropFirst(6))))
                } else {
                    issues.append(
                        .init(
                            line: lineNumber,
                            message: "unknown modifier: \"\(modifier)\""))
                }
            }

            // T0 fallback: if effort was not declared, read it from the title.
            // "If the user said how long, read it" (docs/09-tiering.md).
            var effortConfidence = effort == .unknown ? 0.0 : 1.0
            var effortTier: Tier = .user
            if effort == .unknown, let parsed = effortParser.parse(title) {
                effort = parsed.bucket
                effortConfidence = parsed.confidence
                effortTier = .t0
            }

            let item = Item(
                id: generator.next(), title: title,
                type: Classified(.task, confidence: 1.0, tier: .user),
                status: status,
                effort: Classified(effort, confidence: effortConfidence, tier: effortTier),
                dueAt: due, category: category, createdAt: now)
            graph.insert(item)
            itemOrder.append(item.id)
            if itemIdsByTitle.updateValue(item.id, forKey: title.lowercased()) != nil {
                issues.append(
                    .init(
                        line: lineNumber,
                        message: "duplicate title \"\(title)\" — later one wins for `after`"))
            }
            if !edgeRequests.contains(where: { $0.0 == .blocks }) {
                inferredCandidates.append((lineNumber, item.id, title))
            }
            for (kind, target) in edgeRequests {
                pending.append(
                    PendingEdge(
                        targetTitle: target, itemId: item.id,
                        kind: kind, line: lineNumber))
            }
        }

        // T0 fallback: read blocking phrases out of titles that declared none,
        // then resolve each referent against the other items. An unmatched
        // referent produces no edge at all — precision over recall.
        let allTitles = itemIdsByTitle.map { (id: $0.value, title: $0.key) }
        for (lineNumber, itemId, title) in inferredCandidates {
            guard !pending.contains(where: { $0.itemId == itemId && $0.kind == .blocks }) else {
                continue
            }
            // Exclude the item itself *before* matching. Its own title
            // contains the referent, so it can win the tie and then be
            // discarded — losing the real match along with it.
            let others = allTitles.filter { $0.id != itemId }
            for reference in dependencyParser.parse(title, now: now) {
                guard let match = TitleMatcher.bestMatch(reference.targetText, in: others)
                else { continue }
                do {
                    try graph.addEdge(
                        Edge(
                            id: generator.next(), from: match.id, to: itemId, kind: .blocks,
                            confidence: reference.confidence * match.score,
                            // Unconfirmed: the user wrote the phrase, but the
                            // *parse* may be wrong, and invariant 3 reserves
                            // `confirmed` for a human (docs/01-domain.md).
                            // Blocking still applies structurally — the item is
                            // correctly excluded from `next`. Only the leverage
                            // credit waits for a confirming tap.
                            source: .t0Rule, confirmed: false))
                } catch {
                    issues.append(
                        .init(
                            line: lineNumber,
                            message: "inferred dependency on \"\(reference.targetText)\" "
                                + "would create a cycle — dropped"))
                }
            }
        }

        // Pass two: wire edges now that every title is known.
        for edge in pending {
            let key = edge.targetTitle.lowercased()
            do {
                switch edge.kind {
                case .serves:
                    guard let goalId = goalIdsByTitle[key] else {
                        issues.append(
                            .init(
                                line: edge.line,
                                message: "unknown goal: \"\(edge.targetTitle)\""))
                        continue
                    }
                    try graph.addEdge(
                        Edge(
                            id: generator.next(), from: edge.itemId, to: goalId,
                            kind: .serves, source: .user, confirmed: true))
                case .blocks:
                    // `after X` means X blocks this item, so the edge runs X → item.
                    guard let blockerId = itemIdsByTitle[key] else {
                        issues.append(
                            .init(
                                line: edge.line,
                                message: "unknown item: \"\(edge.targetTitle)\""))
                        continue
                    }
                    try graph.addEdge(
                        Edge(
                            id: generator.next(), from: blockerId, to: edge.itemId,
                            kind: .blocks, source: .user, confirmed: true))
                case .relates, .duplicate:
                    continue
                }
            } catch let error as GraphError {
                // Report titles, not ULIDs — the raw ids mean nothing to a reader.
                let message: String
                switch error {
                case .wouldCreateCycle:
                    message =
                        "\"\(edge.targetTitle)\" must finish first, but that would "
                        + "create a circular dependency — edge dropped"
                case .selfLoop:
                    message = "a task cannot depend on itself"
                default:
                    message = "\(error)"
                }
                issues.append(.init(line: edge.line, message: message))
            } catch {
                issues.append(.init(line: edge.line, message: "\(error)"))
            }
        }
        return Result(
            graph: graph, issues: issues,
            itemOrder: itemOrder, goalOrder: goalOrder)
    }
}
