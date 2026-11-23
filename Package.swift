// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Brain",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BrainCore", targets: ["BrainCore"]),
        .executable(name: "brain", targets: ["BrainCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        // Pure logic. No AI, no network, no I/O. Deliberately dependency-free.
        .target(name: "BrainCore"),

        // Dogfood CLI: read a plain-text dump, print next / quick-wins / blocked.
        .executableTarget(
            name: "BrainCLI",
            dependencies: [
                "BrainCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        .testTarget(name: "BrainCoreTests", dependencies: ["BrainCore"]),
    ]
)
