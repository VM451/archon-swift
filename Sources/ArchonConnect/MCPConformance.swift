import Foundation

/// Package-provable MCP conformance scope, driven by the fake transport only.
///
/// This report never claims live-server interoperability. Cursor-cycle
/// rejection, collection/page bounds, and notification forwarding are proven
/// against `FakeMCPConformanceTransport` (zero network); wire interop against
/// real servers stays proven through the official-SDK adapter fixtures.
public struct MCPConformanceReport: Sendable, Equatable {
    /// A cycling pagination cursor was rejected with `.invalidResponse`.
    public var paginationCursorsCycled: Bool
    /// How many collection/page bound rejections were observed.
    public var collectionBoundHits: Int
    /// Notification methods the fake transport forwarded in order.
    public var notificationsForwarded: [String]

    public init(
        paginationCursorsCycled: Bool = false,
        collectionBoundHits: Int = 0,
        notificationsForwarded: [String] = []
    ) {
        self.paginationCursorsCycled = paginationCursorsCycled
        self.collectionBoundHits = collectionBoundHits
        self.notificationsForwarded = notificationsForwarded
    }
}

/// Uniform cursor-cycle and pagination guard shared by every paginated MCP
/// list operation (tools, resources, prompts). Cycle repeats fail with
/// `.invalidResponse`; page/collection overflows fail with
/// `.collectionTooLarge`.
public struct MCPPaginationGuard: Sendable {
    private var seenCursors: Set<String> = []
    private var pageCount = 0

    public init() {}

    /// Advances one page, enforcing the maximum page count.
    public mutating func checkPage() throws {
        pageCount += 1
        guard pageCount <= MCPTransportLimits.maximumPaginationPages else {
            throw MCPTransportError.collectionTooLarge(
                maximumItems: MCPTransportLimits.maximumCollectionItems
            )
        }
    }

    /// Records a `nextCursor`, rejecting repeats (fail closed: a server that
    /// cycles cursors would otherwise page forever).
    public mutating func checkCursor(_ cursor: String) throws {
        guard seenCursors.insert(cursor).inserted else {
            throw MCPTransportError.invalidResponse
        }
    }

    /// Enforces the maximum collection size on an accumulated result.
    public static func checkCollection(count: Int) throws {
        guard count <= MCPTransportLimits.maximumCollectionItems else {
            throw MCPTransportError.collectionTooLarge(
                maximumItems: MCPTransportLimits.maximumCollectionItems
            )
        }
    }
}

/// Deterministic fake transport backing `conformanceProbe()`. It simulates a
/// cycling cursor, an oversized collection, and forwarded notifications with
/// zero network.
public actor FakeMCPConformanceTransport: MCPTransport {
    public enum Scenario: Sendable {
        case cyclingCursors
        case oversizedCollection
        case notifications
    }

    private let scenario: Scenario
    private var connected = false
    private var authorizedToolNames: Set<String> = []

    public init(scenario: Scenario = .cyclingCursors) {
        self.scenario = scenario
    }

    public func connect() async throws {
        connected = true
    }

    public func disconnect() async {
        connected = false
        authorizedToolNames.removeAll()
    }

    public func listTools() async throws -> [MCPTool] {
        guard connected else { throw MCPTransportError.notConnected }
        switch scenario {
        case .cyclingCursors:
            // Simulate pages whose nextCursor repeats: the shared guard must
            // reject the cycle instead of paging forever.
            var guardState = MCPPaginationGuard()
            try guardState.checkPage()
            try guardState.checkCursor("cursor-loop")
            try guardState.checkPage()
            try guardState.checkCursor("cursor-loop")
            throw MCPTransportError.sdkFailure("Unreachable: the cursor cycle must throw first.")
        case .oversizedCollection:
            try MCPPaginationGuard.checkCollection(
                count: MCPTransportLimits.maximumCollectionItems + 1
            )
            throw MCPTransportError.sdkFailure("Unreachable: the oversized collection must throw first.")
        case .notifications:
            return [MCPTool(name: "fake_probe", description: "Conformance probe tool")]
        }
    }

    public func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        guard connected else { throw MCPTransportError.notConnected }
        guard authorizedToolNames.contains(name) else {
            throw MCPTransportError.unsupported("unauthorized fake tool \(name)")
        }
        return MCPToolResult(content: [.string("fake-ok")])
    }

    public func streamTool(
        name: String,
        arguments: [String: JSONValue]
    ) async -> AsyncThrowingStream<MCPStreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<MCPStreamEvent, Error>.makeStream()
        guard connected else {
            continuation.finish(throwing: MCPTransportError.notConnected)
            return stream
        }
        let forwarded = ["notifications/progress", "notifications/tools/list_changed"]
        for method in forwarded {
            continuation.yield(.notification(method: method, params: nil))
        }
        continuation.yield(.result(MCPToolResult(content: [.string("fake-ok")])))
        continuation.finish()
        return stream
    }

    public func setAuthorizedToolNames(_ names: Set<String>) async {
        authorizedToolNames = names
    }
}

/// Runs the package-provable MCP conformance probe against the fake
/// transport only. No network, no loopback, no live server.
public func conformanceProbe() async -> MCPConformanceReport {
    var report = MCPConformanceReport()

    let cycling = FakeMCPConformanceTransport(scenario: .cyclingCursors)
    try? await cycling.connect()
    do {
        _ = try await cycling.listTools()
    } catch let error as MCPTransportError where error == .invalidResponse {
        report.paginationCursorsCycled = true
    } catch {
        // Any other outcome leaves the flag false (fail closed).
    }

    let oversized = FakeMCPConformanceTransport(scenario: .oversizedCollection)
    try? await oversized.connect()
    do {
        _ = try await oversized.listTools()
    } catch let error as MCPTransportError where error == .collectionTooLarge(
        maximumItems: MCPTransportLimits.maximumCollectionItems
    ) {
        report.collectionBoundHits += 1
    } catch {
        // Fail closed: only the exact bound error counts.
    }

    let notifying = FakeMCPConformanceTransport(scenario: .notifications)
    try? await notifying.connect()
    let events = await notifying.streamTool(name: "fake_probe", arguments: [:])
    do {
        for try await event in events {
            if case .notification(let method, _) = event {
                report.notificationsForwarded.append(method)
            }
        }
    } catch {
        // A failed stream yields no forwarded methods.
    }
    return report
}
