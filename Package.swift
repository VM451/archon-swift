// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "Archon",
    platforms: [
        .iOS(.v27),
        .macOS(.v27),
        .visionOS(.v27)
    ],
    products: [
        .library(name: "ArchonCore", targets: ["ArchonCore"]),
        .library(name: "ArchonModels", targets: ["ArchonModels"]),
        .library(name: "ArchonAgent", targets: ["ArchonAgent"]),
        .library(name: "ArchonContext", targets: ["ArchonContext"]),
        .library(name: "ArchonMemory", targets: ["ArchonMemory"]),
        .library(name: "ArchonSearch", targets: ["ArchonSearch"]),
        .library(name: "ArchonSandbox", targets: ["ArchonSandbox"]),
        .library(name: "ArchonConnect", targets: ["ArchonConnect"]),
        .library(name: "ArchonComputerUse", targets: ["ArchonComputerUse"]),
        .library(name: "ArchonModelsUI", targets: ["ArchonModelsUI"]),
        .library(name: "ArchonFull", targets: ["ArchonFull"]),
        .executable(name: "archon-model", targets: ["ArchonModelCLI"]),
        .executable(name: "archon-example-app", targets: ["ArchonExampleApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "602.0.0" ..< "604.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMajor(from: "3.31.4")),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0")
    ],
    targets: [
        .target(
            name: "ArchonCore",
            path: "Sources/ArchonCore",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "ArchonModels",
            dependencies: ["ArchonCore"],
            path: "Sources/ArchonModels",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "ArchonContext",
            dependencies: ["ArchonCore"],
            path: "Sources/ArchonContext",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "ArchonConnect",
            dependencies: ["ArchonCore"],
            path: "Sources/ArchonConnect",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "ArchonComputerUse",
            dependencies: ["ArchonCore"],
            path: "Sources/ArchonComputerUse",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .macro(
            name: "ArchonAgentMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax")
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "ArchonAgent",
            dependencies: [
                "ArchonCore",
                "ArchonModels",
                "ArchonAgentMacros",
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/ArchonAgent",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "ArchonMemory",
            dependencies: [
                "ArchonCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/ArchonMemory",
            exclude: ["Documentation.docc"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "ArchonSearch",
            dependencies: ["ArchonCore"],
            path: "Sources/ArchonSearch",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "ArchonSandbox",
            dependencies: ["ArchonCore"],
            path: "Sources/ArchonSandbox",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "ArchonModelsUI",
            dependencies: ["ArchonCore", "ArchonModels"],
            path: "Sources/ArchonModelsUI",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "ArchonFull",
            dependencies: [
                "ArchonCore",
                "ArchonModels",
                "ArchonAgent",
                "ArchonContext",
                "ArchonMemory",
                "ArchonSearch",
                "ArchonSandbox",
                "ArchonConnect",
                "ArchonComputerUse",
                "ArchonModelsUI"
            ],
            path: "Sources/ArchonFull",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "ArchonModelCLI",
            dependencies: [
                "ArchonAgent",
                "ArchonModels",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Tools/ArchonModelCLI",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "ArchonExampleApp",
            dependencies: ["ArchonAgent", "ArchonModels", "ArchonModelsUI"],
            path: "Examples/ArchonExampleApp",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ArchonCoreTests",
            dependencies: ["ArchonCore"],
            path: "Tests/ArchonCoreTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ArchonModelsTests",
            dependencies: ["ArchonModels"],
            path: "Tests/ArchonModelsTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ArchonContextTests",
            dependencies: ["ArchonContext"],
            path: "Tests/ArchonContextTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ArchonConnectTests",
            dependencies: ["ArchonConnect"],
            path: "Tests/ArchonConnectTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ArchonComputerUseTests",
            dependencies: ["ArchonComputerUse"],
            path: "Tests/ArchonComputerUseTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ArchonAgentTests",
            dependencies: [
                "ArchonAgent",
                "ArchonModels",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            path: "Tests/ArchonAgentTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ArchonMemoryTests",
            dependencies: ["ArchonMemory"],
            path: "Tests/ArchonMemoryTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ArchonSearchTests",
            dependencies: ["ArchonSearch"],
            path: "Tests/ArchonSearchTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ArchonSandboxTests",
            dependencies: ["ArchonSandbox"],
            path: "Tests/ArchonSandboxTests",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        )
    ],
    swiftLanguageModes: [.v6]
)
