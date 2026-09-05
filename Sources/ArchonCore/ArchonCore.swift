import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The small shared foundation used by Archon's independently adoptable modules.
public enum ArchonCore {}

public enum ArchonLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public protocol ArchonLogger: Sendable {
    func log(_ level: ArchonLogLevel, message: String)
}

public struct NoOpArchonLogger: ArchonLogger, Sendable {
    public init() {}

    public func log(_ level: ArchonLogLevel, message: String) {}
}

public enum ArchonPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case network
    case storage
    case clipboard
    case camera
    case microphone
    case location
    case externalURL
}

public struct ArchonCapability: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let description: String

    public init(id: String, description: String) {
        self.id = id
        self.description = description
    }
}

public enum ArchonCapabilityState: String, Codable, CaseIterable, Sendable {
    case available
    case unavailable
    case restricted
    case unsupported
    case degraded
}

/// A host-observed capability and the permissions required to use it.
///
/// The registry describes capability state; it never grants an Apple system
/// permission. Permission prompts and authorization remain owned by the host
/// application.
public struct ArchonCapabilityStatus: Codable, Equatable, Sendable {
    public let capability: ArchonCapability
    public let state: ArchonCapabilityState
    public let requiredPermissions: Set<ArchonPermission>
    public let reason: String?
    public let observedAt: Date

    public init(
        capability: ArchonCapability,
        state: ArchonCapabilityState,
        requiredPermissions: Set<ArchonPermission> = [],
        reason: String? = nil,
        observedAt: Date = Date()
    ) {
        self.capability = capability
        self.state = state
        self.requiredPermissions = requiredPermissions
        self.reason = reason
        self.observedAt = observedAt
    }

    public var isAvailable: Bool { state == .available }
}

public enum ArchonCapabilityError: Error, LocalizedError, Equatable, Sendable {
    case notRegistered(String)
    case unavailable(id: String, reason: String?)
    case permissionsRequired(id: String, permissions: Set<ArchonPermission>)

    public var errorDescription: String? {
        switch self {
        case .notRegistered(let id):
            return "Archon capability is not registered: \(id)"
        case .unavailable(let id, let reason):
            if let reason {
                return "Archon capability is unavailable: \(id). \(reason)"
            } else {
                return "Archon capability is unavailable: \(id)"
            }
        case .permissionsRequired(let id, let permissions):
            let values = permissions.map(\.rawValue).sorted().joined(separator: ", ")
            return "Archon capability requires permission before use: \(id) [\(values)]"
        }
    }
}

/// A structured, privacy-safe event emitted at an Archon subsystem boundary.
///
/// Events contain identifiers and redacted metadata only. Secrets, prompts,
/// model contents, and credential values remain the responsibility of the
/// consuming application and must never be placed in `metadata`.
public struct ArchonAuditEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let category: String
    public let action: String
    public let outcome: String
    public let metadata: [String: String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        category: String,
        action: String,
        outcome: String,
        metadata: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.action = action
        self.outcome = outcome
        self.metadata = ArchonRedactor.redact(metadata)
        self.createdAt = createdAt
    }
}

public protocol ArchonAuditSink: Sendable {
    func record(_ event: ArchonAuditEvent) async
}

public actor NoOpArchonAuditSink: ArchonAuditSink {
    public init() {}
    public func record(_ event: ArchonAuditEvent) {}
}

/// Redacts values by key before they cross an Archon audit boundary.
public enum ArchonRedactor {
    private static let sensitiveKeyFragments = [
        "token", "secret", "password", "credential", "authorization", "api-key", "apikey", "cookie"
    ]

    public static func redact(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [:]) { result, entry in
            let key = entry.key.lowercased()
            if sensitiveKeyFragments.contains(where: key.contains) {
                result[entry.key] = "<redacted>"
            } else {
                result[entry.key] = entry.value
            }
        }
    }
}

public enum ArchonNetworkBoundary: String, Codable, CaseIterable, Sendable {
    case local
    case hostApprovedRemote
    case denied
}

/// Actor-isolated capability discovery for local, host-supplied runtime facts.
///
/// This is intentionally a policy boundary rather than a permission manager:
/// callers register facts from Apple frameworks or the host app, then require a
/// capability with the permissions the host has actually granted.
public actor ArchonCapabilityRegistry {
    private var statuses: [String: ArchonCapabilityStatus]

    public init(statuses: [ArchonCapabilityStatus] = []) {
        self.statuses = statuses.reduce(into: [:]) { result, status in
            result[status.capability.id] = status
        }
    }

    public func register(_ status: ArchonCapabilityStatus) {
        statuses[status.capability.id] = status
    }

    public func remove(id: String) {
        statuses.removeValue(forKey: id)
    }

    public func status(for id: String) -> ArchonCapabilityStatus? {
        statuses[id]
    }

    public func allStatuses() -> [ArchonCapabilityStatus] {
        statuses.values.sorted { lhs, rhs in
            lhs.capability.id < rhs.capability.id
        }
    }

    /// Fails closed unless the capability is available and all required host
    /// permissions were explicitly supplied by the caller.
    @discardableResult
    public func require(
        _ id: String,
        grantedPermissions: Set<ArchonPermission> = []
    ) throws -> ArchonCapabilityStatus {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArchonCoreError.invalidIdentifier(id)
        }
        guard let status = statuses[id] else {
            throw ArchonCapabilityError.notRegistered(id)
        }
        guard status.isAvailable else {
            throw ArchonCapabilityError.unavailable(id: id, reason: status.reason)
        }
        let missingPermissions = status.requiredPermissions.subtracting(grantedPermissions)
        guard missingPermissions.isEmpty else {
            throw ArchonCapabilityError.permissionsRequired(id: id, permissions: missingPermissions)
        }
        return status
    }
}

public enum ArchonPlatform: String, Codable, CaseIterable, Hashable, Sendable {
    case iOS
    case iPadOS
    case macOS
    case visionOS
}

public struct ArchonOSVersion: Codable, Comparable, Equatable, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(_ version: OperatingSystemVersion) {
        self.init(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
    }

    public static func < (lhs: ArchonOSVersion, rhs: ArchonOSVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public var stringValue: String { "\(major).\(minor).\(patch)" }
}

public enum ArchonModelRuntime: String, Codable, CaseIterable, Sendable {
    case coreAI
    case foundationModels
    case mlx
    case remote
    case unknown
}

public enum ArchonModelTask: String, Codable, CaseIterable, Hashable, Sendable {
    case textGeneration
    case vision
    case audio
    case embedding
    case imageGeneration
    case classification
    case unknown
}

public enum ArchonThermalState: String, Codable, CaseIterable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

/// Confidence of the process-memory envelope used for local model selection.
public enum ArchonMemoryBudgetConfidence: String, Codable, CaseIterable, Sendable {
    /// The host supplied current process headroom through a public OS API and
    /// the package also applied its conservative platform envelope.
    case observedHeadroom

    /// The host did not expose a process-headroom API, so the package used its
    /// physical-memory/platform prediction and a conservative fallback.
    case platformHeuristic
}

/// A conservative memory envelope for one local model's predicted peak.
///
/// `currentProcessHeadroomBytes` is already after the current app footprint on
/// platforms that expose `os_proc_available_memory()`. The additional reserves
/// account for app growth, runtime/framework allocations, loaded models, and
/// changing system pressure. This is a safety policy and prediction, not an
/// Apple-guaranteed process limit.
public struct ArchonModelMemoryBudget: Codable, Equatable, Sendable {
    public let predictedProcessLimitBytes: UInt64
    public let currentProcessHeadroomBytes: UInt64
    public let applicationGrowthReserveBytes: UInt64
    public let runtimeReserveBytes: UInt64
    public let dynamicSafetyReserveBytes: UInt64
    public let loadedModelMemoryBytes: UInt64
    public let recommendedModelMemoryBytes: UInt64
    public let confidence: ArchonMemoryBudgetConfidence

    public init(
        predictedProcessLimitBytes: UInt64,
        currentProcessHeadroomBytes: UInt64,
        applicationGrowthReserveBytes: UInt64,
        runtimeReserveBytes: UInt64,
        dynamicSafetyReserveBytes: UInt64,
        loadedModelMemoryBytes: UInt64,
        recommendedModelMemoryBytes: UInt64,
        confidence: ArchonMemoryBudgetConfidence
    ) {
        self.predictedProcessLimitBytes = predictedProcessLimitBytes
        self.currentProcessHeadroomBytes = currentProcessHeadroomBytes
        self.applicationGrowthReserveBytes = applicationGrowthReserveBytes
        self.runtimeReserveBytes = runtimeReserveBytes
        self.dynamicSafetyReserveBytes = dynamicSafetyReserveBytes
        self.loadedModelMemoryBytes = loadedModelMemoryBytes
        self.recommendedModelMemoryBytes = recommendedModelMemoryBytes
        self.confidence = confidence
    }

    public var predictedProcessLimitGB: Double {
        Double(predictedProcessLimitBytes) / 1_073_741_824.0
    }

    public var recommendedModelMemoryGB: Double {
        Double(recommendedModelMemoryBytes) / 1_073_741_824.0
    }
}

public struct ArchonModelCapabilities: Codable, Equatable, Sendable {
    public let tasks: Set<ArchonModelTask>
    public let supportsStreaming: Bool
    public let supportsToolCalling: Bool
    public let supportsStructuredOutput: Bool

    public init(
        tasks: Set<ArchonModelTask> = [.textGeneration],
        supportsStreaming: Bool = true,
        supportsToolCalling: Bool = false,
        supportsStructuredOutput: Bool = false
    ) {
        self.tasks = tasks
        self.supportsStreaming = supportsStreaming
        self.supportsToolCalling = supportsToolCalling
        self.supportsStructuredOutput = supportsStructuredOutput
    }
}

public struct ArchonDeviceCapabilities: Codable, Equatable, Sendable {
    public let platform: ArchonPlatform
    public let osVersion: ArchonOSVersion
    public let physicalMemoryBytes: UInt64
    /// Current process memory headroom when the platform exposes it. This is
    /// advisory and can change while the app is running; it is not a published
    /// universal Apple per-process limit.
    public let availableMemoryBytes: UInt64
    public let processorCount: Int
    public let deviceArchitecture: String
    public let supportsAppleFoundationModels: Bool
    public let supportsCoreAI: Bool
    public let thermalState: ArchonThermalState
    /// Memory currently occupied by other loaded model runtimes.
    public let loadedModelMemoryBytes: UInt64

    public init(
        platform: ArchonPlatform,
        osVersion: ArchonOSVersion,
        physicalMemoryBytes: UInt64,
        availableMemoryBytes: UInt64,
        processorCount: Int,
        deviceArchitecture: String,
        supportsAppleFoundationModels: Bool,
        supportsCoreAI: Bool,
        thermalState: ArchonThermalState = .nominal,
        loadedModelMemoryBytes: UInt64 = 0
    ) {
        self.platform = platform
        self.osVersion = osVersion
        self.physicalMemoryBytes = physicalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.processorCount = processorCount
        self.deviceArchitecture = deviceArchitecture
        self.supportsAppleFoundationModels = supportsAppleFoundationModels
        self.supportsCoreAI = supportsCoreAI
        self.thermalState = thermalState
        self.loadedModelMemoryBytes = loadedModelMemoryBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            platform: try container.decode(ArchonPlatform.self, forKey: .platform),
            osVersion: try container.decode(ArchonOSVersion.self, forKey: .osVersion),
            physicalMemoryBytes: try container.decode(UInt64.self, forKey: .physicalMemoryBytes),
            availableMemoryBytes: try container.decode(UInt64.self, forKey: .availableMemoryBytes),
            processorCount: try container.decode(Int.self, forKey: .processorCount),
            deviceArchitecture: try container.decode(String.self, forKey: .deviceArchitecture),
            supportsAppleFoundationModels: try container.decode(Bool.self, forKey: .supportsAppleFoundationModels),
            supportsCoreAI: try container.decode(Bool.self, forKey: .supportsCoreAI),
            thermalState: try container.decodeIfPresent(ArchonThermalState.self, forKey: .thermalState) ?? .nominal,
            loadedModelMemoryBytes: try container.decodeIfPresent(UInt64.self, forKey: .loadedModelMemoryBytes) ?? 0
        )
    }

    private enum CodingKeys: String, CodingKey {
        case platform, osVersion, physicalMemoryBytes, availableMemoryBytes
        case processorCount, deviceArchitecture, supportsAppleFoundationModels
        case supportsCoreAI, thermalState, loadedModelMemoryBytes
    }

    /// Conservative app-owned model budget, not an Apple-guaranteed limit.
    /// Callers should refresh device capabilities before a new load/download.
    public var modelMemoryBudget: ArchonModelMemoryBudget {
        let predictedLimit = archonPredictedProcessMemoryLimit(
            platform: platform,
            physicalMemoryBytes: physicalMemoryBytes
        )
        let currentHeadroom = min(availableMemoryBytes, predictedLimit)
        let applicationReserve = archonApplicationGrowthReserve(
            platform: platform,
            physicalMemoryBytes: physicalMemoryBytes
        )
        let runtimeReserve = archonRuntimeReserve(for: platform)
        let safetyReserve = max(
            archonMinimumSafetyReserve(for: platform),
            UInt64(Double(predictedLimit) * archonSafetyFraction(for: platform))
        )
        let availableAfterReserves = archonSubtract(
            currentHeadroom,
            applicationReserve,
            runtimeReserve,
            safetyReserve,
            loadedModelMemoryBytes
        )
        let confidence: ArchonMemoryBudgetConfidence
        #if canImport(Darwin) && (os(iOS) || os(visionOS))
        confidence = availableMemoryBytes > 0 ? .observedHeadroom : .platformHeuristic
        #else
        confidence = .platformHeuristic
        #endif

        return ArchonModelMemoryBudget(
            predictedProcessLimitBytes: predictedLimit,
            currentProcessHeadroomBytes: currentHeadroom,
            applicationGrowthReserveBytes: applicationReserve,
            runtimeReserveBytes: runtimeReserve,
            dynamicSafetyReserveBytes: safetyReserve,
            loadedModelMemoryBytes: loadedModelMemoryBytes,
            recommendedModelMemoryBytes: availableAfterReserves,
            confidence: confidence
        )
    }

    public var recommendedModelMemoryBytes: UInt64 {
        modelMemoryBudget.recommendedModelMemoryBytes
    }

    public static var current: ArchonDeviceCapabilities {
        let processInfo = ProcessInfo.processInfo
        let physicalMemory = processInfo.physicalMemory
        let platform: ArchonPlatform
        #if os(iOS)
        platform = archonCurrentDeviceIsIPad ? .iPadOS : .iOS
        #elseif os(visionOS)
        platform = .visionOS
        #else
        platform = .macOS
        #endif

        let supportsAppleModels: Bool
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            supportsAppleModels = SystemLanguageModel.default.isAvailable
        } else {
            supportsAppleModels = false
        }
        #else
        supportsAppleModels = false
        #endif
        let supportsCoreAI: Bool
        #if canImport(CoreAI)
        #if arch(arm64)
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            supportsCoreAI = true
        } else {
            supportsCoreAI = false
        }
        #else
        supportsCoreAI = false
        #endif
        #else
        supportsCoreAI = false
        #endif

        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif

        let thermalState: ArchonThermalState
        switch processInfo.thermalState {
        case .nominal: thermalState = .nominal
        case .fair: thermalState = .fair
        case .serious: thermalState = .serious
        case .critical: thermalState = .critical
        @unknown default: thermalState = .unknown
        }

        return ArchonDeviceCapabilities(
            platform: platform,
            osVersion: ArchonOSVersion(processInfo.operatingSystemVersion),
            physicalMemoryBytes: physicalMemory,
            availableMemoryBytes: archonCurrentAvailableMemoryBytes(physicalMemory: physicalMemory),
            processorCount: processInfo.activeProcessorCount,
            deviceArchitecture: architecture,
            supportsAppleFoundationModels: supportsAppleModels,
            supportsCoreAI: supportsCoreAI,
            thermalState: thermalState,
            loadedModelMemoryBytes: 0
        )
    }
}

/// Reads the process-available memory reported by Darwin instead of treating a
/// fixed fraction of physical memory as available. The conservative fraction is
/// retained only for non-Darwin toolchains where no equivalent public API is
/// available.
private func archonCurrentAvailableMemoryBytes(physicalMemory: UInt64) -> UInt64 {
    #if canImport(Darwin) && (os(iOS) || os(visionOS))
    let availableMemory = UInt64(os_proc_available_memory())
    if availableMemory > 0 {
        return min(availableMemory, physicalMemory)
    }
    #endif
    return physicalMemory / 2
}

private func archonPredictedProcessMemoryLimit(
    platform: ArchonPlatform,
    physicalMemoryBytes: UInt64
) -> UInt64 {
    let gibibyte = 1_073_741_824.0
    let physicalGB = Double(physicalMemoryBytes) / gibibyte

    switch platform {
    case .iOS, .iPadOS:
        // Conservative foreground-app envelope based on the device RAM tier.
        // It intentionally stays below the maximums seen in field reports so
        // model selection does not optimize right up to a Jetsam boundary.
        let tierLimitGB: Double
        if physicalGB <= 4.0 {
            tierLimitGB = 1.5
        } else if physicalGB <= 6.0 {
            tierLimitGB = 2.25
        } else if physicalGB <= 8.0 {
            tierLimitGB = 3.0
        } else if physicalGB <= 12.0 {
            tierLimitGB = 4.0
        } else {
            tierLimitGB = 5.0
        }
        return UInt64(min(Double(physicalMemoryBytes) * 0.45, tierLimitGB * gibibyte))
    case .visionOS:
        // visionOS shares the mobile-style pressure/jettison model, with a
        // slightly tighter envelope for compositor and scene resources.
        return UInt64(min(Double(physicalMemoryBytes) * 0.40, 6.0 * gibibyte))
    case .macOS:
        // macOS has no single Jetsam-style app ceiling. Keep a large but
        // bounded envelope and retain at least 2 GiB for the rest of the host.
        let fractionLimit = UInt64(Double(physicalMemoryBytes) * 0.75)
        let hostRoomLimit = physicalMemoryBytes > UInt64(2.0 * gibibyte)
            ? physicalMemoryBytes - UInt64(2.0 * gibibyte)
            : UInt64(Double(physicalMemoryBytes) * 0.50)
        return min(fractionLimit, hostRoomLimit)
    }
}

private func archonApplicationGrowthReserve(
    platform: ArchonPlatform,
    physicalMemoryBytes: UInt64
) -> UInt64 {
    let gibibyte = 1_073_741_824.0
    let minimum: Double
    let fraction: Double
    switch platform {
    case .iOS, .iPadOS:
        minimum = 0.50 * gibibyte
        fraction = 0.10
    case .visionOS:
        minimum = 0.75 * gibibyte
        fraction = 0.12
    case .macOS:
        minimum = 1.0 * gibibyte
        fraction = 0.10
    }
    return max(UInt64(minimum), UInt64(Double(physicalMemoryBytes) * fraction))
}

private func archonRuntimeReserve(for platform: ArchonPlatform) -> UInt64 {
    let megabyte = 1_048_576.0
    switch platform {
    case .iOS, .iPadOS:
        return UInt64(256.0 * megabyte)
    case .visionOS:
        return UInt64(384.0 * megabyte)
    case .macOS:
        return UInt64(512.0 * megabyte)
    }
}

private func archonMinimumSafetyReserve(for platform: ArchonPlatform) -> UInt64 {
    let megabyte = 1_048_576.0
    switch platform {
    case .iOS, .iPadOS:
        return UInt64(256.0 * megabyte)
    case .visionOS:
        return UInt64(384.0 * megabyte)
    case .macOS:
        return UInt64(512.0 * megabyte)
    }
}

private func archonSafetyFraction(for platform: ArchonPlatform) -> Double {
    switch platform {
    case .iOS, .iPadOS:
        return 0.10
    case .visionOS:
        return 0.12
    case .macOS:
        return 0.10
    }
}

private func archonSubtract(_ value: UInt64, _ amounts: UInt64...) -> UInt64 {
    amounts.reduce(value) { remaining, amount in
        remaining > amount ? remaining - amount : 0
    }
}

private var archonCurrentDeviceIsIPad: Bool {
    #if os(iOS)
    if let simulatorIdentifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
        return simulatorIdentifier.lowercased().hasPrefix("ipad")
    }

    #if canImport(Darwin)
    var systemInfo = utsname()
    guard uname(&systemInfo) == 0 else { return false }
    let machine = systemInfo.machine
    let machineSize = MemoryLayout.size(ofValue: machine)
    let identifier = withUnsafePointer(to: machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: machineSize) {
            String(cString: $0)
        }
    }
    return identifier.lowercased().hasPrefix("ipad")
    #else
    return false
    #endif
    #else
    return false
    #endif
}

public enum ArchonCoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidConfiguration(String)
    case unsupportedPlatform(ArchonPlatform)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value): "Invalid Archon identifier: \(value)"
        case .invalidConfiguration(let value): "Invalid Archon configuration: \(value)"
        case .unsupportedPlatform(let platform): "Unsupported platform: \(platform.rawValue)"
        case .cancelled: "The Archon operation was cancelled."
        }
    }
}
