#!/usr/bin/env swift

import Foundation

#if canImport(Darwin)
import Darwin
#endif

let scorecardPath = CommandLine.arguments.dropFirst().first
    ?? "Documentation/reference/competitor-comparison.md"

func fail(_ message: String) -> Never {
    print("SCORECARD_CHECK=FAIL: \(message)")
    exit(1)
}

func tableCells(_ line: String) -> [String]? {
    guard line.first == "|" else { return nil }
    let parts = line.split(separator: "|", omittingEmptySubsequences: false)
    guard parts.count >= 3 else { return nil }
    return parts.dropFirst().dropLast().map {
        $0.trimmingCharacters(in: .whitespaces)
    }
}

func numericValue(_ cell: String) -> Double? {
    let cleaned = cell
        .replacingOccurrences(of: "*", with: "")
        .replacingOccurrences(of: "`", with: "")
        .trimmingCharacters(in: .whitespaces)
    return Double(cleaned)
}

func isSeparator(_ cells: [String]) -> Bool {
    cells.allSatisfy { cell in
        let trimmed = cell.trimmingCharacters(in: CharacterSet(charactersIn: " :-"))
        return trimmed.isEmpty
    }
}

func firstIndex(in header: [String], matching predicate: (String) -> Bool) -> Int? {
    header.firstIndex(where: predicate)
}

let fileURL = URL(fileURLWithPath: scorecardPath)
let contents: String
do {
    contents = try String(contentsOf: fileURL, encoding: .utf8)
} catch {
    fail("could not read \(scorecardPath): \(error)")
}

let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
let marketAwareWeights = [0.25, 0.20, 0.20, 0.15, 0.10, 0.10]
let engineeringWeights = [0.2667, 0.2667, 0.20, 0.1333, 0.1333]
var weightedTableCount = 0
var capabilityTableCount = 0
var productNames: [String] = []
var lineIndex = 0

while lineIndex < lines.count {
    guard let header = tableCells(lines[lineIndex]) else {
        lineIndex += 1
        continue
    }

    if let overallIndex = firstIndex(in: header, matching: { $0 == "Overall / 100" || $0 == "Engineering / 100" }) {
        let isEngineeringTable = header[overallIndex] == "Engineering / 100"
        let pullIndex = firstIndex(in: header) { $0.hasPrefix("Pull") || $0.hasPrefix("User pull") }
        let differentiationIndex = firstIndex(in: header) { $0.hasPrefix("Diff.") || $0.hasPrefix("Differentiation") }
        let localIndex = firstIndex(in: header) { $0 == "Local" || $0.hasPrefix("Local feasibility") }
        let qualityIndex = firstIndex(in: header) { $0.hasPrefix("Quality") }
        let maintainabilityIndex = firstIndex(in: header) { $0.hasPrefix("Maintain") }
        let fitIndex = firstIndex(in: header) { $0 == "Fit" || $0.hasPrefix("Strategic fit") }
        let indices: [Int?]
        let weights: [Double]
        if isEngineeringTable {
            indices = [differentiationIndex, localIndex, qualityIndex, maintainabilityIndex, fitIndex]
            weights = engineeringWeights
        } else {
            indices = [pullIndex, differentiationIndex, localIndex, qualityIndex, maintainabilityIndex, fitIndex]
            weights = marketAwareWeights
        }
        guard indices.allSatisfy({ $0 != nil }) else {
            fail("weighted table at line \(lineIndex + 1) is missing a scoring dimension")
        }

        weightedTableCount += 1
        var rowIndex = lineIndex + 2
        while rowIndex < lines.count, let row = tableCells(lines[rowIndex]) {
            if isSeparator(row) {
                rowIndex += 1
                continue
            }
            guard row.count > overallIndex else {
                fail("weighted row at line \(rowIndex + 1) is malformed")
            }
            let scores = indices.compactMap { index in
                numericValue(row[index!])
            }
            guard scores.count == weights.count else {
                fail("weighted row '\(row[0])' has a non-numeric score")
            }
            guard scores.allSatisfy({ $0 >= 0 && $0 <= 5 }) else {
                fail("weighted row '\(row[0])' contains a score outside 0...5")
            }
            let expected = Int((zip(scores, weights).reduce(0.0) { partial, pair in
                partial + pair.0 * pair.1
            } * 20.0).rounded())
            guard let actualValue = numericValue(row[overallIndex]) else {
                fail("weighted row '\(row[0])' has no overall score")
            }
            let actual = Int(actualValue)
            guard actualValue >= 0 && actualValue <= 100 else {
                fail("weighted row '\(row[0])' has an overall score outside 0...100")
            }
            guard expected == actual else {
                fail("weighted score mismatch for '\(row[0])': expected \(expected), got \(actual)")
            }

            if header.first == "Product" {
                productNames.append(row[0].replacingOccurrences(of: "`", with: ""))
            }
            rowIndex += 1
        }
        lineIndex = rowIndex
        continue
    }

    if let averageIndex = firstIndex(in: header, matching: { $0 == "Average / 5" }) {
        capabilityTableCount += 1
        var rowIndex = lineIndex + 2
        while rowIndex < lines.count, let row = tableCells(lines[rowIndex]) {
            if isSeparator(row) {
                rowIndex += 1
                continue
            }
            guard row.count > averageIndex else {
                fail("capability row at line \(rowIndex + 1) is malformed")
            }
            let scores = row[1..<averageIndex].compactMap(numericValue)
            guard !scores.isEmpty, scores.count == averageIndex - 1 else {
                fail("capability row '\(row[0])' has a non-numeric aspect score")
            }
            guard scores.allSatisfy({ $0 >= 0 && $0 <= 5 }) else {
                fail("capability row '\(row[0])' contains a score outside 0...5")
            }
            let expected = (scores.reduce(0.0, +) / Double(scores.count) * 10.0).rounded() / 10.0
            guard let actual = numericValue(row[averageIndex]), actual >= 0, actual <= 5,
                  abs(expected - actual) < 0.001 else {
                fail("capability average mismatch for '\(row[0])'")
            }
            rowIndex += 1
        }
        lineIndex = rowIndex
        continue
    }

    lineIndex += 1
}

let expectedProducts = [
    "ArchonCore", "ArchonModels", "ArchonAgent", "ArchonContext", "ArchonMemory",
    "ArchonMemoryProxima", "ArchonSearch", "ArchonSandbox", "ArchonConnect",
    "ArchonComputerUse", "ArchonModelsUI", "ArchonFull", "archon-model",
    "archon-example-app"
]
guard Set(productNames) == Set(expectedProducts), productNames.count == expectedProducts.count else {
    let missing = Set(expectedProducts).subtracting(productNames)
    let unexpected = Set(productNames).subtracting(expectedProducts)
    fail("product scorecard mismatch; missing: \(missing.sorted()), unexpected: \(unexpected.sorted())")
}

guard weightedTableCount == 7, capabilityTableCount == 6 else {
    fail("expected 7 weighted and 6 capability tables; found \(weightedTableCount) and \(capabilityTableCount)")
}

print("SCORECARD_CHECK=PASS (\(weightedTableCount) weighted tables, \(capabilityTableCount) capability tables, \(productNames.count) products)")
