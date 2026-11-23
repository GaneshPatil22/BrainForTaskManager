import Foundation

// MARK: - Tiers

/// Who decided a value. Recorded on every classified field so the scorecard can
/// be sliced by tier (`docs/09-tiering.md`).
public enum Tier: String, Sendable, Codable, CaseIterable {
    case t0  // deterministic code
    case t1  // our own model
    case t2  // global LLM
    case t3  // the user answered
    case user  // the user authored it directly
}

// MARK: - Spans and classification

/// A half-open range of UTF-16 offsets into a capture's raw text. Every
/// extracted value cites one, and the harness verifies it resolves.
public struct Span: Hashable, Sendable, Codable {
    public let start: Int
    public let end: Int
    public init(start: Int, end: Int) {
        precondition(start >= 0 && end >= start, "invalid span")
        self.start = start
        self.end = end
    }

    /// The text this span points at, or nil if it does not resolve.
    public func resolve(in text: String) -> String? {
        let utf16 = Array(text.utf16)
        guard end <= utf16.count, start <= end else { return nil }
        return String(decoding: utf16[start..<end], as: UTF16.self)
    }
}

/// A value that may be unknown, always carrying its confidence and its source.
///
/// `nil` is never a failure. The eval rewards abstaining over a wrong guess.
public struct Classified<Value: Sendable & Hashable>: Hashable, Sendable {
    public let value: Value?
    public let confidence: Double
    public let tier: Tier
    public let evidence: Span?

    public init(_ value: Value?, confidence: Double, tier: Tier, evidence: Span? = nil) {
        self.value = value
        self.confidence = min(max(confidence, 0), 1)
        self.tier = tier
        self.evidence = evidence
    }

    /// The abstention case. Always legal, for every field.
    public static func unknown(tier: Tier = .t0) -> Self {
        .init(nil, confidence: 0, tier: tier)
    }

    public var isKnown: Bool { value != nil }
}

// MARK: - Enums

public enum ItemType: String, Sendable, Codable, CaseIterable {
    case task, idea, note, reminder, link
}

public enum ItemStatus: String, Sendable, Codable, CaseIterable {
    case open, done, dropped
    /// Only open items contribute to leverage or appear in rankings.
    public var isOpen: Bool { self == .open }
}

public enum EffortBucket: String, Sendable, Codable, CaseIterable {
    case tiny, small, medium, large, xlarge, unknown

    /// Minutes used by the scoring denominator (`docs/02-scoring-spec.md`).
    /// `unknown` is treated as `medium` for scoring but flagged in the UI.
    public var minutes: Double {
        switch self {
        case .tiny: 5
        case .small: 20
        case .medium, .unknown: 60
        case .large: 240
        case .xlarge: 960
        }
    }

    /// Quick wins are drawn from these buckets.
    public var isQuick: Bool { self == .tiny || self == .small }
}

public enum CaptureSource: String, Sendable, Codable, CaseIterable {
    case text, voice, image, share
}

public enum CaptureStatus: String, Sendable, Codable, CaseIterable {
    case raw, enriching, enriched, failed
    /// `failed` is always retryable — a capture is never lost.
    public var isRetryable: Bool { self == .failed }
}

public enum EdgeKind: String, Sendable, Codable, CaseIterable {
    /// `A blocks B` — B cannot start until A is done. Directed, acyclic.
    case blocks
    /// Symmetric, no scoring weight, purely navigational.
    case relates
    /// Symmetric; resolution merges into the older item.
    case duplicate
    /// Item serves a goal. From item to goal only.
    case serves
}

public enum EdgeSource: String, Sendable, Codable, CaseIterable {
    case t0Rule, t1Model, t2Model, user
}

public enum GoalStatus: String, Sendable, Codable, CaseIterable {
    case active, achieved, abandoned
}

// MARK: - Entities

/// The raw thing the user dumped. Append-only; never modified after creation.
public struct Capture: Hashable, Sendable, Identifiable {
    public let id: ULID
    public let rawText: String
    public let source: CaptureSource
    public let createdAt: Date
    public var status: CaptureStatus
    public let idempotencyKey: String?

    public init(
        id: ULID, rawText: String, source: CaptureSource = .text,
        createdAt: Date, status: CaptureStatus = .raw, idempotencyKey: String? = nil
    ) {
        self.id = id
        self.rawText = rawText
        self.source = source
        self.createdAt = createdAt
        self.status = status
        self.idempotencyKey = idempotencyKey
    }
}

public struct Item: Hashable, Sendable, Identifiable {
    public let id: ULID
    public let captureId: ULID?
    public var title: String
    public var type: Classified<ItemType>
    public var status: ItemStatus
    public var effort: Classified<EffortBucket>
    public var dueAt: Classified<Date>
    public var goalId: Classified<ULID>
    /// What doing this task involves. Orthogonal to `type`.
    /// Derived at T0 from the title when not supplied (`Category.swift`).
    public var category: Classified<TaskCategory>
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ULID, captureId: ULID? = nil, title: String,
        type: Classified<ItemType> = .unknown(),
        status: ItemStatus = .open,
        effort: Classified<EffortBucket> = .unknown(),
        dueAt: Classified<Date> = .unknown(),
        goalId: Classified<ULID> = .unknown(),
        category: Classified<TaskCategory>? = nil,
        createdAt: Date, updatedAt: Date? = nil
    ) {
        self.id = id
        self.captureId = captureId
        self.title = title
        self.type = type
        self.status = status
        self.effort = effort
        self.dueAt = dueAt
        self.goalId = goalId
        // Nothing supplied: classify from the title at T0. Free, deterministic,
        // and abstains rather than guessing.
        let resolvedCategory = category ?? CategoryClassifier.classify(title)
        self.category = resolvedCategory
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Effort used by scoring. Absent effort scores as `unknown` (= medium).
    public var effortBucket: EffortBucket { effort.value ?? .unknown }
}

public struct Goal: Hashable, Sendable, Identifiable {
    public let id: ULID
    public var title: String
    public var status: GoalStatus
    public let createdAt: Date

    public init(id: ULID, title: String, status: GoalStatus = .active, createdAt: Date) {
        self.id = id
        self.title = title
        self.status = status
        self.createdAt = createdAt
    }
}

public struct Edge: Hashable, Sendable, Identifiable {
    public let id: ULID
    public let from: ULID
    public let to: ULID
    public let kind: EdgeKind
    public var confidence: Double
    public var source: EdgeSource
    public var confirmed: Bool

    public init(
        id: ULID, from: ULID, to: ULID, kind: EdgeKind,
        confidence: Double = 1.0, source: EdgeSource, confirmed: Bool = false
    ) {
        // Invariant 3 (docs/01-domain.md): only a user may confirm an edge.
        precondition(
            !confirmed || source == .user,
            "confirmed == true requires source == .user")
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.confidence = min(max(confidence, 0), 1)
        self.source = source
        self.confirmed = confirmed
    }
}

/// The training signal: written whenever a user changes what a tier decided.
public struct Correction: Hashable, Sendable, Identifiable {
    public let id: ULID
    public let targetId: ULID
    public let field: String
    public let beforeValue: String?
    public let afterValue: String?
    public let tier: Tier
    public let createdAt: Date

    public init(
        id: ULID, targetId: ULID, field: String, beforeValue: String?,
        afterValue: String?, tier: Tier, createdAt: Date
    ) {
        self.id = id
        self.targetId = targetId
        self.field = field
        self.beforeValue = beforeValue
        self.afterValue = afterValue
        self.tier = tier
        self.createdAt = createdAt
    }
}
