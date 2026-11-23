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
        let at: Date
        let tokens: Int
    }

    private var limits: [String: ModelLimits] = [:]
    private var recent: [String: [Stamp]] = [:]
    private var dayCount: [String: Int] = [:]
    private var dayStart: [String: Date] = [:]
    private var userDayCount: [String: Int] = [:]
    private var userDayStart: [String: Date] = [:]

    /// Injected so tests do not sleep and so the provider's reset clock can be
    /// followed rather than the local one.
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
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
    public func consume(
        model: String, estimatedTokens: Int, user: String? = nil, userLimit: Int? = nil
    ) throws {
        let clock = now()
        let limit = limits[model] ?? .unlimited

        // Roll the per-day counters on the provider's day boundary.
        if let start = dayStart[model], clock.timeIntervalSince(start) >= 86_400 {
            dayCount[model] = 0
            dayStart[model] = clock
        } else if dayStart[model] == nil {
            dayStart[model] = clock
        }

        // Drop anything outside the rolling minute.
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
        if let rpd = limit.requestsPerDay, (dayCount[model] ?? 0) >= rpd {
            throw BudgetRefusal.requestsPerDay(limit: rpd)
        }

        if let user, let userLimit {
            if let start = userDayStart[user], clock.timeIntervalSince(start) >= 86_400 {
                userDayCount[user] = 0
                userDayStart[user] = clock
            } else if userDayStart[user] == nil {
                userDayStart[user] = clock
            }
            if (userDayCount[user] ?? 0) >= userLimit {
                throw BudgetRefusal.userFairShare(limit: userLimit, user: user)
            }
            userDayCount[user, default: 0] += 1
        }

        window.append(Stamp(at: clock, tokens: estimatedTokens))
        recent[model] = window
        dayCount[model, default: 0] += 1
    }

    /// What has been spent, for the scorecard's quota line. Free is not the
    /// same as unlimited, so this is reported whether or not money is involved.
    public func usage(model: String) -> (minuteRequests: Int, minuteTokens: Int, dayRequests: Int) {
        let clock = now()
        let window = (recent[model] ?? []).filter { clock.timeIntervalSince($0.at) < 60 }
        return (window.count, window.reduce(0) { $0 + $1.tokens }, dayCount[model] ?? 0)
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
