import ArgumentParser
import BrainCore
import Foundation

/// On-disk scenario format (`docs/03-dataset-schema.md`).
///
/// Ids are short, human-authorable keys ("i1", "g1"), mapped to stable ULIDs by
/// `ULID.derived(from:)`. Keeping the files readable matters more here than
/// storing real ULIDs, and the domain stays strict either way.
struct ScenarioFile: Codable {
    struct ItemSpec: Codable {
        let id: String
        let title: String
        let type: String
        let effort: String
        /// Either nil, or a day offset from `now` such as "+3" or "-2".
        let dueAt: String?
        let status: String
    }
    struct GoalSpec: Codable { let id: String; let title: String }
    struct EdgeSpec: Codable {
        let from: String, to: String, kind: String
        let confirmed: Bool
    }
    struct Expected: Codable {
        /// The human's top three, best first.
        let rankingTop3: [String]
        let rankedBy: String
        let rankedAt: String
        let note: String?
    }

    let id: String
    let description: String
    /// What dimension this scenario probes. **Never shown during ranking** —
    /// it would prime the answer.
    let tests: String
    let now: String
    let userTz: String
    let goals: [GoalSpec]
    let items: [ItemSpec]
    let edges: [EdgeSpec]
    var expected: Expected?

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    static let encoder: JSONEncoder = {
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
    static func derived(from key: String) -> ULID {
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

enum ScenarioLoader {
    struct Loaded {
        let file: ScenarioFile
        let path: URL
        let graph: BrainGraph
        let now: Date
        let calendar: Calendar
        /// Short key → ULID, so output can be written back in readable form.
        let idsByKey: [String: ULID]
        let keysById: [ULID: String]
    }

    static func load(_ path: URL) throws -> Loaded {
        let data = try Data(contentsOf: path)
        let file = try ScenarioFile.decoder.decode(ScenarioFile.self, from: data)

        guard let now = ISO8601DateFormatter().date(from: file.now) else {
            throw ValidationError("scenario \(file.id): bad `now`: \(file.now)")
        }
        guard let zone = TimeZone(identifier: file.userTz) else {
            throw ValidationError("scenario \(file.id): bad timezone: \(file.userTz)")
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
                throw ValidationError("scenario \(file.id): bad edge \(spec.from)→\(spec.to)")
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

    static func loadAll(in directory: URL) throws -> [Loaded] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map(load)
    }

    static func save(_ file: ScenarioFile, to path: URL) throws {
        var data = try ScenarioFile.encoder.encode(file)
        data.append(0x0A)
        try data.write(to: path)
    }
}
