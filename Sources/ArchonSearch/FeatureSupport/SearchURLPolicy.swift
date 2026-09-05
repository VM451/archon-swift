import Foundation
import ArchonCore

/// Boundary policy for URLs that can be fetched by the search/content tools.
enum SearchURLPolicy {
    static let maxResponseBytes = 8 * 1024 * 1024

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url, SearchURLPolicy.validate(url) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    static func makeSession() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: RedirectDelegate(), delegateQueue: nil)
    }

    static func validate(_ url: URL) -> Bool {
        (try? ArchonNetworkPolicy.publicInternet.validate(url)) != nil
    }

    /// Local files are an explicit on-device capability used by the local-workspace
    /// source. Keep it bounded and refuse symlinked/non-regular files at the boundary.
    static func validateLocalFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let resolved = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0,
              size.int64Value <= Int64(maxResponseBytes) else { return false }
        return true
    }

    static func validateRemoteOrLocalFile(_ url: URL) -> Bool {
        validate(url) || validateLocalFile(url)
    }
}
