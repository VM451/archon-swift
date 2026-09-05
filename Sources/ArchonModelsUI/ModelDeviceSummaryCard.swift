//
//  ModelDeviceSummaryCard.swift
//  ArchonModelsUI
//

import SwiftUI
import ArchonCore

/// A compact, accessible header card presenting the host device's hardware identity,
/// operating system version, unified RAM, AI model budget, and thermal status.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
public struct ModelDeviceSummaryCard: View {
    public let device: ArchonDeviceCapabilities

    public init(device: ArchonDeviceCapabilities) {
        self.device = device
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            deviceIcon

            VStack(alignment: .leading, spacing: 3) {
                headerLine
                metricsLine
            }

            Spacer(minLength: 6)

            thermalBadge
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var deviceIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 44, height: 44)

            Image(systemName: iconName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var headerLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(device.deviceDisplayName)
                .font(.headline)
                .foregroundStyle(.primary)

            Text("•")
                .foregroundStyle(.tertiary)

            Text(osDisplay)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    @ViewBuilder
    private var metricsLine: some View {
        HStack(spacing: 6) {
            Label(
                ByteCountFormatter.string(fromByteCount: Int64(device.physicalMemoryBytes), countStyle: .memory) + " RAM",
                systemImage: "memorychip"
            )

            Text("•")
                .foregroundStyle(.tertiary)

            Label(
                ByteCountFormatter.string(fromByteCount: Int64(device.recommendedModelMemoryBytes), countStyle: .memory) + " Budget",
                systemImage: "gauge.with.dots.needle.50percent"
            )
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    @ViewBuilder
    private var thermalBadge: some View {
        let (title, icon, color) = thermalVisuals
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var iconName: String {
        switch device.platform {
        case .iOS: "iphone"
        case .iPadOS: "ipad"
        case .macOS: "laptopcomputer"
        case .visionOS: "visionpro"
        }
    }

    private var osDisplay: String {
        let version = device.osVersion
        if version.major > 0 {
            let verString = version.patch == 0 ? "\(version.major).\(version.minor)" : version.stringValue
            return "\(device.platform.rawValue) \(verString)"
        }
        return device.platform.rawValue
    }

    private var thermalVisuals: (String, String, Color) {
        switch device.thermalState {
        case .nominal:
            return ("Optimal", "bolt.fill", .green)
        case .fair:
            return ("Warm", "thermometer.medium", .yellow)
        case .serious:
            return ("Hot", "thermometer.high", .orange)
        case .critical:
            return ("Throttled", "thermometer.sun.fill", .red)
        case .unknown:
            return ("Ready", "checkmark.circle.fill", .secondary)
        }
    }

    private var accessibilitySummary: String {
        "\(device.deviceDisplayName), \(osDisplay), \(ByteCountFormatter.string(fromByteCount: Int64(device.physicalMemoryBytes), countStyle: .memory)) RAM, \(ByteCountFormatter.string(fromByteCount: Int64(device.recommendedModelMemoryBytes), countStyle: .memory)) AI model memory budget, thermal state \(thermalVisuals.0)."
    }
}
