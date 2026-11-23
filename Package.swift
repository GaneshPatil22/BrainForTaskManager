// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Brain",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BrainCore", targets: ["BrainCore"]),
        .library(name: "BrainDatasets", targets: ["BrainDatasets"]),
        .library(name: "BrainEval", targets: ["BrainEval"]),
        .library(name: "BrainHarness", targets: ["BrainHarness"]),
        .library(name: "BrainPipeline", targets: ["BrainPipeline"]),
        .library(name: "BrainAdapters", targets: ["BrainAdapters"]),
        // The composition root the server imports: ProductionRouter.make is
        // the only supported way to build the production ladder, so the
        // module has to leave the package.
        .library(name: "BrainProduction", targets: ["BrainProduction"]),
        .executable(name: "brain", targets: ["BrainCLI"]),
        .executable(name: "EvalCLI", targets: ["EvalCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        // Pure logic. No AI, no network, no I/O. Deliberately dependency-free.
        .target(name: "BrainCore"),

        // File formats: scenario JSON, the .brain dump format, capture JSONL.
        // Everything that touches disk lives here so BrainCore stays pure.
        .target(name: "BrainDatasets", dependencies: ["BrainCore"]),

        // Dogfood CLI: read a plain-text dump, print next / quick-wins / blocked.
        .executableTarget(
            name: "BrainCLI",
            dependencies: [
                "BrainCore", "BrainDatasets", "BrainPipeline", "BrainAdapters", "BrainEval",
                "BrainProduction",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // Every model call passes through here: guards, router, budget ledger,
        // cassettes. No provider SDKs — just the protocol they implement.
        .target(name: "BrainHarness", dependencies: ["BrainCore"]),

        // Provider implementations. The only target that knows a vendor
        // exists; everything else talks to LLMProvider.
        .target(name: "BrainAdapters", dependencies: ["BrainCore", "BrainHarness"]),

        // Composition root: the one supported way to build the production
        // ladder. Kept separate because it is the only place that needs to
        // see both the adapters and the pipeline's prompts, and neither of
        // those should have to depend on the other.
        .target(
            name: "BrainProduction",
            dependencies: ["BrainCore", "BrainHarness", "BrainAdapters", "BrainPipeline"]),

        // capture -> item + suggested edges. Typed stages, each degrading to
        // "unknown" rather than throwing: a capture is never lost.
        .target(name: "BrainPipeline", dependencies: ["BrainCore", "BrainHarness"]),

        // Metrics and the scorecard. A library, not buried in the executable,
        // because the thing that reports every number must itself be tested.
        .target(
            name: "BrainEval",
            dependencies: ["BrainCore", "BrainDatasets", "BrainHarness", "BrainPipeline"]),

        // The eval runner. Lives in Swift so it tests the code that ships.
        .executableTarget(
            name: "EvalCLI",
            dependencies: [
                "BrainCore", "BrainDatasets", "BrainEval",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        .testTarget(name: "BrainCoreTests", dependencies: ["BrainCore", "BrainDatasets"]),
        .testTarget(name: "BrainEvalTests", dependencies: ["BrainEval", "BrainDatasets"]),
        .testTarget(name: "BrainHarnessTests", dependencies: ["BrainHarness", "BrainCore"]),
        .testTarget(
            name: "BrainAdaptersTests", dependencies: ["BrainAdapters", "BrainHarness"]),
        .testTarget(
            name: "BrainProductionTests",
            dependencies: ["BrainProduction", "BrainHarness"]),
        .testTarget(
            name: "BrainPipelineTests",
            dependencies: ["BrainPipeline", "BrainHarness", "BrainCore"]),
    ]
)
