import Foundation

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
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host == "::1" {
            return false
        }
        if host.hasPrefix("127.") || host == "0.0.0.0" || host == "::" || host.hasPrefix("169.254.") || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return false
        }
        // Reject alternate numeric and IPv4-mapped IPv6 spellings that do not
        // survive the simple dotted-decimal checks below.
        // Avoid incomplete textual IPv6 classification; reject literals at
        // this boundary and leave hostname resolution to the host networking
        // layer, where resolved-address policy can be enforced atomically.
        if host.contains(":") {
            return false
        }
        if host.split(separator: ".").count == 1, Int(host) != nil {
            return false
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) {
                return false
            }
        }
        return true
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
