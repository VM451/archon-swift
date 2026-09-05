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
                modelIcon
                    .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(model.publisher)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let size = variant.sizeBytes {
                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text(variant.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        fitBadge

                        Text(variant.runtime.displayName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                    }
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
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var modelIcon: some View {
        let (iconName, tintColor) = iconAndTint(for: model)
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(tintColor.opacity(0.12))
                .frame(width: 44, height: 44)

            Image(systemName: iconName)
                .font(.system(size: 20))
                .foregroundStyle(tintColor)
        }
        .accessibilityHidden(true)
    }

    private func iconAndTint(for model: ModelDescriptor) -> (String, Color) {
        let nameLower = (model.publisher + " " + model.name).lowercased()
        if nameLower.contains("apple") {
            return ("apple.logo", .primary)
        } else if nameLower.contains("google") || nameLower.contains("gemma") {
            return ("sparkles", .blue)
        } else if nameLower.contains("meta") || nameLower.contains("llama") {
            return ("brain.head.profile", .indigo)
        } else if nameLower.contains("qwen") {
            return ("cpu", .purple)
        } else if nameLower.contains("mistral") {
            return ("wind", .orange)
        } else {
            return ("cpu", .secondary)
        }
    }

    @ViewBuilder
    private var fitBadge: some View {
        let (icon, color) = fitVisuals(compatibility.fit)
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(compatibility.fit.displayName)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
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
        case .failed, .cancelled:
            Button("Retry", action: onRetry)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        case .ready:
            readyBadge
        default:
            if isInstalled {
                readyBadge
            } else if compatibility.canLoad {
                let canDownload = variant.downloadURL != nil || !variant.resources.isEmpty || !variant.tokenizerResources.isEmpty
                Button(action: onDownload) {
                    Text("Download")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
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
        Menu {
            Button("Redownload", action: onRedownload)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                Text("Installed")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
        .accessibilityLabel("\(variant.name) installed. Tap for options.")
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
