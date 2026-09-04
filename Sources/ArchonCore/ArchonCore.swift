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

public enum ArchonPermission: String, Codable, CaseIterable, Sendable {
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

    public var recommendedModelMemoryBytes: UInt64 {
        let budget = min(availableMemoryBytes, UInt64(Double(physicalMemoryBytes) * 0.5))
        return budget > loadedModelMemoryBytes ? budget - loadedModelMemoryBytes : 0
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
            availableMemoryBytes: physicalMemory / 2,
            processorCount: processInfo.activeProcessorCount,
            deviceArchitecture: architecture,
            supportsAppleFoundationModels: supportsAppleModels,
            supportsCoreAI: supportsCoreAI,
            thermalState: thermalState,
            loadedModelMemoryBytes: 0
        )
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
