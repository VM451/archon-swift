import Foundation

/// A host-owned workspace root advertised to MCP servers.
///
/// Filesystem access stays in the consuming application boundary.
/// The host supplies only URIs it has already resolved and is willing to
/// expose; Archon never discovers, broadens, or persists them. Per the MCP
/// roots specification, URIs use the `file://` scheme.
public struct MCPHostRoot: Codable, Equatable, Sendable, Identifiable {
    public var id: String { uri }
    public var uri: String
    public var name: String?

    public init(uri: String, name: String? = nil) {
        self.uri = uri
        self.name = name
    }
}

/// Role of one sampling conversation turn.
public enum MCPSamplingRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

/// One content block inside a sampling request.
///
/// This mirrors the MCP sampling content model without exposing vendor types.
/// Binary payloads (`image`, `audio`, embedded-resource `blob`) stay base64
/// strings exactly as they arrive on the wire.
public enum MCPSamplingContent: Equatable, Sendable {
    case text(String)
    case image(data: String, mimeType: String)
    case audio(data: String, mimeType: String)
    case toolUse(id: String, name: String, input: [String: JSONValue])
    indirect case toolResult(
        toolUseId: String,
        blocks: [MCPSamplingContent],
        structured: [String: JSONValue]?,
        isError: Bool
    )
    case embeddedResource(uri: String, mimeType: String?, text: String?, blob: String?)
    case resourceLink(uri: String, name: String, mimeType: String?)
}

/// A server-initiated sampling request asking the host to run an LLM completion.
///
/// The host owns model selection and inference (on-device or its own
/// providers); Archon only translates the wire shape. `includeContext` carries
/// the raw `none` / `thisServer` / `allServers` value so new spec values pass
/// through instead of failing the request.
public struct MCPSamplingRequest: Equatable, Sendable {
    public struct Message: Equatable, Sendable {
        public var role: MCPSamplingRole
        public var content: [MCPSamplingContent]

        public init(role: MCPSamplingRole, content: [MCPSamplingContent]) {
            self.role = role
            self.content = content
        }
    }

    public var messages: [Message]
    public var systemPrompt: String?
    public var maxTokens: Int
    public var temperature: Double?
    public var stopSequences: [String]?
    public var modelHints: [String]
    public var includeContext: String?

    public init(
        messages: [Message],
        systemPrompt: String? = nil,
        maxTokens: Int,
        temperature: Double? = nil,
        stopSequences: [String]? = nil,
        modelHints: [String] = [],
        includeContext: String? = nil
    ) {
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stopSequences = stopSequences
        self.modelHints = modelHints
        self.includeContext = includeContext
    }
}

/// A host-produced sampling completion.
///
/// Text-only by design: multi-turn tool-use loops stay host-side, and the
/// stricter shape keeps the wire result constructible without vendor types.
public struct MCPSamplingResponse: Equatable, Sendable {
    public var model: String
    public var text: String
    /// Raw stop reason (`endTurn`, `maxTokens`, `stopSequence`, `toolUse`,
    /// or any provider-specific value). `nil` omits the field.
    public var stopReason: String?

    public init(model: String, text: String, stopReason: String? = nil) {
        self.model = model
        self.text = text
        self.stopReason = stopReason
    }
}

/// A server-initiated elicitation request asking the host to collect user input.
///
/// Form mode carries a JSON Schema fragment (`properties` / `required`); URL
/// mode carries an out-of-band review URL. Rendering UI and opening URLs stay
/// in the consuming application boundary.
public struct MCPElicitationRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case form(properties: [String: JSONValue], required: [String])
        case url(url: String, elicitationId: String)
    }

    public var message: String
    /// Raw `form` / `url` mode. `nil` means the server left the default.
    public var mode: String?
    public var kind: Kind

    public init(message: String, mode: String? = nil, kind: Kind) {
        self.message = message
        self.mode = mode
        self.kind = kind
    }
}

/// A host-produced elicitation outcome.
///
/// `content` is submitted only with `.accept`; it is ignored for `.decline`
/// and `.cancel`, matching the MCP elicitation result contract.
public struct MCPElicitationResponse: Equatable, Sendable {
    public enum Action: String, Equatable, Sendable {
        case accept
        case decline
        case cancel
    }

    public var action: Action
    public var content: [String: JSONValue]?

    public init(action: Action, content: [String: JSONValue]? = nil) {
        self.action = action
        self.content = content
    }
}

/// Host-provided MCP client capabilities: roots, sampling, and elicitation.
///
/// Each capability is an independent opt-in closure; unset capabilities are
/// never advertised to the server. Install with
/// `MCPTransport.setHostedCapabilities(_:)` before `connect()` so the
/// initialize handshake advertises exactly what the host implements.
public struct MCPHostedCapabilities: Sendable {
    public var roots: (@Sendable () async throws -> [MCPHostRoot])?
    public var sampling: (@Sendable (MCPSamplingRequest) async throws -> MCPSamplingResponse)?
    public var elicitation: (@Sendable (MCPElicitationRequest) async throws -> MCPElicitationResponse)?

    public init(
        roots: (@Sendable () async throws -> [MCPHostRoot])? = nil,
        sampling: (@Sendable (MCPSamplingRequest) async throws -> MCPSamplingResponse)? = nil,
        elicitation: (@Sendable (MCPElicitationRequest) async throws -> MCPElicitationResponse)? = nil
    ) {
        self.roots = roots
        self.sampling = sampling
        self.elicitation = elicitation
    }

    /// True when no capability is installed. Empty capabilities advertise
    /// nothing and preserve the historical client behavior exactly.
    public var isEmpty: Bool {
        roots == nil && sampling == nil && elicitation == nil
    }
}
