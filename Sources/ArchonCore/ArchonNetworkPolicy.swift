import Foundation
import Darwin

/// Shared policy for SDK-owned public-network requests.
///
/// URL syntax alone cannot prove where a hostname resolves. Hosts that need
/// SSRF-grade enforcement should resolve the hostname and pass every resolved
/// address to `validateResolvedAddresses` immediately before opening the
/// connection, or use an equivalent platform networking boundary.
public struct ArchonNetworkPolicy: Sendable, Equatable {
    public let allowsHTTP: Bool
    public let allowsLocalNetwork: Bool

    public init(allowsHTTP: Bool = false, allowsLocalNetwork: Bool = false) {
        self.allowsHTTP = allowsHTTP
        self.allowsLocalNetwork = allowsLocalNetwork
    }

    public static let publicInternet = ArchonNetworkPolicy()
    public static let localDevelopment = ArchonNetworkPolicy(allowsHTTP: true, allowsLocalNetwork: true)

    public func validate(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || (allowsHTTP && scheme == "http"),
              let host = components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty else {
            throw ArchonNetworkPolicyError.invalidURL
        }

        if !allowsLocalNetwork && Self.isPrivateLiteral(host) {
            throw ArchonNetworkPolicyError.privateNetworkAddress
        }
        if !allowsLocalNetwork,
           host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            throw ArchonNetworkPolicyError.privateNetworkAddress
        }
    }

    /// Validates addresses returned by a host resolver. This is intentionally
    /// separate from URL validation because Foundation URLSession may resolve
    /// a hostname again when the request is opened.
    public func validateResolvedAddresses(_ addresses: [String]) throws {
        guard !addresses.isEmpty else { throw ArchonNetworkPolicyError.resolutionFailed }
        guard addresses.allSatisfy(Self.isIPAddress) else {
            throw ArchonNetworkPolicyError.resolutionFailed
        }
        guard allowsLocalNetwork || addresses.allSatisfy({ !Self.isPrivateLiteral($0) }) else {
            throw ArchonNetworkPolicyError.privateNetworkAddress
        }
    }

    private static func isPrivateLiteral(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host.contains(":") {
            return isPrivateIPv6(host)
        }
        if host.split(separator: ".").count == 1, Int(host) != nil {
            return true
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (100, 64...127), (127, _), (169, 254),
             (172, 16...31), (192, 0), (192, 168), (198, 18...19), (198, 51),
             (203, 0), (224...255, _):
            return true
        default:
            return false
        }
    }

    private static func isIPAddress(_ rawAddress: String) -> Bool {
        let address = rawAddress.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if address.contains(":") {
            var parsed = in6_addr()
            return address.withCString { inet_pton(AF_INET6, $0, &parsed) == 1 }
        }
        let octets = address.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets.allSatisfy { (0...255).contains($0) }
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        var parsed = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &parsed) == 1 }) else {
            return true
        }
        let bytes = withUnsafeBytes(of: parsed) { Array($0) }
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) || (bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1) {
            return true
        }
        let first = bytes[0]
        if first == 0xFF || (first & 0xFE) == 0xFC || (first == 0xFE && (bytes[1] & 0xC0) == 0x80) {
            return true
        }
        // IPv4-mapped IPv6 addresses inherit the IPv4 private-address policy.
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            let ipv4 = bytes[12..<16].map(String.init).joined(separator: ".")
            return isPrivateLiteral(ipv4)
        }
        return false
    }
}

public enum ArchonNetworkPolicyError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL
    case privateNetworkAddress
    case resolutionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The URL is not permitted by the active network policy."
        case .privateNetworkAddress: "The URL resolves to a private or local network address."
        case .resolutionFailed: "The hostname could not be resolved to a permitted address."
        }
    }
}
