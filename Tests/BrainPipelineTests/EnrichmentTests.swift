import BrainCore
import BrainHarness
import Foundation
import Testing

@testable import BrainPipeline

/// The pipeline's one inviolable promise: **a capture is never lost**. Every
/// other behaviour here is in service of that (`docs/07-harness-spec.md`).
@Suite("EnrichmentPipeline")
struct EnrichmentTests {
    static let zone = TimeZone(identifier: "Asia/Kolkata")!
    /// Monday 23 Nov 2026, 09:00 IST — the same fixed clock the datasets use.
    static let now = Date(timeIntervalSince1970: 1_795_404_600)

    func pipeline(router: ModelRouter? = nil) -> EnrichmentPipeline {
        EnrichmentPipeline(timeZone: Self.zone, router: router)
    }

    func capture(_ text: String, _ gen: inout ULIDGenerator) -> Capture {
        Capture(id: gen.next(), rawText: text, createdAt: Self.now)
    }

    func generator() -> ULIDGenerator {
        ULIDGenerator(seed: 1, clock: { UInt64(Self.now.timeIntervalSince1970 * 1000) })
    }

    @Test("A Hinglish capture is read end to end, all at T0")
    func hinglishEndToEnd() async {
        var gen = generator()
        let input = capture("Kal plumber ko call krna h, 20 min ka kaam", &gen)
        let result = await pipeline().enrich(
            capture: input, graph: BrainGraph(), now: Self.now, idGenerator: &gen)

        #expect(result.item.type.value == .task)
        #expect(result.item.effort.value == .small)
        #expect(result.item.dueAt.value != nil)
        #expect(result.item.category.value == .communication)
        #expect(result.trace.tierByField["type"] == .t0)
        #expect(result.trace.estimatedTokens == 0, "no model should have been called")
        #expect(result.capture.status == .enriched)
    }

    /// The promise, tested directly.
    @Test("An empty capture is kept, marked failed, and stays retryable")
    func emptyCaptureSurvives() async {
        var gen = generator()
        for text in ["", "   ", "\u{200B}\u{200B}"] {
            let input = capture(text, &gen)
            let result = await pipeline().enrich(
                capture: input, graph: BrainGraph(), now: Self.now, idGenerator: &gen)
            #expect(result.capture.status == .failed, "\(text.debugDescription)")
            #expect(result.capture.status.isRetryable)
            #expect(result.capture.rawText == text, "raw text must survive verbatim")
        }
    }

    @Test("Every provider failing costs a field, not the capture")
    func providerOutageSurvives() async {
        var gen = generator()
        let router = ModelRouter(
            ladders: [
                .classifyType: [
                    Rung(
                        name: "dead", action: .provider(FakeModel.alwaysFails()),
                        model: "m", tier: .t2),
                    Rung(name: "give-up", action: .degrade, model: "-", tier: .t0),
                ]
            ],
            ledger: BudgetLedger(), mode: .live)

        // A fragment T0 cannot type, so it has to escalate.
        let input = capture("the thing about the refunds and the other matter entirely", &gen)
        let result = await pipeline(router: router).enrich(
            capture: input, graph: BrainGraph(), now: Self.now, idGenerator: &gen)

        #expect(result.capture.status == .enriched, "the capture survives the outage")
        #expect(result.item.title.isEmpty == false)
        #expect(result.trace.unresolved.contains("type"))
    }

    /// Guard 10 runs before anything leaves the machine, and the original is
    /// untouched.
    @Test("PII is redacted for the model but kept in the capture")
    func piiRedaction() async {
        var gen = generator()
        let input = capture("call priya on 9876543210 about the ₹1,200 bill", &gen)
        let result = await pipeline().enrich(
            capture: input, graph: BrainGraph(), now: Self.now, idGenerator: &gen)

        #expect(result.trace.redactedBeforeSending)
        #expect(result.capture.rawText.contains("9876543210"), "original must be intact")
    }

    @Test("A stated dependency becomes an unconfirmed edge")
    func statedDependency() async throws {
        var gen = generator()
        var graph = BrainGraph()
        let blocker = Item(
            id: gen.next(), title: "Get client approval", createdAt: Self.now)
        graph.insert(blocker)

        let input = capture("client approval ke baad invoice bhejna h", &gen)
        let result = await pipeline().enrich(
            capture: input, graph: graph, now: Self.now, idGenerator: &gen)

        let edge = try #require(result.suggestedEdges.first)
        #expect(edge.from == blocker.id)
        #expect(edge.kind == .blocks)
        // Invariant 3: only a human may confirm.
        #expect(edge.confirmed == false)
        #expect(edge.source == .t0Rule)
    }

    @Test("A dependency matching nothing produces no edge at all")
    func unmatchedDependency() async {
        var gen = generator()
        let input = capture("after the thing nobody has written down yet, do this", &gen)
        let result = await pipeline().enrich(
            capture: input, graph: BrainGraph(), now: Self.now, idGenerator: &gen)
        #expect(result.suggestedEdges.isEmpty, "precision over recall — no guess")
    }

    /// T0 answers, so no quota is spent even though a router is available.
    @Test("The router is not called when T0 already knows")
    func t0ShortCircuits() async {
        var gen = generator()
        let router = ModelRouter(
            ladders: [
                .classifyType: [
                    Rung(
                        name: "should-not-run", action: .provider(FakeModel.misbehaves()),
                        model: "m", tier: .t2)
                ]
            ],
            ledger: BudgetLedger(), mode: .live)

        let input = capture("call the plumber", &gen)
        let result = await pipeline(router: router).enrich(
            capture: input, graph: BrainGraph(), now: Self.now, idGenerator: &gen)

        #expect(result.item.type.value == .task)
        #expect(result.trace.tierByField["type"] == .t0)
        #expect(result.trace.routedCapabilities.isEmpty)
    }

    @Test("Enrichment is deterministic")
    func deterministic() async {
        for text in ["Kal plumber ko call krna h", "idea: batch the reminders", ""] {
            var genA = generator(), genB = generator()
            let a = await pipeline().enrich(
                capture: capture(text, &genA), graph: BrainGraph(), now: Self.now,
                idGenerator: &genA)
            let b = await pipeline().enrich(
                capture: capture(text, &genB), graph: BrainGraph(), now: Self.now,
                idGenerator: &genB)
            #expect(a.item.type.value == b.item.type.value, "\(text)")
            #expect(a.item.dueAt.value == b.item.dueAt.value, "\(text)")
            #expect(a.item.category.value == b.item.category.value, "\(text)")
        }
    }
}

@Suite("Normalizer")
struct NormalizerTests {
    @Test("List numbering, zero-width and control characters are removed")
    func cleans() {
        #expect(Normalizer.normalize("12. call the plumber").normalized == "call the plumber")
        #expect(Normalizer.normalize("ca\u{200B}ll plumber").normalized == "call plumber")
        #expect(Normalizer.normalize("call\u{0001} plumber").normalized == "call plumber")
        #expect(Normalizer.normalize("call   the    plumber").normalized == "call the plumber")
    }

    /// Newlines are structure, not noise — a multi-line capture is normal.
    @Test("Newlines and tabs survive")
    func keepsStructure() {
        #expect(Normalizer.normalize("call plumber\nkal subah").normalized.contains("\n"))
    }

    /// Span grounding depends on this: rewrite the text and every offset lies.
    @Test("The original is never modified")
    func originalPreserved() {
        let input = "12. ca\u{200B}ll   plumber"
        #expect(Normalizer.normalize(input).original == input)
    }

    @Test("URLs are extracted with spans into the original")
    func urls() throws {
        let input = "read this https://example.com/a?b=c kal"
        let result = Normalizer.normalize(input)
        let url = try #require(result.urls.first)
        #expect(url.text == "https://example.com/a?b=c")
        #expect(url.span.resolve(in: input) == url.text)
    }

    @Test("Composed and decomposed forms normalise alike")
    func unicodeForms() {
        // "é" precomposed vs "e" + combining acute.
        #expect(
            Normalizer.normalize("caf\u{00E9}").normalized
                == Normalizer.normalize("cafe\u{0301}").normalized)
    }
}
