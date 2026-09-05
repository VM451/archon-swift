import Foundation

/// Describes the isolation boundary used by a sandbox executor.
///
/// In-process WebKit is useful for local mini-apps, but it is not equivalent to
/// a process, container, or microVM. Keeping this value explicit prevents a
/// local WebKit adapter from making stronger isolation claims than it can prove.
public enum IsolationLevel: String, Codable, Hashable, Sendable {
    case inProcessWebKit
    case localProcess
    case remoteContainer
    case remoteMicroVM
}

/// A bounded script request for an execution provider.
public struct SandboxExecutionRequest: Codable, Hashable, Sendable {
    public let script: String
    public let timeout: TimeInterval?

    public init(script: String, timeout: TimeInterval? = nil) {
        self.script = script
        self.timeout = timeout
    }
}

public struct SandboxResourceUsage: Codable, Hashable, Sendable {
    public let duration: TimeInterval
    public let outputBytes: Int

    public init(duration: TimeInterval, outputBytes: Int) {
        self.duration = max(0, duration)
        self.outputBytes = max(0, outputBytes)
    }
}

/// Provider-neutral execution result with an explicit isolation declaration.
public struct SandboxExecutionResult: Codable, Hashable, Sendable {
    public let output: String
    public let isolationLevel: IsolationLevel
    public let networkAccessPermitted: Bool
    public let duration: TimeInterval
    public let resourceUsage: SandboxResourceUsage

    public init(
        output: String,
        isolationLevel: IsolationLevel,
        networkAccessPermitted: Bool,
        duration: TimeInterval,
        resourceUsage: SandboxResourceUsage? = nil
    ) {
        self.output = output
        self.isolationLevel = isolationLevel
        self.networkAccessPermitted = networkAccessPermitted
        self.duration = duration
        self.resourceUsage = resourceUsage ?? SandboxResourceUsage(
            duration: duration,
            outputBytes: output.utf8.count
        )
    }
}

/// Archon-owned execution contract for local WebKit and optional remote
/// container/microVM adapters. Remote implementations must disclose their
/// network dependence and must not be presented as local execution.
public protocol SandboxExecutionProvider: Sendable {
    var isolationLevel: IsolationLevel { get }
    var isNetworkDependent: Bool { get }
    func execute(_ request: SandboxExecutionRequest) async throws -> SandboxExecutionResult
}

/// Executes JavaScript in an already-bound `SandboxEngine`.
public actor InProcessWebKitExecutionProvider: SandboxExecutionProvider {
    public nonisolated let isolationLevel: IsolationLevel = .inProcessWebKit
    public nonisolated let isNetworkDependent = false

    private let engine: SandboxEngine

    public init(engine: SandboxEngine) {
        self.engine = engine
    }

    public func execute(_ request: SandboxExecutionRequest) async throws -> SandboxExecutionResult {
        try Task.checkCancellation()
        guard !request.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SandboxError.invalidExecutionRequest("Script must not be empty.")
        }
        if let timeout = request.timeout, timeout <= 0 {
            throw SandboxError.invalidExecutionRequest("Timeout must be greater than zero.")
        }

        let start = ContinuousClock.now
        let output: String
        if let timeout = request.timeout {
            output = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await self.engine.evaluateScript(request.script)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw SandboxError.timeout("script execution")
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw SandboxError.executionFailed("Execution completed without a result.")
                }
                return first
            }
        } else {
            output = try await engine.evaluateScript(request.script)
        }
        try Task.checkCancellation()

        let duration = start.duration(to: .now)
        return SandboxExecutionResult(
            output: output,
            isolationLevel: isolationLevel,
            networkAccessPermitted: engine.configuration.allows(.network),
            duration: duration.timeInterval
        )
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
