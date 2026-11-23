import ArgumentParser
import BrainAdapters
import BrainCore
import BrainDatasets
import BrainHarness
import BrainPipeline
import Foundation

/// Calls a live model and records the answers as cassettes.
///
/// **The only command that spends quota.** Everything else replays. It is
/// deliberately awkward to run by accident: `--limit` is required, pacing is
/// enforced against the published RPM/TPM, and it refuses to start without a
/// key in the environment.
struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Call a live model and record cassettes. Spends free-tier quota.")

    @Option(name: .long, help: "Model id, as listed by the provider.")
    var model: String = "gemma-4-26b-a4b-it"

    @Option(
        name: .long,
        help: "generate (generateContent) or decide (the Decisions API).")
    var api: String = "generate"

    @Option(name: .long, help: "How many captures to record. Required — no unbounded runs.")
    var limit: Int

    @Option(name: .long, help: "Dataset split to draw captures from.")
    var split: String = "dev"

    @Option(name: .long, help: "Where to write cassettes.")
    var cassettes: String = "eval/cassettes"

    @Flag(name: .long, help: "Only captures the T0 rules could not type — the real escalation set.")
    var escalationsOnly = false

    func run() async throws {
        guard let key = ProcessInfo.processInfo.environment["GOOGLE_AI_API_KEY"],
            !key.isEmpty
        else {
            throw ValidationError(
                """
                GOOGLE_AI_API_KEY is not set.

                It lives in .env (gitignored). Load it for this command only:
                    set -a; source .env; set +a; swift run brain record --limit 5
                """)
        }

        let zone = TimeZone(identifier: "Asia/Kolkata")!
        let now = SyntheticLoader.now
        let captures = try SyntheticLoader.load(
            directory: URL(fileURLWithPath: "datasets/v1"), split: split)
        guard !captures.isEmpty else {
            throw ValidationError("no synthetic captures in split \(split)")
        }

        // Recording what T0 already answers is pure waste: those calls never
        // happen in production, because the router stops at the first rung.
        let classifier = TypeClassifier(timeZone: zone)
        let pool =
            escalationsOnly
            ? captures.filter { !classifier.classify($0.rawText, now: now).isKnown }
            : captures
        let batch = Array(pool.prefix(limit))

        // Two tracks, as B3 requires: generate-and-parse against a closed-set
        // decision call, on the same captures so the comparison is paired.
        let isDecision = api == "decide"
        let limits = isDecision ? DecisionLimits.geminiDecision1 : GoogleLimits.limits(for: model)
        let provider: any LLMProvider =
            isDecision
            ? DecisionProvider(
                model: model, apiKey: key,
                instructions: Prompts.classifyTypeSystem,
                criteria: Prompts.typeCriteria)
            // 20s was too short: a thinking model spends 300+ tokens reasoning
            // before it answers, and a third of the first batch timed out.
            : GoogleProvider(model: model, apiKey: key, timeout: 60)
        let store = CassetteStore(
            directory: URL(fileURLWithPath: cassettes), mode: .record)
        let ledger = BudgetLedger()
        await ledger.setLimits(limits, for: model)

        // Pace against the tighter of RPM and TPM. TPM is usually the binding
        // one on the free tier, and being refused is slower than waiting.
        let perMinute = min(
            limits.requestsPerMinute ?? 30,
            (limits.tokensPerMinute ?? 16_000) / 600)
        let gapNanos = UInt64(60.0 / Double(max(perMinute, 1)) * 1_000_000_000)

        print(
            """

            RECORDING  model \(model) · split \(split)

              candidates        \(pool.count)\(escalationsOnly ? "  (T0 could not type these)" : "")
              recording         \(batch.count)
              free-tier limits  \(limits.requestsPerMinute ?? 0) rpm · \
            \(limits.tokensPerMinute ?? 0) tpm · \(limits.requestsPerDay ?? 0) rpd
              pacing            \(perMinute)/min  (~\(batch.count * 60 / max(perMinute, 1))s)

            """)

        var ok = 0, failed = 0, skipped = 0
        var errors: [String: Int] = [:]

        for (index, capture) in batch.enumerated() {
            let normalized = Normalizer.normalize(capture.rawText)
            let request = ModelRequest(
                capability: .classifyType,
                system: Prompts.classifyTypeSystem,
                untrustedContent: normalized.redacted,
                allowedAnswers: ItemType.allCases.map(\.rawValue),
                promptVersion: Prompts.version)

            if await store.lookup(request, model: model) != nil {
                skipped += 1
                continue
            }
            do {
                try await ledger.consume(
                    model: model, estimatedTokens: provider.estimateTokens(request))
            } catch {
                errors["budget: \(error)", default: 0] += 1
                failed += 1
                continue
            }
            // Retry transport failures with backoff. 503 ("model overloaded")
            // and timeouts were both common on the first run and both clear on
            // a retry — giving up on them would silently shrink the dataset.
            var lastError: Error?
            for attempt in 0..<3 {
                do {
                    let response = try await provider.complete(request)
                    try await store.write(request, response: response, model: model)
                    ok += 1
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < 2 {
                        try? await Task.sleep(
                            nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_500_000_000))
                    }
                }
            }
            if let lastError {
                errors["\(lastError)", default: 0] += 1
                failed += 1
            }
            if index % 25 == 24 {
                print("  \(index + 1)/\(batch.count)  ok \(ok)  failed \(failed)")
            }
            if index < batch.count - 1 { try await Task.sleep(nanoseconds: gapNanos) }
        }

        let usage = await ledger.usage(model: model)
        let stats = await store.stats()
        print(
            """

            recorded \(ok) · failed \(failed) · already had \(skipped)
            quota used today: \(usage.dayRequests) of \(limits.requestsPerDay ?? 0)
            cassettes on disk: \(stats.recorded) new
            """)
        for (reason, count) in errors.sorted(by: { $0.value > $1.value }).prefix(5) {
            print("  \(count)x  \(reason.prefix(110))")
        }
    }
}
