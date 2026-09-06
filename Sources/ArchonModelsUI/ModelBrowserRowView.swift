//
//  ModelBrowserRowView.swift
//  ArchonModelsUI
//

import SwiftUI
import ArchonCore
import ArchonModels

/// A dedicated, accessible row view for model catalog browsing.
///
/// Presents model metadata, publisher, variant details, compatibility badges,
/// download progress/actions, and seamless navigation to `ModelDetailView`.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct ModelBrowserRowView: View {
    let model: ModelDescriptor
    let variant: ModelVariant
    let compatibility: ModelCompatibility
    let device: ArchonDeviceCapabilities
    let phase: DownloadPhase?
    let progress: Double?
    let statusMessage: String?
    let isInstalled: Bool
    let library: ModelLibrary
    let downloadManager: ModelDownloadManager

    let onDownload: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRedownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationLink {
                ModelDetailView(
                    model: model,
                    device: device,
                    library: library,
                    downloadManager: downloadManager
                )
            } label: {
                EmptyView()
            }
            .opacity(0)

            HStack(alignment: .center, spacing: 12) {
                ModelLogoView(model: model)

                VStack(alignment: .leading, spacing: 3) {
                    metadataHeader

                    Text(displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .minimumScaleFactor(0.85)

                    fitBadge
                        .padding(.top, 1)

                    if let progressValue = progress, phase == .downloading {
                        ProgressView(value: progressValue)
                            .progressViewStyle(.linear)
                            .padding(.top, 2)
                    } else if let message = statusMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                actionControl
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var metadataHeader: some View {
        HStack(spacing: 4) {
            Text(displayPublisher)
                .fontWeight(.semibold)
                .lineLimit(1)

            Text("•")
                .foregroundStyle(.tertiary)

            Text(variant.runtime.displayName)
                .lineLimit(1)

            if let quantization = variant.quantization ?? variant.precision {
                Text("•")
                    .foregroundStyle(.tertiary)
                Text(quantization)
                    .lineLimit(1)
            }

            if let size = variant.sizeBytes {
                Text("•")
                    .foregroundStyle(.tertiary)
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .lineLimit(1)
            }

            Text("•")
                .foregroundStyle(.tertiary)
            Text(releaseAgeText)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .minimumScaleFactor(0.85)
    }

    private var releaseAgeText: String {
        guard let releaseDate = model.releaseDate else { return "Release age unavailable" }
        let days = max(0, Calendar.current.dateComponents([.day], from: releaseDate, to: Date()).day ?? 0)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    private var displayTitle: String {
        let trimmedName = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? variant.name : trimmedName
    }

    private var displayPublisher: String {
        if model.publisher == "Google DeepMind" {
            return "Google"
        }
        return model.publisher
    }

    @ViewBuilder
    private var fitBadge: some View {
        let (icon, color) = fitVisuals(for: compatibility)
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(fitBadgeText)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fitAccessibilityLabel)
    }

    private var fitBadgeText: String {
        switch compatibility.status {
        case .insufficientMemory:
            if let peakBytes = ModelCompatibilityAnalyzer.estimatedPeakMemoryBytes(for: variant) {
                return "Needs \(ByteCountFormatter.string(fromByteCount: Int64(peakBytes), countStyle: .memory)) RAM"
            } else if let declaredBytes = variant.estimatedMemoryBytes, declaredBytes > 0 {
                return "Needs \(ByteCountFormatter.string(fromByteCount: declaredBytes, countStyle: .memory)) RAM"
            }
            return "Needs more RAM"
        case .macOSOnly:
            return "Mac only"
        case .requiresNewerOS:
            if let minOS = variant.minimumOS {
                return "Requires OS \(minOS.major)+"
            }
            return "Requires newer OS"
        case .unsupportedArchitecture:
            return "Unsupported chip"
        case .unsupportedOnDevice:
            return "Device unsupported"
        case .conversionRequired:
            return "Needs conversion"
        case .requiresAuthentication:
            return "Auth required"
        case .thermalConstrained:
            return "Device too hot"
        case .experimental:
            return "Experimental"
        case .memoryEstimateUnavailable:
            return "Needs memory spec"
        case .unsupportedFormat:
            return "Unsupported format"
        default:
            return compatibility.fit.displayName
        }
    }

    private var fitAccessibilityLabel: String {
        switch compatibility.status {
        case .insufficientMemory:
            let needed: String
            if let peakBytes = ModelCompatibilityAnalyzer.estimatedPeakMemoryBytes(for: variant) {
                needed = ByteCountFormatter.string(fromByteCount: Int64(peakBytes), countStyle: .memory)
            } else if let declaredBytes = variant.estimatedMemoryBytes, declaredBytes > 0 {
                needed = ByteCountFormatter.string(fromByteCount: declaredBytes, countStyle: .memory)
            } else {
                needed = "additional"
            }
            let budget = ByteCountFormatter.string(fromByteCount: Int64(device.recommendedModelMemoryBytes), countStyle: .memory)
            return "Cannot run: needs \(needed) RAM, device budget is \(budget)"
        default:
            return fitBadgeText
        }
    }

    private func fitVisuals(for compatibility: ModelCompatibility) -> (String, Color) {
        switch compatibility.status {
        case .insufficientMemory:
            return ("memorychip", .secondary)
        case .macOSOnly:
            return ("laptopcomputer", .secondary)
        case .requiresNewerOS:
            return ("arrow.up.circle.fill", .secondary)
        case .thermalConstrained:
            return ("thermometer.sun.fill", .orange)
        case .requiresAuthentication:
            return ("lock.fill", .secondary)
        case .conversionRequired:
            return ("arrow.triangle.2.circlepath", .secondary)
        case .experimental:
            return ("flask.fill", .secondary)
        case .unsupportedArchitecture:
            return ("cpu", .secondary)
        case .unsupportedFormat:
            return ("doc.badge.gearshape", .secondary)
        default:
            return fitVisuals(compatibility.fit)
        }
    }

    private func fitVisuals(_ fit: ModelFitRating) -> (String, Color) {
        switch fit {
        case .excellentFit, .goodFit:
            return ("checkmark.circle.fill", .green)
        case .mayBeSlow, .memoryConstrained:
            return ("exclamationmark.circle.fill", .orange)
        case .notRecommended:
            return ("xmark.circle.fill", .red)
        case .cannotRun:
            return ("slash.circle.fill", .secondary)
        }
    }

    @ViewBuilder
    private var actionControl: some View {
        switch phase {
        case .downloading:
            HStack(spacing: 6) {
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Pause download")

                Button(role: .cancel, action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Cancel download")
            }
        case .paused:
            Button("Resume", action: onResume)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .foregroundStyle(.background)
        case .failed, .cancelled:
            Button("Retry", action: onRetry)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        case .ready:
            readyBadge
        default:
            if isInstalled || variant.source == .appleCoreAI || variant.runtime == .foundationModels {
                readyBadge
            } else if compatibility.canDownload {
                let canDownload = variant.downloadURL != nil || !variant.resources.isEmpty || !variant.tokenizerResources.isEmpty
                Button(action: onDownload) {
                    Text("Download")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.background)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .foregroundStyle(.background)
                .disabled(!canDownload)
            } else {
                Text(compatibility.status == .conversionRequired ? "Convert" : "Unavailable")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var readyBadge: some View {
        if variant.downloadURL != nil {
            Menu {
                Button("Redownload", action: onRedownload)
                if isInstalled {
                    Button("Delete", role: .destructive, action: onDelete)
                }
            } label: {
                installedBadgeLabel(title: "Installed")
            }
            .accessibilityLabel("\(variant.name) installed. Tap for options.")
        } else {
            installedBadgeLabel(title: variant.source == .appleCoreAI ? "System" : "Ready")
                .accessibilityLabel("\(variant.name) \(variant.source == .appleCoreAI ? "system model" : "ready").")
        }
    }

    private func installedBadgeLabel(title: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

private extension ArchonModelRuntime {
    var displayName: String {
        switch self {
        case .coreAI: "Core AI"
        case .foundationModels: "Foundation Models"
        case .mlx: "MLX"
        case .remote: "Remote"
        case .unknown: "Unknown"
        }
    }
}
