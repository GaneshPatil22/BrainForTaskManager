import Foundation

/// Explanations are templates filled from graph facts. Nothing is generated.
///
/// If a model ever rephrases one of these, `claimCheck` (guard 12) verifies that
/// the rephrasing contains no claim absent from the facts, and discards it if it
/// does. The template is the fallback and the source of truth.
public enum Explain {

    public static func reason(
        for item: Item, breakdown: ScoreBreakdown,
        now: Date, calendar: Calendar
    ) -> String {
        var parts: [String] = []

        // Only confirmed counts are shown. Telling a user something "unblocks 3
        // tasks" on the strength of unconfirmed AI guesses would be a lie.
        if breakdown.unblockedConfirmed > 0 {
            parts.append(
                "Unblocks \(breakdown.unblockedConfirmed) "
                    + (breakdown.unblockedConfirmed == 1 ? "task" : "tasks"))
        }
        if breakdown.goalsConfirmed > 0 {
            parts.append(
                "serves \(breakdown.goalsConfirmed) "
                    + (breakdown.goalsConfirmed == 1 ? "goal" : "goals"))
        }
        if breakdown.effort != .unknown {
            parts.append(effortPhrase(breakdown.effort))
        }
        if let clause = dueClause(item.dueAt.value, now: now, calendar: calendar) {
            parts.append(clause)
        }
        // Everything was zero or unknown: say that, rather than inventing a reason.
        if parts.isEmpty { return "No links or deadline yet" }
        return parts.joined(separator: " · ")
    }

    static func effortPhrase(_ bucket: EffortBucket) -> String {
        switch bucket {
        case .tiny: "about 5 min"
        case .small: "about 20 min"
        case .medium: "about an hour"
        case .large: "about half a day"
        case .xlarge: "multi-day"
        case .unknown: "effort unknown"
        }
    }

    static func dueClause(_ dueAt: Date?, now: Date, calendar: Calendar) -> String? {
        guard let dueAt else { return nil }
        let days =
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: now),
                to: calendar.startOfDay(for: dueAt)
            ).day ?? 0
        switch days {
        case ..<0: return "overdue by \(-days) \(-days == 1 ? "day" : "days")"
        case 0: return "due today"
        case 1: return "due tomorrow"
        default: return "due in \(days) days"
        }
    }
}
