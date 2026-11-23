import ArgumentParser
import BrainCore
import Foundation

/// Turns plain-text scenario sketches into scenario JSON.
///
/// You write the same `.brain` format used for dogfooding, with a
/// `scenario: <title>` line separating one from the next. Nobody should be
/// hand-writing JSON to describe four tasks.
///
///     scenario: Two deadlines clash
///     Ship the hotfix        | medium | due aaj
///     Book flights for Diwali| small  | due in 2 days
///     Call Amma              | tiny
///
///     scenario: The blocked hub
///     goal: Ship v1
///     Get credentials from IT | tiny
///     Migrate the database    | large | after Get credentials from IT | goal Ship v1
struct NewScenarioCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-scenarios",
        abstract: "Turn plain-text scenario sketches into scenario JSON files.")

    @Argument(help: "Text file containing one or more `scenario:` blocks.")
    var file: String

    @Option(name: .long, help: "Scenario directory.")
    var dir: String = "datasets/scenarios"

    @Flag(name: .long, help: "Parse and report, but write nothing.")
    var dryRun = false

    /// Every scenario shares one fixed "now" so they stay comparable and
    /// relative dates ("kal") mean the same thing in all of them.
    static let canonicalNow = "2026-11-23T09:00:00+05:30"

    func run() throws {
        let zone = TimeZone(identifier: "Asia/Kolkata")!
        guard let now = ISO8601DateFormatter().date(from: Self.canonicalNow) else {
            throw ValidationError("bad canonical now")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let raw = try String(contentsOfFile: file, encoding: .utf8)
        let blocks = Self.splitIntoBlocks(raw)
        guard !blocks.isEmpty else {
            throw ValidationError(
                """
                No `scenario:` blocks found in \(file).
                Each scenario starts with a line like:  scenario: Two deadlines clash
                """)
        }

        let directory = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var nextNumber = try Self.nextAvailableNumber(in: directory)
        var written = 0

        for block in blocks {
            let parsed = DumpFormat.parse(block.body, now: now, timeZone: zone)
            for issue in parsed.issues {
                print("  \(block.title): line \(issue.line): \(issue.message)")
            }
            let openCount = parsed.itemOrder.compactMap { parsed.graph.items[$0] }
                .filter { $0.status.isOpen }.count
            guard openCount >= 2 else {
                print("  SKIP \"\(block.title)\" — needs at least 2 open items, found \(openCount)")
                continue
            }

            let id = String(format: "scenario-%03d", nextNumber)
            let scenario = Self.build(
                id: id, title: block.title, parsed: parsed,
                now: now, calendar: calendar)
            let path = directory.appendingPathComponent("\(id).json")
            if dryRun {
                print("  would write \(id).json — \"\(block.title)\" (\(openCount) open items)")
            } else {
                try ScenarioLoader.save(scenario, to: path)
                print("  wrote \(id).json — \"\(block.title)\" (\(openCount) open items)")
            }
            nextNumber += 1
            written += 1
        }

        print("\n\(dryRun ? "Would add" : "Added") \(written) scenario\(written == 1 ? "" : "s").")
        if !dryRun && written > 0 { print("Run `make rank` to rank them.") }
    }

    // MARK: - Parsing

    struct Block { let title: String; let body: String }

    static func splitIntoBlocks(_ raw: String) -> [Block] {
        var blocks: [Block] = []
        var title: String?
        var body: [String] = []

        func flush() {
            if let title, !body.isEmpty {
                blocks.append(Block(title: title, body: body.joined(separator: "\n")))
            }
            body = []
        }
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("scenario:") {
                flush()
                title = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else {
                body.append(line)
            }
        }
        flush()
        return blocks
    }

    // MARK: - Conversion

    static func build(
        id: String, title: String, parsed: DumpFormat.Result,
        now: Date, calendar: Calendar
    ) -> ScenarioFile {
        // Short, readable keys: i1..iN, g1..gN.
        var keyFor: [ULID: String] = [:]
        for (index, goalId) in parsed.goalOrder.enumerated() { keyFor[goalId] = "g\(index + 1)" }
        for (index, itemId) in parsed.itemOrder.enumerated() { keyFor[itemId] = "i\(index + 1)" }

        let goals = parsed.goalOrder.compactMap { goalId -> ScenarioFile.GoalSpec? in
            guard let goal = parsed.graph.goals[goalId], let key = keyFor[goalId] else {
                return nil
            }
            return ScenarioFile.GoalSpec(id: key, title: goal.title)
        }
        let items = parsed.itemOrder.compactMap { itemId -> ScenarioFile.ItemSpec? in
            guard let item = parsed.graph.items[itemId], let key = keyFor[itemId] else {
                return nil
            }
            // Absolute dates become day offsets, so a scenario stays meaningful
            // whatever date it is read on.
            var offset: String?
            if let due = item.dueAt.value {
                let days =
                    calendar.dateComponents(
                        [.day], from: calendar.startOfDay(for: now),
                        to: calendar.startOfDay(for: due)
                    ).day ?? 0
                offset = days >= 0 ? "+\(days)" : "\(days)"
            }
            return ScenarioFile.ItemSpec(
                id: key, title: item.title, type: (item.type.value ?? .task).rawValue,
                effort: item.effortBucket.rawValue, dueAt: offset, status: item.status.rawValue)
        }
        let edges = parsed.graph.edges.values
            .compactMap { edge -> ScenarioFile.EdgeSpec? in
                guard let from = keyFor[edge.from], let to = keyFor[edge.to] else { return nil }
                return ScenarioFile.EdgeSpec(
                    from: from, to: to, kind: edge.kind.rawValue,
                    confirmed: edge.confirmed)
            }
            .sorted { ($0.from, $0.to) < ($1.from, $1.to) }

        return ScenarioFile(
            id: id, description: title,
            tests: "authored by Ganesh",
            now: canonicalNow, userTz: "Asia/Kolkata",
            goals: goals, items: items, edges: edges, expected: nil)
    }

    static func nextAvailableNumber(in directory: URL) throws -> Int {
        let existing =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil))
            ?? []
        let numbers =
            existing
            .filter { $0.pathExtension == "json" }
            .compactMap {
                Int(
                    $0.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "scenario-", with: ""))
            }
        return (numbers.max() ?? 0) + 1
    }
}
