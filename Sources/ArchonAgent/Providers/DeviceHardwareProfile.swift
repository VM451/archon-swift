import Foundation
import ArchonCore

#if canImport(Darwin)
import Darwin
#endif

/// Target Apple platform classification supported by the package.
public enum ApplePlatformKind: String, Codable, CaseIterable, Equatable, Sendable {
    case iOS
    case iPadOS
    case macOS
    case visionOS
}

/// Hardware classification tier based on physical unified memory and per-process memory limits.
public enum HardwareMemoryTier: String, Codable, Equatable, Sendable {
    /// Ultra-light tier (< 5 GB physical RAM, e.g. iPhone 11/12/13/14 base with 4GB RAM, entry iPad).
    /// Applies the smallest predicted process envelope and the full reserve policy.
    case ultraLight

    /// Balanced tier (5 GB – 7.9 GB physical RAM, e.g. iPhone 13 Pro, iPhone 14 Pro, iPhone 15 base with 6GB RAM).
    /// Applies the conservative predicted process envelope and reserve policy.
    case balanced

    /// Performance tier (>= 8 GB physical RAM, e.g. iPhone 15 Pro/Max, iPhone 16 series, M-series Macs & iPads).
    /// The actual model budget still depends on current headroom and peak estimate.
    case performance
}

/// Device hardware profiling and process memory budget manager across iOS, iPadOS, macOS, and visionOS.
///
/// On Apple mobile platforms (iOS, iPadOS, and visionOS), the operating system's
/// memory-pressure manager enforces process limits that can be significantly lower
/// than total physical RAM. Apple does not publish one fixed per-app GB limit for
/// all devices; the process-limit values below are conservative app heuristics.
///
/// To prevent Out-Of-Memory (OOM) process termination (`EXC_RESOURCE: MEMORY`), `DeviceHardwareProfile`
/// calculates a **Safe Model Memory Budget** from the predicted process envelope,
/// current headroom, application growth, runtime/framework allocations, loaded
/// models, and a dynamic safety margin.
public struct DeviceHardwareProfile: Sendable, Equatable {
    /// Target Apple platform family (iOS, iPadOS, macOS, or visionOS).
    public let platform: ApplePlatformKind

    /// Total physical RAM installed on device in bytes.
    public let physicalMemoryBytes: UInt64

    /// Total physical RAM in gigabytes (approximate decimal GB).
    public var physicalMemoryGB: Double {
        Double(physicalMemoryBytes) / 1_073_741_824.0
    }

    /// Conservative app estimate of the process memory ceiling in bytes. This is
    /// not an Apple-guaranteed or App-Review-published limit.
    public let appProcessMemoryLimitBytes: UInt64

    /// Estimated process memory limit in gigabytes.
    public var appProcessMemoryLimitGB: Double {
        Double(appProcessMemoryLimitBytes) / 1_073_741_824.0
    }

    /// Current/advisory process headroom in bytes when exposed by the OS.
    public let availableProcessMemoryBytes: UInt64

    /// Safe memory allocation budget ratio reserved for local AI models (default: 0.50 / 50%).
    public let modelMemoryBudgetFraction: Double

    /// Safe maximum predicted peak memory in bytes that a local model is
    /// permitted to allocate after app, runtime, and pressure reserves. This is
    /// a conservative prediction, not Apple's limit.
    public var safeModelMemoryBudgetBytes: UInt64 {
        let envelope = appProcessMemoryLimitBytes
        let applicationReserve = max(
            UInt64(applicationGrowthMinimumGB * 1_073_741_824.0),
            UInt64(Double(physicalMemoryBytes) * applicationGrowthFraction)
        )
        let runtimeReserve = UInt64(runtimeReserveMB * 1_048_576)
        let safetyReserve = max(
            UInt64(safetyReserveMB * 1_048_576),
            UInt64(Double(appProcessMemoryLimitBytes) * safetyFraction)
        )
        let reservedEnvelope = subtract(
            envelope,
            applicationReserve,
            runtimeReserve,
            safetyReserve
        )
        let policyCap = UInt64(Double(appProcessMemoryLimitBytes) * modelMemoryBudgetFraction)
        return min(reservedEnvelope, policyCap)
    }

    /// Safe maximum model budget in megabytes.
    public var safeModelMemoryBudgetMB: Int {
        Int(safeModelMemoryBudgetBytes / (1024 * 1024))
    }

    /// Resolves the model budget used at load time from both the dynamic system
    /// recommendation and this device's conservative process envelope.
    ///
    /// `os_proc_available_memory()` is advisory and can briefly dip while the
    /// app is foregrounding or another framework is releasing memory. Using it
    /// as the only gate can make a model that passed the catalog preflight fail
    /// immediately at load time. The static profile provides a conservative
    /// floor for this fallback; it already reserves application growth, runtime
    /// overhead, and pressure headroom, while a stronger dynamic recommendation
    /// may still be used when the OS reports more headroom.
    public static func effectiveModelMemoryBudgetBytes(
        dynamicRecommendationBytes: UInt64,
        profile: DeviceHardwareProfile
    ) -> UInt64 {
        max(dynamicRecommendationBytes, profile.safeModelMemoryBudgetBytes)
    }

    /// Current conservative model budget for an on-device provider load.
    public static var currentEffectiveModelMemoryBudgetBytes: UInt64 {
        effectiveModelMemoryBudgetBytes(
            dynamicRecommendationBytes: ArchonDeviceCapabilities.current.recommendedModelMemoryBytes,
            profile: current
        )
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

        // Derive a conservative app safety limit if the host has not supplied a
        // measured value. Apple limits are dynamic and device/app-state specific.
        let processLimit: UInt64
        if let explicitLimit = appProcessMemoryLimitBytes {
            processLimit = explicitLimit
        } else {
            switch platform {
            case .macOS:
                // macOS has unified virtual memory: process limit is roughly 75% of physical RAM
                processLimit = UInt64(Double(physicalMemoryBytes) * 0.75)
            case .iOS, .iPadOS, .visionOS:
                // Conservative mobile/visionOS fallback tiers; runtime headroom
                // from ArchonDeviceCapabilities remains the primary gate.
                if gigabytes <= 4.0 {
                    processLimit = UInt64(1.5 * 1024.0 * 1024.0 * 1024.0) // ~1.5 GiB
                } else if gigabytes < 7.0 {
                    processLimit = UInt64(2.25 * 1024.0 * 1024.0 * 1024.0) // ~2.25 GiB
                } else {
                    processLimit = UInt64(3.0 * 1024.0 * 1024.0 * 1024.0) // ~3.0 GiB
                }
            }
        }
        self.appProcessMemoryLimitBytes = processLimit
        self.availableProcessMemoryBytes = availableProcessMemoryBytes ?? processLimit

        if gigabytes < 5.0 {
            self.memoryTier = .ultraLight
        } else if gigabytes < 7.0 {
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
        #elseif os(visionOS)
        detectedPlatform = .visionOS
        #else
        detectedPlatform = .macOS
        #endif

        var availableBytes: UInt64 = memoryBytes / 2
        #if os(iOS) || os(visionOS) || os(tvOS) || os(watchOS)
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

    /// Simulated iPhone 12 / 13 base (4 GB RAM, conservative ~1.5 GiB process envelope).
    public static let iPhone12Base = DeviceHardwareProfile(
        platform: .iOS,
        physicalMemoryBytes: 4 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: 2 * 1024 * 1024 * 1024,
        availableProcessMemoryBytes: UInt64(1.8 * 1024.0 * 1024.0 * 1024.0),
        modelMemoryBudgetFraction: 0.50,
        processorCount: 6,
        isAppleFoundationModelSupported: false
    )

    /// Simulated iPhone 14 Pro / 15 base (6 GB RAM, conservative ~2.25 GiB process envelope).
    public static let iPhone14Pro = DeviceHardwareProfile(
        platform: .iOS,
        physicalMemoryBytes: 6 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: 3 * 1024 * 1024 * 1024,
        availableProcessMemoryBytes: UInt64(2.7 * 1024.0 * 1024.0 * 1024.0),
        modelMemoryBudgetFraction: 0.50,
        processorCount: 6,
        isAppleFoundationModelSupported: false
    )

    /// Simulated iPhone 15 Pro / 16 (8 GB RAM, conservative ~3.0 GiB process envelope).
    public static let iPhone15Pro = DeviceHardwareProfile(
        platform: .iOS,
        physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: UInt64(3.0 * 1024.0 * 1024.0 * 1024.0),
        availableProcessMemoryBytes: UInt64(2.7 * 1024.0 * 1024.0 * 1024.0),
        modelMemoryBudgetFraction: 0.50,
        processorCount: 6,
        isAppleFoundationModelSupported: true
    )

    /// Simulated iPhone 17 Pro-class device (12 GB RAM). This preserves the
    /// conservative mobile process envelope until a consuming app captures
    /// device-specific memory and thermal measurements; physical RAM alone is
    /// not permission to load a larger model.
    public static let iPhone17Pro = DeviceHardwareProfile(
        platform: .iOS,
        physicalMemoryBytes: 12 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: UInt64(3.0 * 1024.0 * 1024.0 * 1024.0),
        availableProcessMemoryBytes: UInt64(2.7 * 1024.0 * 1024.0 * 1024.0),
        modelMemoryBudgetFraction: 0.50,
        processorCount: 6,
        isAppleFoundationModelSupported: true
    )

    // MARK: iPadOS Hardware Profiles

    /// Simulated entry iPad (4 GB RAM, conservative ~1.5 GiB process envelope).
    public static let iPadEntry = DeviceHardwareProfile(
        platform: .iPadOS,
        physicalMemoryBytes: 4 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: 2 * 1024 * 1024 * 1024,
        availableProcessMemoryBytes: UInt64(1.8 * 1024.0 * 1024.0 * 1024.0),
        modelMemoryBudgetFraction: 0.50,
        processorCount: 6,
        isAppleFoundationModelSupported: false
    )

    /// Simulated iPad Air / iPad Pro M2 (8 GB RAM, conservative ~3.0 GiB process envelope).
    public static let iPadProM2 = DeviceHardwareProfile(
        platform: .iPadOS,
        physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
        appProcessMemoryLimitBytes: UInt64(3.0 * 1024.0 * 1024.0 * 1024.0),
        availableProcessMemoryBytes: UInt64(2.7 * 1024.0 * 1024.0 * 1024.0),
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

    private var applicationGrowthFraction: Double {
        switch platform {
        case .iOS, .iPadOS: 0.10
        case .visionOS: 0.12
        case .macOS: 0.10
        }
    }

    private var applicationGrowthMinimumGB: Double {
        switch platform {
        case .iOS, .iPadOS: 0.50
        case .visionOS: 0.75
        case .macOS: 1.0
        }
    }

    private var runtimeReserveMB: Double {
        switch platform {
        case .iOS, .iPadOS: 256
        case .visionOS: 384
        case .macOS: 512
        }
    }

    private var safetyReserveMB: Double {
        switch platform {
        case .iOS, .iPadOS: 256
        case .visionOS: 384
        case .macOS: 512
        }
    }

    private var safetyFraction: Double {
        switch platform {
        case .iOS, .iPadOS: 0.10
        case .visionOS: 0.12
        case .macOS: 0.10
        }
    }

    private func subtract(_ value: UInt64, _ amounts: UInt64...) -> UInt64 {
        amounts.reduce(value) { remaining, amount in
            remaining > amount ? remaining - amount : 0
        }
    }
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
