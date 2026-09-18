import Foundation

/// Host-visible choice between the custom Archon transport and the official
/// MCP Swift SDK adapter. Partial ADAPT: the official
/// `OfficialMCPTransport` is available for SDK-owned wire behavior, while the
/// custom `MCPHTTPTransport` remains the default so existing hosts keep
/// byte-identical behavior unless they explicitly opt in.
public enum MCPTransportChoice: String, Codable, CaseIterable, Sendable {
    case custom
    case officialSDK
}

/// Disclosure describing which transport backs a connection.
public struct MCPTransportDescriptor: Codable, Equatable, Sendable {
    public let choice: MCPTransportChoice
    public let endpoint: URL
    public let requiresExplicitToolAuthorization: Bool
    public let summary: String
    /// Package-provable conformance scope for this transport. The custom
    /// transport stays the default until the official-SDK gates close; see
    /// `conformanceProbe()` for the fake-driven report.
    public let conformanceScope: String

    public init(choice: MCPTransportChoice, endpoint: URL) {
        self.choice = choice
        self.endpoint = endpoint
        self.requiresExplicitToolAuthorization = true
        switch choice {
        case .custom:
            self.summary = "Custom Archon MCP transport. Host-owned JSON-RPC over HTTP; tool calls require explicit host authorization."
            self.conformanceScope = "Package-provable: JSON-RPC schema validation, 1000-item collections, 100-page pagination with cursor-cycle rejection, bounded streams, and typed errors. Full wire interop stays proven through the official-SDK adapter fixtures."
        case .officialSDK:
            self.summary = "Official MCP Swift SDK adapter with Archon policy (explicit tool authorization, pagination and size limits, typed errors). Custom transport remains available."
            self.conformanceScope = "Package-provable: SDK-owned wire behavior plus Archon policy (explicit tool authorization, uniform pagination guard, notification allowlist, bounded teardown, typed errors). Live-server interop remains an open gate."
        }
    }
}

public enum MCPTransportFactory: Sendable {
    /// Fail closed: unknown future choices must not silently map to a
    /// transport. Decoding is constrained to the two known cases by the enum.
    public static func descriptor(
        for choice: MCPTransportChoice,
        endpoint: URL
    ) -> MCPTransportDescriptor {
        MCPTransportDescriptor(choice: choice, endpoint: endpoint)
    }

    /// Builds the custom transport, which never depends on the vendor SDK.
    public static func makeCustomTransport(
        endpoint: URL,
        session: URLSession = .shared,
        headers: [String: String] = [:],
        requestTimeout: TimeInterval? = 60
    ) -> MCPHTTPTransport {
        MCPHTTPTransport(endpoint: endpoint, session: session, headers: headers, requestTimeout: requestTimeout)
    }
}
