import Darwin
import Foundation

private enum ScopeCheckError: LocalizedError {
    case packageDumpFailed(Int32, String)
    case invalidPackageDescription
    case missingTarget(String)
    case unexpectedTargets(Set<String>)
    case unexpectedDependencies(target: String, dependencies: Set<String>, expected: Set<String>)

    var errorDescription: String? {
        switch self {
        case let .packageDumpFailed(code, output):
            return "swift package dump-package failed with exit code \(code): \(output)"
        case .invalidPackageDescription:
            return "swift package dump-package did not return a valid target description."
        case let .missingTarget(target):
            return "Expected target \(target) was not present in the package description."
        case let .unexpectedTargets(targets):
            return "Unlisted production targets require an explicit product-scope rule: \(targets.sorted().joined(separator: ", "))."
        case let .unexpectedDependencies(target, dependencies, expected):
            return "Target \(target) has dependencies [\(dependencies.sorted().joined(separator: ", "))], expected [\(expected.sorted().joined(separator: ", "))]."
        }
    }
}

private let expectedDependencies: [String: Set<String>] = [
    "ArchonCore": [],
    "ArchonModels": ["ArchonCore"],
    "ArchonAgentMacros": [
        "SwiftSyntaxMacros@swift-syntax", "SwiftCompilerPlugin@swift-syntax",
        "SwiftSyntax@swift-syntax", "SwiftSyntaxBuilder@swift-syntax"
    ],
    "ArchonAgent": [
        "ArchonCore", "ArchonModels", "ArchonAgentMacros",
        "MLX@mlx-swift", "MLXLLM@mlx-swift-lm", "MLXLMCommon@mlx-swift-lm",
        "MLXHuggingFace@mlx-swift-lm", "HuggingFace@swift-huggingface",
        "Tokenizers@swift-transformers"
    ],
    "ArchonContext": ["ArchonCore"],
    "ArchonMemory": ["ArchonCore", "GRDB@GRDB.swift"],
    "ArchonMemoryProxima": ["ArchonMemory", "ProximaKit@ProximaKit"],
    "ArchonSearch": ["ArchonCore"],
    "ArchonSandbox": ["ArchonCore"],
    "ArchonConnect": ["ArchonCore", "MCP@swift-sdk"],
    "ArchonComputerUse": ["ArchonCore"],
    "ArchonModelsUI": ["ArchonCore", "ArchonModels"],
    "ArchonFull": [
        "ArchonCore", "ArchonModels", "ArchonAgent", "ArchonContext",
        "ArchonMemory", "ArchonSearch", "ArchonSandbox", "ArchonConnect",
        "ArchonComputerUse", "ArchonModelsUI"
    ],
    "ArchonModelCLI": ["ArchonAgent", "ArchonModels", "ArgumentParser@swift-argument-parser"],
    "ArchonExampleApp": ["ArchonAgent", "ArchonModels", "ArchonModelsUI"]
]

func dumpedPackageDescription() throws -> [String: Any] {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "package", "dump-package"]
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    try process.run()
    process.waitUntilExit()

    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errors = errorPipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw ScopeCheckError.packageDumpFailed(
            process.terminationStatus,
            String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    guard let package = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
        throw ScopeCheckError.invalidPackageDescription
    }
    return package
}

func dependencies(in target: [String: Any]) -> Set<String> {
    let rawDependencies = target["dependencies"] as? [[String: Any]] ?? []
    return Set(rawDependencies.compactMap { dependency in
        if let byName = dependency["byName"] as? [Any],
           let name = byName.first as? String {
            return name
        }
        if let product = dependency["product"] as? [Any],
           let productName = product.first as? String,
           product.count > 1,
           let packageName = product[1] as? String {
            return "\(productName)@\(packageName)"
        }
        return nil
    })
}

do {
    let package = try dumpedPackageDescription()
    guard let rawTargets = package["targets"] as? [[String: Any]] else {
        throw ScopeCheckError.invalidPackageDescription
    }

    let targets = Dictionary(uniqueKeysWithValues: rawTargets.compactMap { target -> (String, [String: Any])? in
        guard let name = target["name"] as? String else { return nil }
        return (name, target)
    })

    let productionTargets = Set(rawTargets.compactMap { target -> String? in
        guard let type = target["type"] as? String,
              type == "regular" || type == "executable" || type == "macro" else {
            return nil
        }
        return target["name"] as? String
    })
    let expectedTargetNames = Set(expectedDependencies.keys)
    let unlistedTargets = productionTargets.subtracting(expectedTargetNames)
    guard unlistedTargets.isEmpty else {
        throw ScopeCheckError.unexpectedTargets(unlistedTargets)
    }

    for targetName in expectedDependencies.keys.sorted() {
        guard let target = targets[targetName] else {
            throw ScopeCheckError.missingTarget(targetName)
        }
        let actual = dependencies(in: target)
        let expected = expectedDependencies[targetName] ?? []
        guard actual == expected else {
            throw ScopeCheckError.unexpectedDependencies(
                target: targetName,
                dependencies: actual,
                expected: expected
            )
        }
    }

    print("PRODUCT_SCOPE_CHECK=PASS (\(expectedDependencies.count) targets)")
    for targetName in expectedDependencies.keys.sorted() {
        let dependencies = expectedDependencies[targetName, default: []].sorted().joined(separator: ", ")
        let displayDependencies = dependencies.isEmpty ? "none" : dependencies
        print("- \(targetName): \(displayDependencies)")
    }
} catch {
    fputs("PRODUCT_SCOPE_CHECK=FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
