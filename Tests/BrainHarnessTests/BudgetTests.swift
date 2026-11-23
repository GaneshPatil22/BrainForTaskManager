import Foundation
import Testing

@testable import BrainHarness

/// Helper: a wall-clock instant in Pacific, which is the only zone the daily
/// counters care about.
private func pacific(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0)
    -> Date
{
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = ProviderDay.zone
    return calendar.date(
        from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite("ProviderDay")
struct ProviderDayTests {
    @Test("The day boundary is midnight Pacific, not local midnight")
    func pacificBoundary() {
        // 23:30 Pacific on the 24th is still the 24th; 00:30 is the 25th,
        // one hour later.
        #expect(ProviderDay.containing(pacific(2026, 11, 24, 23, 30)).key == "2026-11-24")
        #expect(ProviderDay.containing(pacific(2026, 11, 25, 0, 30)).key == "2026-11-25")
    }

    @Test("Asia/Kolkata midnight is mid-afternoon the previous Pacific day")
    func notLocalMidnight() {
        // Ganesh's midnight. Getting this wrong would reset the quota 13.5
        // hours early every day.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let istMidnight = calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 25, hour: 0, minute: 0))!
        #expect(ProviderDay.containing(istMidnight).key == "2026-11-24")
    }

    @Test("DST is handled by the zone, not a fixed offset")
    func acrossDST() {
        // US DST ended 2026-11-01. A fixed -08:00 would misplace dates before
        // it; a fixed -07:00 would misplace dates after.
        #expect(ProviderDay.containing(pacific(2026, 10, 15, 23, 30)).key == "2026-10-15")
        #expect(ProviderDay.containing(pacific(2026, 11, 15, 23, 30)).key == "2026-11-15")
    }
}

@Suite("Daily counters survive a restart")
struct BudgetPersistenceTests {
    /// The bug this whole change exists for: a server redeploys, the ledger is
    /// rebuilt, and the day's spend is forgotten.
    @Test("A new ledger sharing a store does not get a fresh daily allowance")
    func survivesRebuild() async throws {
        let store = InMemoryBudgetStore()
        let clock = pacific(2026, 11, 24, 10)
        let limits = ModelLimits(requestsPerMinute: nil, tokensPerMinute: nil, requestsPerDay: 3)

        let before = BudgetLedger(store: store, now: { clock })
        await before.setLimits(limits, for: "m")
        for _ in 0..<3 { try await before.consume(model: "m", estimatedTokens: 1) }

        // Redeploy.
        let after = BudgetLedger(store: store, now: { clock })
        await after.setLimits(limits, for: "m")
        await #expect(throws: BudgetRefusal.requestsPerDay(limit: 3)) {
            try await after.consume(model: "m", estimatedTokens: 1)
        }
        let usage = await after.usage(model: "m")
        #expect(usage.dayRequests == 3)
    }

    @Test("In-memory is still the default, so nothing else changes behaviour")
    func defaultIsInMemory() async throws {
        let ledger = BudgetLedger(now: { pacific(2026, 11, 24, 10) })
        await ledger.setLimits(
            ModelLimits(requestsPerMinute: nil, tokensPerMinute: nil, requestsPerDay: 1),
            for: "m")
        try await ledger.consume(model: "m", estimatedTokens: 1)
        await #expect(throws: BudgetRefusal.requestsPerDay(limit: 1)) {
            try await ledger.consume(model: "m", estimatedTokens: 1)
        }
    }
}

@Suite("The day rolls at the provider's boundary")
struct BudgetDayRollTests {
    /// The old code rolled 24h after the *first call*. A deployment whose
    /// first call landed at 23:00 would hold the previous day's count through
    /// most of the next day.
    @Test("Two hours later, across midnight, is a new day — not 24h later")
    func rollsOnBoundaryNotElapsedTime() async throws {
        let store = InMemoryBudgetStore()
        nonisolated(unsafe) var clock = pacific(2026, 11, 24, 23)
        let ledger = BudgetLedger(store: store, now: { clock })
        await ledger.setLimits(
            ModelLimits(requestsPerMinute: nil, tokensPerMinute: nil, requestsPerDay: 1),
            for: "m")

        try await ledger.consume(model: "m", estimatedTokens: 1)
        await #expect(throws: BudgetRefusal.requestsPerDay(limit: 1)) {
            try await ledger.consume(model: "m", estimatedTokens: 1)
        }

        clock = pacific(2026, 11, 25, 1)  // two hours later, new Pacific day
        try await ledger.consume(model: "m", estimatedTokens: 1)
    }

    @Test("Twenty-two hours later within the same Pacific day is still that day")
    func doesNotRollEarly() async throws {
        let store = InMemoryBudgetStore()
        nonisolated(unsafe) var clock = pacific(2026, 11, 24, 1)
        let ledger = BudgetLedger(store: store, now: { clock })
        await ledger.setLimits(
            ModelLimits(requestsPerMinute: nil, tokensPerMinute: nil, requestsPerDay: 1),
            for: "m")

        try await ledger.consume(model: "m", estimatedTokens: 1)
        clock = pacific(2026, 11, 24, 23)
        await #expect(throws: BudgetRefusal.requestsPerDay(limit: 1)) {
            try await ledger.consume(model: "m", estimatedTokens: 1)
        }
    }
}

/// A store that suspends inside `reserve`, which is what a Postgres round trip
/// does. Without it the concurrency test below passes trivially.
private actor SlowStore: BudgetStore {
    private let inner = InMemoryBudgetStore()

    func reserve(
        model: String, user: String?, day: ProviderDay,
        modelDailyLimit: Int?, userDailyLimit: Int?
    ) async -> BudgetReservation {
        for _ in 0..<8 { await Task.yield() }
        return await inner.reserve(
            model: model, user: user, day: day,
            modelDailyLimit: modelDailyLimit, userDailyLimit: userDailyLimit)
    }

    func dailyRequests(model: String, day: ProviderDay) async -> Int {
        await inner.dailyRequests(model: model, day: day)
    }
}

@Suite("Concurrency")
struct BudgetConcurrencyTests {
    /// **This test fails if the minute slot is appended after the await.**
    ///
    /// `consume` suspends at the daily reservation, and an actor is re-entrant
    /// at every suspension point. If the window were only updated afterwards,
    /// every one of these 40 callers would pass the RPM check before any of
    /// them recorded itself, and all 40 would be allowed through a limit of 5.
    @Test("Concurrent callers cannot exceed RPM across the suspension point")
    func rpmHoldsUnderConcurrency() async throws {
        let ledger = BudgetLedger(store: SlowStore(), now: { pacific(2026, 11, 24, 10) })
        await ledger.setLimits(
            ModelLimits(requestsPerMinute: 5, tokensPerMinute: nil, requestsPerDay: nil),
            for: "m")

        let allowed = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    do {
                        try await ledger.consume(model: "m", estimatedTokens: 1)
                        return true
                    } catch { return false }
                }
            }
            var total = 0
            for await ok in group where ok { total += 1 }
            return total
        }
        #expect(allowed == 5, "RPM 5 let \(allowed) requests through")
    }

    @Test("A refused day releases the minute slot it was holding")
    func refusalReleasesSlot() async throws {
        let ledger = BudgetLedger(store: SlowStore(), now: { pacific(2026, 11, 24, 10) })
        await ledger.setLimits(
            ModelLimits(requestsPerMinute: 10, tokensPerMinute: nil, requestsPerDay: 1),
            for: "m")

        try await ledger.consume(model: "m", estimatedTokens: 1)
        await #expect(throws: BudgetRefusal.requestsPerDay(limit: 1)) {
            try await ledger.consume(model: "m", estimatedTokens: 1)
        }
        // One succeeded, one was refused and gave its slot back: the minute
        // window must show 1, not 2, or a refused day would eat the RPM pool.
        let usage = await ledger.usage(model: "m")
        #expect(usage.minuteRequests == 1)
    }
}

@Suite("Per-user fair share")
struct FairShareTests {
    @Test("One user exhausting their share does not block another")
    func oneUserCannotStarveAnother() async throws {
        let ledger = BudgetLedger(now: { pacific(2026, 11, 24, 10) })
        await ledger.setLimits(
            ModelLimits(requestsPerMinute: nil, tokensPerMinute: nil, requestsPerDay: 100),
            for: "m")

        for _ in 0..<2 {
            try await ledger.consume(model: "m", estimatedTokens: 1, user: "a", userLimit: 2)
        }
        await #expect(throws: BudgetRefusal.userFairShare(limit: 2, user: "a")) {
            try await ledger.consume(model: "m", estimatedTokens: 1, user: "a", userLimit: 2)
        }
        // The whole point: b is still served.
        try await ledger.consume(model: "m", estimatedTokens: 1, user: "b", userLimit: 2)
    }
}
