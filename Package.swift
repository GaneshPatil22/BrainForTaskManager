// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Brain",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BrainCore", targets: ["BrainCore"]),
        .library(name: "BrainDatasets", targets: ["BrainDatasets"]),
        .library(name: "BrainEval", targets: ["BrainEval"]),
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
                "BrainCore", "BrainDatasets",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // Metrics and the scorecard. A library, not buried in the executable,
        // because the thing that reports every number must itself be tested.
        .target(name: "BrainEval", dependencies: ["BrainCore", "BrainDatasets"]),

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
    ]
)
