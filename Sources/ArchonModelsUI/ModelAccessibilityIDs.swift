import Foundation

/// Stable accessibility identifiers for model-management surfaces.
///
/// UI automation and snapshot tests depend on these exact strings; add new
/// identifiers here instead of inlining string literals in views.
public enum ModelAccessibilityIDs {
    public static func browserBenchmark(variantID: String) -> String {
        "archon.models.browser.benchmark.\(variantID)"
    }

    public static func detailBenchmark(variantID: String) -> String {
        "archon.models.detail.benchmark.\(variantID)"
    }

    public static func librarySize(modelID: String) -> String {
        "archon.models.library.size.\(modelID)"
    }

    public static func storageRow(modelID: String) -> String {
        "archon.models.storage.row.\(modelID)"
    }

    public static let storageTemp = "archon.models.storage.temp"
    public static let storageStaging = "archon.models.storage.staging"
}
