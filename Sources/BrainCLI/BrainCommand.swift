import ArgumentParser
import BrainCore
import Foundation

@main
struct BrainCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brain",
        abstract: "Brain v1 Core — everything here is computed deterministically.",
        subcommands: [NextCommand.self, RankCommand.self, IngestCommand.self],
        defaultSubcommand: NextCommand.self)
}

/// Dogfood: read a plain-text dump, print what to do next. No AI involved.
struct NextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next",
        abstract: "Read a dump file and print next / ranked / quick wins / blocked.",
        discussion: """
            Format:
              goal: Ship Brain v1
              Finalize API spec | medium | due kal | goal Ship Brain v1
              Call plumber      | tiny
              Deploy to prod    | small | after Finalize API spec
            """)

    @Argument(help: "Path to the dump file.")
    var file: String

    @Option(name: .long, help: "IANA timezone for date parsing.")
    var timezone: String = "Asia/Kolkata"

    @Option(name: .long, help: "Override 'now' as ISO-8601, for reproducible output.")
    var now: String?

    @Option(name: .long, help: "Weight for unconfirmed edges (0...1).")
    var alpha: Double = 0.0

    @Flag(name: .long, help: "Print the full ranked list, not just the top 8.")
    var all = false

    func run() throws {
        guard let zone = TimeZone(identifier: timezone) else {
            throw ValidationError("Unknown timezone: \(timezone)")
        }
        let nowDate: Date
        if let now {
            guard let parsed = ISO8601DateFormatter().date(from: now) else {
                throw ValidationError("Could not parse --now as ISO-8601: \(now)")
            }
            nowDate = parsed
        } else {
            nowDate = Date()
        }

        let contents = try String(contentsOfFile: file, encoding: .utf8)
        let parsed = DumpFormat.parse(contents, now: nowDate, timeZone: zone)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let outputs = Brain.compute(
            graph: parsed.graph, now: nowDate, calendar: calendar,
            policy: EdgePolicy(alpha: alpha))

        Printer.render(outputs: outputs, issues: parsed.issues, showAll: all, timeZone: zone)
    }
}
