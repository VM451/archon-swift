import Foundation
import ArchonCore

#if canImport(Darwin)
import Darwin
#endif

/// Target Apple platform classification.
public enum ApplePlatformKind: String, Codable, CaseIterable, Equatable, Sendable {
    case iOS
    case iPadOS
    case macOS
}

/// Hardware classification tier based on physical unified memory and per-process memory limits.
public enum HardwareMemoryTier: String, Codable, Equatable, Sendable {
    /// Ultra-light tier (< 5 GB physical RAM, e.g. iPhone 11/12/13/14 base with 4GB RAM, entry iPad).
    /// Enforces strict 50% process headroom: LLM budget capped at ~1.0 – 1.4 GB.
    case ultraLight

    /// Balanced tier (5 GB – 7.9 GB physical RAM, e.g. iPhone 13 Pro, iPhone 14 Pro, iPhone 15 base with 6GB RAM).
    /// Enforces 50% process headroom: LLM budget capped at ~1.5 – 2.0 GB.
    case balanced

    /// Performance tier (>= 8 GB physical RAM, e.g. iPhone 15 Pro/Max, iPhone 16 series, M-series Macs & iPads).
    /// LLM budget: >= 3.5 GB.
    case performance
}

/// Device hardware profiling and process memory budget manager across iOS, iPadOS, and macOS.
///
/// On Apple mobile platforms (iOS and iPadOS), the operating system's jetsam memory manager
/// enforces strict per-process memory ceilings that are significantly lower than total physical RAM.
///
/// To prevent Out-Of-Memory (OOM) process termination (`EXC_RESOURCE: MEMORY`), `DeviceHardwareProfile`
/// calculates a **Safe Model Memory Budget** (by default 50% of the app's process memory limit),
/// ensuring the remaining 50% is reserved for application UI, view hierarchies, image caches,
/// checkpointers, and background tasks.
public struct DeviceHardwareProfile: Sendable, Equatable {
    /// Target Apple platform family (iOS, iPadOS, or macOS).
    public let platform: ApplePlatformKind

    /// Total physical RAM installed on device in bytes.
    public let physicalMemoryBytes: UInt64

    /// Total physical RAM in gigabytes (approximate decimal GB).
    public var physicalMemoryGB: Double {
        Double(physicalMemoryBytes) / 1_073_741_824.0
    }

    /// Estimated maximum memory limit (jetsam ceiling) allowed for this app process in bytes.
    public let appProcessMemoryLimitBytes: UInt64

    /// Estimated process memory limit in gigabytes.
    public var appProcessMemoryLimitGB: Double {
        Double(appProcessMemoryLimitBytes) / 1_073_741_824.0
    }

    /// Currently available memory for this process before jetsam termination in bytes.
    public let availableProcessMemoryBytes: UInt64

    /// Safe memory allocation budget ratio reserved for local AI models (default: 0.50 / 50%).
    public let modelMemoryBudgetFraction: Double

    /// Safe maximum memory in bytes that a local model is permitted to allocate.
    public var safeModelMemoryBudgetBytes: UInt64 {
        UInt64(Double(appProcessMemoryLimitBytes) * modelMemoryBudgetFraction)
    }

    /// Safe maximum model budget in megabytes.
    public var safeModelMemoryBudgetMB: Int {
        Int(safeModelMemoryBudgetBytes / (1024 * 1024))
    }

    /// Number of active processor cores.
    public let processorCount: Int

    /// The hardware memory classification tier.
    public let memoryTier: HardwareMemoryTier

    /// Whether Apple Intelligence / Apple Foundation Models are supported and available on this hardware.
    public let isAppleFoundationModelSupported: Bool

    /// Whether the public Apple Core AI runtime is available for custom model assets on this hardware.
    public let isCoreAISupported: Bool

    /// Creates a hardware profile with explicit parameters (ideal for testing, diagnostics, or simulated devices).
    public init(
        platform: ApplePlatformKind = .iOS,
        physicalMemoryBytes: UInt64,
        appProcessMemoryLimitBytes: UInt64? = nil,
        availableProcessMemoryBytes: UInt64? = nil,
        modelMemoryBudgetFraction: Double = 0.50,
        processorCount: Int,
        isAppleFoundationModelSupported: Bool,
        isCoreAISupported: Bool = false
    ) {
        self.platform = platform
        self.physicalMemoryBytes = physicalMemoryBytes
        self.processorCount = processorCount
        self.isAppleFoundationModelSupported = isAppleFoundationModelSupported
        self.isCoreAISupported = isCoreAISupported
        self.modelMemoryBudgetFraction = max(0.10, min(0.90, modelMemoryBudgetFraction))

        let gigabytes = Double(physicalMemoryBytes) / 1_073_741_824.0

        // Derive process limit if not explicitly provided based on platform jetsam curves
        let processLimit: UInt64
        if let explicitLimit = appProcessMemoryLimitBytes {
            processLimit = explicitLimit
        } else {
            switch platform {
            case .macOS:
                // macOS has unified virtual memory: process limit is roughly 75% of physical RAM
                processLimit = UInt64(Double(physicalMemoryBytes) * 0.75)
            case .iOS, .iPadOS:
                // iOS jetsam limits: ~45% of physical memory on 4GB-6GB devices, ~65% on 8GB+ devices
                if gigabytes < 5.0 {
                    processLimit = UInt64(2.0 * 1024.0 * 1024.0 * 1024.0) // ~2.0 GB
                } else if gigabytes < 7.9 {
                    processLimit = UInt64(3.0 * 1024.0 * 1024.0 * 1024.0) // ~3.0 GB
                } else {
                    processLimit = UInt64(5.2 * 1024.0 * 1024.0 * 1024.0) // ~5.2 GB
                }
            }
        }
        self.appProcessMemoryLimitBytes = processLimit
        self.availableProcessMemoryBytes = availableProcessMemoryBytes ?? processLimit

        if gigabytes < 5.0 {
            self.memoryTier = .ultraLight
        } else if gigabytes < 7.9 {
            self.memoryTier = .balanced
        } else {
            self.memoryTier = .performance
        }
    }

    /// Automatically inspects the current host device's hardware, process memory limits, and platform.
    public static var current: DeviceHardwareProfile {
        let processInfo = ProcessInfo.processInfo
        let memoryBytes = processInfo.physicalMemory
        let cores = processInfo.activeProcessorCount
        let appleModelAvailable = AppleFoundationModelProvider.isAvailable

        let detectedPlatform: ApplePlatformKind
        #if os(macOS)
        detectedPlatform = .macOS
        #elseif os(iOS)
        if deviceHardwareIdentifier.lowercased().hasPrefix("ipad") {
            detectedPlatform = .iPadOS
        } else {
            detectedPlatform = .iOS
        }
        #else
        detectedPlatform = .macOS
        #endif

        var availableBytes: UInt64 = memoryBytes / 2
        #if os(iOS) || os(tvOS) || os(watchOS)
        let procAvailable = os_proc_available_memory()
        if procAvailable > 0 {
            availableBytes = UInt64(procAvailable)
        }
        #elseif os(macOS)
        availableBytes = UInt64(Double(memoryBytes) * 0.75)
        #endif

        return DeviceHardwareProfile(
            platform: detectedPlatform,
            physicalMemoryBytes: memoryBytes,
            availableProcessMemoryBytes: availableBytes,
            modelMemoryBudgetFraction: 0.50, // 50% model / 50% host app headroom
            processorCount: cores,
            isAppleFoundationModelSupported: appleModelAvailable,
            isCoreAISupported: ArchonDeviceCapabilities.current.supportsCoreAI
        )
    }

    // MARK: - Pre-configured Hardware Profile Mocks for Testing & Simulation

    // MARK: iOS Hardware Profiles

    /// Simulated iPhone 12 / 13 base (4 GB RAM, ~2.0 GB process limit, ~1.0 GB 50% model budget).
    public static let iPhone12Base = DeviceHardwareProfile(
        platform: .iOS,
        physicalMemoryBytes: 4 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: 2 * 1024 * 1024 * 1024,
        availableProcessMemoryBytes: UInt64(1.8 * 1024.0 * 1024.0 * 1024.0),
        modelMemoryBudgetFraction: 0.50,
        processorCount: 6,
        isAppleFoundationModelSupported: false
    )

    /// Simulated iPhone 14 Pro / 15 base (6 GB RAM, ~3.0 GB process limit, ~1.5 GB 50% model budget).
    public static let iPhone14Pro = DeviceHardwareProfile(
        platform: .iOS,
        physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: 3 * 1024 * 1024 * 1024,
        availableProcessMemoryBytes: UInt64(2.7 * 1024.0 * 1024.0 * 1024.0),
        modelMemoryBudgetFraction: 0.50,
        processorCount: 6,
        isAppleFoundationModelSupported: false
    )

    /// Simulated iPhone 15 Pro / 16 (8 GB RAM, ~5.2 GB process limit, Apple Foundation Models supported).
    public static let iPhone15Pro = DeviceHardwareProfile(
        platform: .iOS,
        physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: UInt64(5.2 * 1024.0 * 1024.0 * 1024.0),
        availableProcessMemoryBytes: UInt64(4.8 * 1024.0 * 1024.0 * 1024.0),
        modelMemoryBudgetFraction: 0.50,
        processorCount: 6,
        isAppleFoundationModelSupported: true
    )

    // MARK: iPadOS Hardware Profiles

    /// Simulated entry iPad (4 GB RAM, ~2.0 GB process limit, ~1.0 GB 50% model budget).
    public static let iPadEntry = DeviceHardwareProfile(
        platform: .iPadOS,
        physicalMemoryBytes: 4 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: 2 * 1024 * 1024 * 1024,
        availableProcessMemoryBytes: UInt64(1.8 * 1024.0 * 1024.0 * 1024.0),
        modelMemoryBudgetFraction: 0.50,
        processorCount: 6,
        isAppleFoundationModelSupported: false
    )

    /// Simulated iPad Air / iPad Pro M2 (8 GB RAM, ~5.5 GB process limit, Apple Foundation Models supported).
    public static let iPadProM2 = DeviceHardwareProfile(
        platform: .iPadOS,
        physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: UInt64(5.5 * 1024.0 * 1024.0 * 1024.0),
        availableProcessMemoryBytes: UInt64(5.0 * 1024.0 * 1024.0 * 1024.0),
        modelMemoryBudgetFraction: 0.50,
        processorCount: 8,
        isAppleFoundationModelSupported: true
    )

    // MARK: macOS Hardware Profiles

    /// Simulated legacy Intel Mac (16 GB RAM, ~12 GB process limit).
    public static let macIntelLegacy = DeviceHardwareProfile(
        platform: .macOS,
        physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: 12 * 1024 * 1024 * 1024,
        availableProcessMemoryBytes: 10 * 1024 * 1024 * 1024,
        modelMemoryBudgetFraction: 0.50,
        processorCount: 8,
        isAppleFoundationModelSupported: false
    )

    /// Simulated Mac with Apple Silicon (16 GB RAM, ~12 GB process limit, Apple Foundation Models supported).
    public static let macAppleSilicon = DeviceHardwareProfile(
        platform: .macOS,
        physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: 12 * 1024 * 1024 * 1024,
        availableProcessMemoryBytes: 10 * 1024 * 1024 * 1024,
        modelMemoryBudgetFraction: 0.50,
        processorCount: 10,
        isAppleFoundationModelSupported: true
    )
}

private var deviceHardwareIdentifier: String {
    if let simulatorIdentifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
        return simulatorIdentifier
    }

    #if canImport(Darwin)
    var systemInfo = utsname()
    guard uname(&systemInfo) == 0 else { return "" }
    let machine = systemInfo.machine
    let machineSize = MemoryLayout.size(ofValue: machine)
    return withUnsafePointer(to: machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: machineSize) {
            String(cString: $0)
        }
    }
    #else
    return ""
    #endif
}
