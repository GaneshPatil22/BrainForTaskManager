import BrainCore
import Foundation

/// Raised when a dataset file on disk is malformed. Kept here rather than
/// reusing ArgumentParser's error so this target stays free of CLI dependencies
/// and can be used from the eval runner as well.
public struct DatasetError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// On-disk scenario format (`docs/03-dataset-schema.md`).
///
/// Ids are short, human-authorable keys ("i1", "g1"), mapped to stable ULIDs by
/// `ULID.derived(from:)`. Keeping the files readable matters more here than
/// storing real ULIDs, and the domain stays strict either way.
public struct ScenarioFile: Codable {
    public struct ItemSpec: Codable {
        public let id: String
        public let title: String
        public let type: String
        public let effort: String
        /// Either nil, or a day offset from `now` such as "+3" or "-2".
        public let dueAt: String?
        public let status: String

        public init(
            id: String, title: String, type: String, effort: String,
            dueAt: String?, status: String
        ) {
            self.id = id
            self.title = title
            self.type = type
            self.effort = effort
            self.dueAt = dueAt
            self.status = status
        }
    }
    public struct GoalSpec: Codable {
        public let id: String
        public let title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }
    public struct EdgeSpec: Codable {
        public let from: String, to: String, kind: String
        public let confirmed: Bool

        public init(from: String, to: String, kind: String, confirmed: Bool) {
            self.from = from
            self.to = to
            self.kind = kind
            self.confirmed = confirmed
        }
    }
    public struct Expected: Codable {
        /// The human's top three, best first.
        public let rankingTop3: [String]
        public let rankedBy: String
        public let rankedAt: String
        public let note: String?

        public init(rankingTop3: [String], rankedBy: String, rankedAt: String, note: String?) {
            self.rankingTop3 = rankingTop3
            self.rankedBy = rankedBy
            self.rankedAt = rankedAt
            self.note = note
        }
    }

    public let id: String
    /// Assigned by `DatasetSplit.forScenario` from the id — never by hand.
    public var split: String?
    public let description: String
    /// What dimension this scenario probes. **Never shown during ranking** —
    /// it would prime the answer.
    public let tests: String
    public let now: String
    public let userTz: String
    public let goals: [GoalSpec]
    public let items: [ItemSpec]
    public let edges: [EdgeSpec]
    public var expected: Expected?
    /// A second, independent ranking of the same scenario on a different day.
    /// Used to measure how much the same human disagrees with themselves, which
    /// is the ceiling on any model's achievable agreement (`docs/12-backlog.md`
    /// B-03a). Without this number, every ranking target is a guess.
    public var secondPass: Expected?

    public init(
        id: String, split: String?, description: String, tests: String,
        now: String, userTz: String, goals: [GoalSpec], items: [ItemSpec],
        edges: [EdgeSpec], expected: Expected?, secondPass: Expected? = nil
    ) {
        self.id = id
        self.split = split
        self.description = description
        self.tests = tests
        self.now = now
        self.userTz = userTz
        self.goals = goals
        self.items = items
        self.edges = edges
        self.expected = expected
        self.secondPass = secondPass
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

extension ULID {
    /// Stable ULID derived from a short key. FNV-1a is used rather than a
    /// cryptographic hash because this only needs to be deterministic and
    /// well-spread, and it keeps BrainCLI free of a crypto dependency.
    public static func derived(from key: String) -> ULID {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(key.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        var rng = SplitMix64(seed: hash)
        let a = rng.next(), b = rng.next()
        var bytes: [UInt8] = []
        for i in 0..<8 { bytes.append(UInt8((a >> (8 * UInt64(i))) & 0xFF)) }
        for i in 0..<2 { bytes.append(UInt8((b >> (8 * UInt64(i))) & 0xFF)) }
        return ULID(timestampMilliseconds: hash & 0xFFFF_FFFF_FFFF, randomness: bytes)
    }
}

public enum ScenarioLoader {
    public struct Loaded {
        public let file: ScenarioFile
        public let path: URL
        public let graph: BrainGraph
        public let now: Date
        public let calendar: Calendar
        /// Short key → ULID, so output can be written back in readable form.
        public let idsByKey: [String: ULID]
        public let keysById: [ULID: String]
    }

    public static func load(_ path: URL) throws -> Loaded {
        let data = try Data(contentsOf: path)
        let file = try ScenarioFile.decoder.decode(ScenarioFile.self, from: data)

        guard let now = ISO8601DateFormatter().date(from: file.now) else {
            throw DatasetError("scenario \(file.id): bad `now`: \(file.now)")
        }
        guard let zone = TimeZone(identifier: file.userTz) else {
            throw DatasetError("scenario \(file.id): bad timezone: \(file.userTz)")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        var graph = BrainGraph()
        var idsByKey: [String: ULID] = [:]
        var keysById: [ULID: String] = [:]
        var generator = ULIDGenerator(seed: 7, clock: { UInt64(now.timeIntervalSince1970 * 1000) })

        for goal in file.goals {
            let id = ULID.derived(from: "\(file.id)/\(goal.id)")
            graph.insert(Goal(id: id, title: goal.title, createdAt: now))
            idsByKey[goal.id] = id
            keysById[id] = goal.id
        }
        for spec in file.items {
            let id = ULID.derived(from: "\(file.id)/\(spec.id)")
            // Offsets resolve to end of day, matching DateParser's convention.
            var due: Classified<Date> = .unknown()
            if let offset = spec.dueAt.flatMap(Int.init),
                let day = calendar.date(byAdding: .day, value: offset, to: now),
                let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: day)
            {
                due = Classified(endOfDay, confidence: 1, tier: .user)
            }
            graph.insert(
                Item(
                    id: id, title: spec.title,
                    type: Classified(
                        ItemType(rawValue: spec.type) ?? .task,
                        confidence: 1, tier: .user),
                    status: ItemStatus(rawValue: spec.status) ?? .open,
                    effort: Classified(
                        EffortBucket(rawValue: spec.effort) ?? .unknown,
                        confidence: 1, tier: .user),
                    dueAt: due, createdAt: now))
            idsByKey[spec.id] = id
            keysById[id] = spec.id
        }
        for spec in file.edges {
            guard let from = idsByKey[spec.from], let to = idsByKey[spec.to],
                let kind = EdgeKind(rawValue: spec.kind)
            else {
                throw DatasetError("scenario \(file.id): bad edge \(spec.from)→\(spec.to)")
            }
            try graph.addEdge(
                Edge(
                    id: generator.next(), from: from, to: to, kind: kind,
                    confidence: spec.confirmed ? 1.0 : 0.7,
                    source: spec.confirmed ? .user : .t2Model,
                    confirmed: spec.confirmed))
        }
        return Loaded(
            file: file, path: path, graph: graph, now: now, calendar: calendar,
            idsByKey: idsByKey, keysById: keysById)
    }

    public static func loadAll(in directory: URL) throws -> [Loaded] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map(load)
    }

    public static func save(_ file: ScenarioFile, to path: URL) throws {
        var data = try ScenarioFile.encoder.encode(file)
        data.append(0x0A)
        try data.write(to: path)
    }
}
