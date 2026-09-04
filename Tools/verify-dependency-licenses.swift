import Darwin
import Foundation

private struct ResolvedPackage: Decodable {
    let identity: String
    let location: String
    let state: State

    struct State: Decodable {
        let version: String?
        let revision: String?
    }
}

private struct ResolvedFile: Decodable {
    let pins: [ResolvedPackage]
}

private enum LicenseCheckError: LocalizedError {
    case missingResolvedFile(URL)
    case invalidCheckout(String)

    var errorDescription: String? {
        switch self {
        case let .missingResolvedFile(url):
            return "Package.resolved was not found at \(url.path). Resolve dependencies before running the license check."
        case let .invalidCheckout(message):
            return message
        }
    }
}

let fileManager = FileManager.default
let rootURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let resolvedURL = rootURL.appendingPathComponent("Package.resolved")
let checkoutRoot = rootURL.appendingPathComponent(".build/checkouts", isDirectory: true)
let directIdentities: Set<String> = [
    "swift-syntax",
    "mlx-swift",
    "mlx-swift-lm",
    "swift-huggingface",
    "swift-transformers",
    "swift-sdk",
    "grdb.swift",
    "proximakit",
    "swift-argument-parser"
]

func checkoutURL(for identity: String) throws -> URL {
    guard let match = try fileManager.contentsOfDirectory(
        at: checkoutRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ).first(where: { $0.lastPathComponent.caseInsensitiveCompare(identity) == .orderedSame }) else {
        throw LicenseCheckError.invalidCheckout("Resolved package \(identity) has no checkout under \(checkoutRoot.path).")
    }
    return match
}

func licenseFiles(in checkoutURL: URL) -> [String] {
    guard let enumerator = fileManager.enumerator(
        at: checkoutURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var result: [String] = []
    for case let fileURL as URL in enumerator {
        let relativeDepth = fileURL.pathComponents.count - checkoutURL.pathComponents.count
        guard relativeDepth <= 2,
              (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            continue
        }

        let name = fileURL.lastPathComponent.lowercased()
        if name.hasPrefix("license") || name.hasPrefix("copying") || name.hasPrefix("notice") {
            result.append(fileURL.path.replacingOccurrences(of: checkoutURL.path + "/", with: ""))
        }
    }
    return result.sorted()
}

do {
    guard fileManager.fileExists(atPath: resolvedURL.path) else {
        throw LicenseCheckError.missingResolvedFile(resolvedURL)
    }

    let data = try Data(contentsOf: resolvedURL)
    let resolved = try JSONDecoder().decode(ResolvedFile.self, from: data)
    let packages = try resolved.pins.sorted { $0.identity < $1.identity }.map { package -> (ResolvedPackage, [String]) in
        let files = licenseFiles(in: try checkoutURL(for: package.identity))
        guard !files.isEmpty else {
            throw LicenseCheckError.invalidCheckout("Resolved package \(package.identity) has no license, copying, or notice file within two directory levels.")
        }
        return (package, files)
    }

    print("# Resolved dependency license check")
    print("# Package.resolved: \(resolvedURL.path)")
    print("| Identity | Revision/version | Scope | Evidence files |")
    print("| --- | --- | --- | --- |")
    for (package, files) in packages {
        let revision = package.state.version ?? package.state.revision ?? "unknown"
        let scope = directIdentities.contains(package.identity) ? "direct" : "transitive"
        print("| `\(package.identity)` | `\(revision)` | \(scope) | \(files.joined(separator: ", ")) |")
    }
    print("LICENSE_CHECK=PASS (\(packages.count) resolved packages)")
} catch {
    fputs("LICENSE_CHECK=FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
