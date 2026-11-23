import BrainCore
import Foundation

/// Free-tier limits for one model, as published per project in AI Studio.
///
/// These are **configuration with a verification date**, not constants. Google
/// changed them unilaterally at least twice in 2026 (`docs/06-model-router.md`).
public struct ModelLimits: Sendable, Hashable {
    public let requestsPerMinute: Int?
    public let tokensPerMinute: Int?
    public let requestsPerDay: Int?

    public init(requestsPerMinute: Int?, tokensPerMinute: Int?, requestsPerDay: Int?) {
        self.requestsPerMinute = requestsPerMinute
        self.tokensPerMinute = tokensPerMinute
        self.requestsPerDay = requestsPerDay
    }

    /// No limits — a local model, or a provider we are not metering.
    public static let unlimited = ModelLimits(
        requestsPerMinute: nil, tokensPerMinute: nil, requestsPerDay: nil)
}

public enum BudgetRefusal: Error, Equatable, CustomStringConvertible {
    case requestsPerMinute(limit: Int)
    case tokensPerMinute(limit: Int, wanted: Int)
    case requestsPerDay(limit: Int)
    case userFairShare(limit: Int, user: String)

    public var description: String {
        switch self {
        case .requestsPerMinute(let limit): "RPM limit \(limit) reached"
        case .tokensPerMinute(let limit, let wanted):
            "TPM limit \(limit) would be exceeded by \(wanted) tokens"
        case .requestsPerDay(let limit): "RPD limit \(limit) reached"
        case .userFairShare(let limit, let user):
            "user \(user) has used their daily share of \(limit)"
        }
    }
}

/// The provider's day, which is **not** the local day and **not** a rolling
/// 24 hours from first use.
///
/// Verified 2026-11-24 against Google's own documentation
/// (`https://aistudio.google.com/docs/rate-limits`, which
/// `ai.google.dev/gemini-api/docs/rate-limits` now 301s to): *"Requests per
/// day (RPD) quotas reset at midnight Pacific time."*
///
/// Pacific, not UTC and not Asia/Kolkata, and the zone identifier rather than
/// a fixed -08:00 so the twice-yearly DST shift is handled rather than
/// silently moving our reset by an hour.
public struct ProviderDay: Sendable, Hashable, CustomStringConvertible {
    public let key: String
    public init(key: String) { self.key = key }
    public var description: String { key }

    /// Pacific. Force-unwrapped because a missing tzdata entry is a broken
    /// installation, not a runtime condition to handle.
    public static let zone = TimeZone(identifier: "America/Los_Angeles")!

    public static func containing(_ instant: Date) -> ProviderDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return ProviderDay(
            key: String(
                format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
    }
}

public enum BudgetReservation: Sendable, Equatable {
    case reserved
    case refused(BudgetRefusal)
}

/// Where the **daily** counters live.
///
/// In Brain they are in memory. A server implements this against Postgres so
/// that a restart or deploy does not reset the day and quietly overspend the
/// free tier. Brain gains no database dependency: it only ever sees this
/// protocol.
///
/// The minute window is deliberately **not** here. Losing it on restart costs
/// at most one minute of possible 429s, and persisting it would make every
/// call a round trip.
public protocol BudgetStore: Sendable {
    /// Check and charge both daily counters **in one atomic operation**.
    ///
    /// Not a read followed by a write. The enrichment worker is concurrent and
    /// a second server instance must not be able to spend in the gap between
    /// another instance reading and writing. In Postgres this is one statement.
    ///
    /// Charging happens before dispatch, so a request that then fails in
    /// transport is still counted. That is deliberate — see `release`.
    func reserve(
        model: String, user: String?, day: ProviderDay,
        modelDailyLimit: Int?, userDailyLimit: Int?
    ) async -> BudgetReservation

    /// Requests charged against `model` on `day`. Reporting only.
    func dailyRequests(model: String, day: ProviderDay) async -> Int
}

/// The default. Behaves exactly as the ledger did before `BudgetStore`
/// existed, so the CLI, the evals and `make ci` are unaffected.
public actor InMemoryBudgetStore: BudgetStore {
    private var modelCount: [String: Int] = [:]
    private var userCount: [String: Int] = [:]
    private var currentDay: ProviderDay?

    public init() {}

    /// Counters are kept for one day only. A long-lived process would
    /// otherwise accumulate a dictionary entry per model per day forever.
    private func rollIfNeeded(to day: ProviderDay) {
        guard currentDay != day else { return }
        modelCount.removeAll()
        userCount.removeAll()
        currentDay = day
    }

    public func reserve(
        model: String, user: String?, day: ProviderDay,
        modelDailyLimit: Int?, userDailyLimit: Int?
    ) async -> BudgetReservation {
        rollIfNeeded(to: day)
        if let limit = modelDailyLimit, (modelCount[model] ?? 0) >= limit {
            return .refused(.requestsPerDay(limit: limit))
        }
        if let user, let limit = userDailyLimit, (userCount[user] ?? 0) >= limit {
            return .refused(.userFairShare(limit: limit, user: user))
        }
        modelCount[model, default: 0] += 1
        if let user, userDailyLimit != nil { userCount[user, default: 0] += 1 }
        return .reserved
    }

    public func dailyRequests(model: String, day: ProviderDay) async -> Int {
        currentDay == day ? (modelCount[model] ?? 0) : 0
    }
}

/// Tracks what each model has spent, per minute and per day, and enforces a
/// per-user share of the daily pool.
///
/// **Per-user fair share is not optional.** RPD is one bucket shared by every
/// user of the deployment; without it a single person pasting a long brain dump
/// starves everyone else until midnight (`docs/06-model-router.md`).
///
/// An actor because the job worker is concurrent and a double-spend here means
/// a 429 from the provider.
public actor BudgetLedger {
    private struct Stamp: Sendable {
        let id: UInt64
        let at: Date
        let tokens: Int
    }

    private var limits: [String: ModelLimits] = [:]
    private var recent: [String: [Stamp]] = [:]
    private var nextStampID: UInt64 = 0
    private let store: any BudgetStore

    /// Injected so tests do not sleep and so the provider's reset clock can be
    /// followed rather than the local one.
    private let now: @Sendable () -> Date

    public init(
        store: any BudgetStore = InMemoryBudgetStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func setLimits(_ limits: ModelLimits, for model: String) {
        self.limits[model] = limits
    }

    /// Default per-user cap, as a share of the model's daily pool.
    ///
    /// `max(50, 2 × daily / activeUsers)` — generous enough that one person
    /// never feels throttled in normal use, tight enough that they cannot take
    /// the whole pool.
    public static func fairShare(dailyLimit: Int, activeUsers: Int) -> Int {
        max(50, 2 * dailyLimit / max(activeUsers, 1))
    }

    /// Charges the budget **before** dispatch, using an estimate.
    ///
    /// Estimating after the call is how you discover you are over the limit by
    /// being refused — TPM is the binding free-tier constraint, so it has to be
    /// paid up front.
    ///
    /// ## Why the minute slot is taken before the `await`
    ///
    /// This method suspends at the daily reservation. An actor is re-entrant
    /// at every suspension point, so if the minute window were only appended
    /// to *after* that await, two concurrent callers could both pass the RPM
    /// check before either recorded itself — reintroducing exactly the
    /// double-spend this actor exists to prevent. The slot is therefore taken
    /// synchronously and released if the daily reservation refuses.
    public func consume(
        model: String, estimatedTokens: Int, user: String? = nil, userLimit: Int? = nil
    ) async throws {
        let clock = now()
        let limit = limits[model] ?? .unlimited

        var window = (recent[model] ?? []).filter { clock.timeIntervalSince($0.at) < 60 }

        if let rpm = limit.requestsPerMinute, window.count >= rpm {
            recent[model] = window
            throw BudgetRefusal.requestsPerMinute(limit: rpm)
        }
        if let tpm = limit.tokensPerMinute {
            let spent = window.reduce(0) { $0 + $1.tokens }
            if spent + estimatedTokens > tpm {
                recent[model] = window
                throw BudgetRefusal.tokensPerMinute(limit: tpm, wanted: estimatedTokens)
            }
        }

        // Hold the slot across the suspension.
        nextStampID += 1
        let held = nextStampID
        window.append(Stamp(id: held, at: clock, tokens: estimatedTokens))
        recent[model] = window

        let outcome = await store.reserve(
            model: model, user: user, day: ProviderDay.containing(clock),
            modelDailyLimit: limit.requestsPerDay, userDailyLimit: userLimit)

        if case .refused(let refusal) = outcome {
            recent[model] = (recent[model] ?? []).filter { $0.id != held }
            throw refusal
        }
    }

    /// What has been spent, for the scorecard's quota line. Free is not the
    /// same as unlimited, so this is reported whether or not money is involved.
    public func usage(
        model: String
    ) async -> (minuteRequests: Int, minuteTokens: Int, dayRequests: Int) {
        let clock = now()
        let window = (recent[model] ?? []).filter { clock.timeIntervalSince($0.at) < 60 }
        let daily = await store.dailyRequests(
            model: model, day: ProviderDay.containing(clock))
        return (window.count, window.reduce(0) { $0 + $1.tokens }, daily)
    }
}

/// Stops hammering a provider that is already failing.
///
/// Opens after consecutive failures, lets one probe through after a cooldown,
/// and closes again on success. While open the router skips that rung entirely
/// rather than waiting for another timeout.
public actor CircuitBreaker {
    public enum State: Sendable, Equatable { case closed, open, halfOpen }

    private var failures = 0
    private var openedAt: Date?
    private let threshold: Int
    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        threshold: Int = 5, cooldown: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.threshold = threshold
        self.cooldown = cooldown
        self.now = now
    }

    public func state() -> State {
        guard let openedAt else { return .closed }
        return now().timeIntervalSince(openedAt) >= cooldown ? .halfOpen : .open
    }

    /// False means skip this provider without calling it.
    public func allows() -> Bool { state() != .open }

    public func recordSuccess() {
        failures = 0
        openedAt = nil
    }

    public func recordFailure() {
        failures += 1
        if failures >= threshold, openedAt == nil { openedAt = now() }
        // A failed half-open probe restarts the cooldown rather than
        // half-opening again immediately.
        if state() == .halfOpen { openedAt = now() }
    }
}
