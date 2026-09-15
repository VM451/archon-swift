import Foundation
import Testing
import ArchonContext
import ArchonComputerUse
import ArchonConnect

// MARK: - Shared fakes

private struct FixedContributor: ContextContributor, Sendable {
    let id: String
    let fragment: ContextFragment
    func makeContextFragment() async throws -> ContextFragment { fragment }
}

private struct FailingContributor: ContextContributor, Sendable {
    struct Boom: Error {}
    let id: String
    func makeContextFragment() async throws -> ContextFragment { throw Boom() }
}

private struct NeverContributor: ContextContributor, Sendable {
    let id: String
    func makeContextFragment() async throws -> ContextFragment {
        try await Task.sleep(for: .seconds(60))
        return ContextFragment(source: id, content: "unreachable")
    }
}

private struct FixedObservation: ComputerUseObservationProvider, Sendable {
    let snapshot: SemanticSnapshot
    func captureSnapshot() async throws -> SemanticSnapshot { snapshot }
}

private struct AllowAllPolicy: ComputerUsePermissionPolicy, Sendable {
    func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool { true }
}

private struct ExpiredApprovalPolicy: ComputerUsePermissionPolicy, Sendable {
    func allows(_ risk: ComputerUseRisk, action: SemanticAction) async -> Bool { true }
    func approval(for risk: ComputerUseRisk, action: SemanticAction) async -> ComputerUseApproval? {
        ComputerUseApproval(actionID: action.id, issuedAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 1))
    }
}

private actor FakeMCPTransport: MCPTransport, Sendable {
    var connected = false
    let tools: [MCPTool]
    var calls: [String] = []
    init(tools: [MCPTool]) { self.tools = tools }
    func connect() async throws { connected = true }
    func disconnect() async { connected = false }
    func listTools() async throws -> [MCPTool] { tools }
    func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        calls.append(name)
        return MCPToolResult(content: [.string("ok:\(name)")])
    }
}

private actor MinimalMCPTransport: MCPTransport, Sendable {
    func connect() async throws {}
    func disconnect() async {}
    func listTools() async throws -> [MCPTool] { [] }
    func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        MCPToolResult(content: [.string(name)])
    }
}

private struct AllowAllMCP: MCPPermissionPolicy, Sendable {
    func allows(_ risk: MCPRisk, tool: MCPTool) async -> Bool { true }
}

// MARK: - Context coverage

struct ContextCoverageSuite {
    @Test("Empty builder snapshots to empty text")
    func emptySnapshot() async throws {
        let snapshot = try await ContextBuilder().snapshot()
        #expect(snapshot.fragments.isEmpty)
        #expect(snapshot.assembledText.isEmpty)
    }

    @Test("Register and remove contributors")
    func registerRemove() async throws {
        let builder = ContextBuilder()
        await builder.register(FixedContributor(id: "a", fragment: ContextFragment(id: "a", source: "a", content: "hi")))
        await builder.removeContributor(id: "missing-does-not-throw")
        var snapshot = try await builder.snapshot()
        #expect(snapshot.fragments.count == 1)
        await builder.removeContributor(id: "a")
        snapshot = try await builder.snapshot()
        #expect(snapshot.fragments.isEmpty)
    }

    @Test("Duplicate registration replaces contributor")
    func duplicateReplaces() async throws {
        let builder = ContextBuilder()
        await builder.register(FixedContributor(id: "a", fragment: ContextFragment(id: "a", source: "a", content: "first")))
        await builder.register(FixedContributor(id: "a", fragment: ContextFragment(id: "a", source: "a", content: "second")))
        let snapshot = try await builder.snapshot()
        #expect(snapshot.fragments.count == 1)
        #expect(snapshot.fragments.first?.content == "second")
    }

    @Test("Zero fragment budget yields empty snapshot")
    func zeroFragmentBudget() async throws {
        let builder = ContextBuilder(contributors: [
            FixedContributor(id: "a", fragment: ContextFragment(id: "a", source: "a", content: "hi"))
        ])
        let snapshot = try await builder.snapshot(budget: try ContextBudget(maxFragments: 0))
        #expect(snapshot.fragments.isEmpty)
    }

    @Test("Fragment budget keeps highest priority first")
    func fragmentBudgetPriority() async throws {
        let builder = ContextBuilder(contributors: [
            FixedContributor(id: "low", fragment: ContextFragment(id: "low", source: "low", content: "l", priority: 1)),
            FixedContributor(id: "high", fragment: ContextFragment(id: "high", source: "high", content: "h", priority: 9))
        ])
        let snapshot = try await builder.snapshot(budget: try ContextBudget(maxFragments: 1))
        #expect(snapshot.fragments.map(\.id) == ["high"])
    }

    @Test("Zero token budget truncates everything")
    func zeroTokenBudget() async throws {
        let builder = ContextBuilder(contributors: [
            FixedContributor(id: "a", fragment: ContextFragment(id: "a", source: "a", content: "hello"))
        ])
        let snapshot = try await builder.snapshot(budget: try ContextBudget(maxTokens: 0))
        #expect(snapshot.fragments.isEmpty)
    }

    @Test("Negative fragment budget is rejected")
    func negativeFragmentBudget() {
        #expect(throws: ContextBuilderError.invalidBudget) { try ContextBudget(maxFragments: -2) }
    }

    @Test("Contributor errors propagate")
    func contributorError() async {
        let builder = ContextBuilder(contributors: [FailingContributor(id: "bad")])
        do {
            _ = try await builder.snapshot()
            Issue.record("Expected contributor error.")
        } catch is FailingContributor.Boom {
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("Snapshot assembly is cancelled")
    func snapshotCancellation() async {
        let builder = ContextBuilder(contributors: [NeverContributor(id: "slow")])
        let task = Task { try await builder.snapshot() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation.")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }

    @Test("Estimator is zero for empty text and deterministic")
    func estimatorEdge() {
        let estimator = UTF8ContextTokenEstimator()
        #expect(estimator.estimateTokens("") == 0)
        #expect(estimator.estimateTokens("abcd") == 1)
        #expect(estimator.estimateTokens("abcde") == 2)
    }

    @Test("Fragment decoding applies metadata and trust defaults")
    func fragmentDecodeDefaults() throws {
        let data = Data(#"{"id":"1","source":"s","content":"c","priority":0}"#.utf8)
        let fragment = try JSONDecoder().decode(ContextFragment.self, from: data)
        #expect(fragment.metadata == [:])
        #expect(fragment.trust == .unknown)
        #expect(fragment.provenance == nil)
    }

    @Test("Error descriptions are present")
    func contextErrorDescription() {
        #expect(ContextBuilderError.invalidBudget.errorDescription != nil)
    }
}

// MARK: - Computer-use coverage

struct ComputerUseCoverageSuite {
    @Test("Unknown action throws actionNotFound")
    func unknownAction() async {
        let controller = ComputerUseController(permissionPolicy: AllowAllPolicy())
        do {
            _ = try await controller.execute(actionID: "nope")
            Issue.record("Expected actionNotFound.")
        } catch let error as ComputerUseError {
            #expect(error == .actionNotFound("nope"))
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("Expired approval denies execution")
    func expiredApproval() async {
        let controller = ComputerUseController(permissionPolicy: ExpiredApprovalPolicy())
        await controller.register(SemanticAction(id: "a", description: "d", risk: .read) {
            SemanticActionResult(actionID: "a", succeeded: true)
        })
        do {
            _ = try await controller.execute(actionID: "a")
            Issue.record("Expected permissionDenied.")
        } catch let error as ComputerUseError {
            #expect(error == .permissionDenied("a"))
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("Missing target element is stale")
    func missingTargetElement() async {
        let observation = FixedObservation(snapshot: SemanticSnapshot(screenID: "s", elements: []))
        let controller = ComputerUseController(observationProvider: observation, permissionPolicy: AllowAllPolicy())
        await controller.register(SemanticAction(id: "t", description: "d", risk: .navigate, targetElementID: "ghost") {
            SemanticActionResult(actionID: "t", succeeded: true)
        })
        do {
            _ = try await controller.execute(actionID: "t")
            Issue.record("Expected staleObservation.")
        } catch let error as ComputerUseError {
            #expect(error == .staleObservation("t"))
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("Unsuccessful result fails verification")
    func unsuccessfulResult() async {
        let controller = ComputerUseController(permissionPolicy: AllowAllPolicy())
        await controller.register(SemanticAction(id: "u", description: "d", risk: .read) {
            SemanticActionResult(actionID: "u", succeeded: false)
        })
        do {
            _ = try await controller.execute(actionID: "u")
            Issue.record("Expected verificationFailed.")
        } catch let error as ComputerUseError {
            #expect(error == .verificationFailed("u"))
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("Failing host postcondition fails verification")
    func failingPostcondition() async {
        let controller = ComputerUseController(permissionPolicy: AllowAllPolicy())
        await controller.register(SemanticAction(
            id: "v", description: "d", risk: .read,
            verify: { _, _ in false }
        ) {
            SemanticActionResult(actionID: "v", succeeded: true)
        })
        do {
            _ = try await controller.execute(actionID: "v")
            Issue.record("Expected verificationFailed.")
        } catch let error as ComputerUseError {
            #expect(error == .verificationFailed("v"))
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("Read-only policy allows read but denies sensitive")
    func readOnlyBoundary() async throws {
        let controller = ComputerUseController(permissionPolicy: ReadOnlyComputerUsePolicy())
        await controller.register(SemanticAction(id: "r", description: "d", risk: .read) {
            SemanticActionResult(actionID: "r", succeeded: true)
        })
        await controller.register(SemanticAction(id: "s", description: "d", risk: .sensitive) {
            SemanticActionResult(actionID: "s", succeeded: true)
        })
        let result = try await controller.execute(actionID: "r")
        #expect(result.succeeded)
        do {
            _ = try await controller.execute(actionID: "s")
            Issue.record("Expected denial.")
        } catch let error as ComputerUseError {
            #expect(error == .permissionDenied("s"))
        }
    }

    @Test("Observe without provider is unavailable")
    func observeUnavailable() async {
        let controller = ComputerUseController(permissionPolicy: AllowAllPolicy())
        do {
            _ = try await controller.observe()
            Issue.record("Expected observationUnavailable.")
        } catch let error as ComputerUseError {
            #expect(error == .observationUnavailable)
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("Pause while idle is a no-op; stop then resume recovers")
    func pauseStopResume() async throws {
        let controller = ComputerUseController(permissionPolicy: AllowAllPolicy())
        await controller.pause()
        #expect(await controller.state == .idle)
        await controller.register(SemanticAction(id: "w", description: "d", risk: .read) {
            SemanticActionResult(actionID: "w", succeeded: true)
        })
        await controller.stop()
        #expect(await controller.state == .stopped)
        let result = try await controller.resume(actionID: "w")
        #expect(result.succeeded)
        #expect(await controller.state == .idle)
    }

    @Test("Available actions are sorted; removal works")
    func registrySorted() async {
        let controller = ComputerUseController(permissionPolicy: AllowAllPolicy())
        await controller.register(SemanticAction(id: "b", description: "d", risk: .read) {
            SemanticActionResult(actionID: "b", succeeded: true)
        })
        await controller.register(SemanticAction(id: "a", description: "d", risk: .read) {
            SemanticActionResult(actionID: "a", succeeded: true)
        })
        #expect(await controller.availableActions().map(\.id) == ["a", "b"])
        await controller.removeAction(id: "a")
        #expect(await controller.availableActions().map(\.id) == ["b"])
    }

    @Test("Approval validity is boundary-inclusive")
    func approvalBoundary() {
        let now = Date()
        let approval = ComputerUseApproval(actionID: "x", issuedAt: now, expiresAt: now)
        #expect(approval.isValid(at: now))
        #expect(!approval.isValid(at: now.addingTimeInterval(1)))
    }

    @Test("All error descriptions are present")
    func errorDescriptions() {
        let errors: [ComputerUseError] = [
            .actionNotFound("a"), .permissionDenied("a"), .observationUnavailable,
            .approvalRequired("a"), .staleObservation("a"), .verificationFailed("a"),
            .actionCancelled("a"), .stopped
        ]
        for error in errors { #expect(error.errorDescription != nil) }
    }
}

// MARK: - Connect coverage

struct ConnectCoverageSuite {
    @Test("Client connects and exposes tools")
    func clientConnect() async throws {
        let transport = FakeMCPTransport(tools: [MCPTool(name: "read", risk: .read, trust: .hostApproved)])
        let client = MCPClient(transport: transport, permissionPolicy: AllowAllMCP())
        try await client.connect()
        #expect(await client.tools().map(\.name) == ["read"])
        let result = try await client.callTool(name: "read")
        #expect(result.content == [.string("ok:read")])
    }

    @Test("Unknown tool call fails closed")
    func unknownTool() async throws {
        let transport = FakeMCPTransport(tools: [])
        let client = MCPClient(transport: transport, permissionPolicy: AllowAllMCP())
        try await client.connect()
        do {
            _ = try await client.callTool(name: "ghost")
            Issue.record("Expected failure for unknown tool.")
        } catch {
            #expect(error.localizedDescription.contains("unavailable"))
        }
    }

    @Test("Call before connect fails closed")
    func callBeforeConnect() async throws {
        let transport = FakeMCPTransport(tools: [MCPTool(name: "read")])
        let client = MCPClient(transport: transport, permissionPolicy: AllowAllMCP())
        do {
            _ = try await client.callTool(name: "read")
            Issue.record("Expected failure before connect.")
        } catch {
            #expect(error.localizedDescription.contains("not connected"))
        }
    }

    @Test("Read before connect fails; stream for unknown tool fails")
    func readAndStreamGuards() async throws {
        let transport = FakeMCPTransport(tools: [])
        let client = MCPClient(transport: transport, permissionPolicy: AllowAllMCP())
        do {
            _ = try await client.readResource(uri: "file:///x")
            Issue.record("Expected resource failure.")
        } catch {
            #expect(error.localizedDescription.contains("not connected"))
        }
        do {
            _ = try await client.getPrompt(name: "p")
            Issue.record("Expected prompt failure.")
        } catch {
            #expect(error.localizedDescription.contains("unavailable"))
        }
        let stream = await client.streamTool(name: "ghost")
        do {
            for try await _ in stream {}
            Issue.record("Expected stream failure.")
        } catch {
            #expect(error.localizedDescription.contains("unavailable"))
        }
    }

    @Test("Disconnect clears cached tools")
    func disconnectClears() async throws {
        let transport = FakeMCPTransport(tools: [MCPTool(name: "read")])
        let client = MCPClient(transport: transport, permissionPolicy: AllowAllMCP())
        try await client.connect()
        #expect(await client.tools().count == 1)
        await client.disconnect()
        #expect(await client.tools().isEmpty)
    }

    @Test("Schema rejects missing required field")
    func schemaMissingRequired() {
        let tool = MCPTool(name: "t", inputSchema: [
            "type": .string("object"),
            "properties": .object(["path": .object(["type": .string("string")])]),
            "required": .array([.string("path")])
        ])
        do {
            try tool.validate(arguments: [:])
            Issue.record("Expected invalidArguments.")
        } catch let error as MCPTransportError {
            guard case .invalidArguments = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test("Schema rejects additional properties and bad enum")
    func schemaAdditionalAndEnum() {
        let closed = MCPTool(name: "t", inputSchema: [
            "type": .string("object"),
            "properties": .object(["a": .object(["type": .string("string")])]),
            "additionalProperties": .bool(false)
        ])
        #expect(throws: MCPTransportError.self) { try closed.validate(arguments: ["zzz": .string("v")]) }
        let withEnum = MCPTool(name: "t", inputSchema: [
            "type": .string("object"),
            "properties": .object(["mode": .object(["enum": .array([.string("x"), .string("y")])])])
        ])
        #expect(throws: MCPTransportError.self) { try withEnum.validate(arguments: ["mode": .string("nope")]) }
        do {
            try withEnum.validate(arguments: ["mode": .string("x")])
        } catch {
            Issue.record("Valid enum rejected: \(error)")
        }
    }

    @Test("Schema validates arrays, integers, and nesting")
    func schemaArraysIntegers() throws {
        let tool = MCPTool(name: "t", inputSchema: [
            "type": .string("object"),
            "properties": .object([
                "count": .object(["type": .string("integer")]),
                "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])])
            ])
        ])
        try tool.validate(arguments: ["count": .number(3), "tags": .array([.string("a")])])
        #expect(throws: MCPTransportError.self) { try tool.validate(arguments: ["count": .number(3.5)]) }
        #expect(throws: MCPTransportError.self) { try tool.validate(arguments: ["tags": .array([.number(1)])]) }
    }

    @Test("Transport defaults: empty resources, unsupported reads, one-shot stream")
    func transportDefaults() async throws {
        let transport = MinimalMCPTransport()
        #expect(try await transport.listResources().isEmpty)
        do {
            _ = try await transport.readResource(uri: "file:///x")
            Issue.record("Expected unsupported.")
        } catch let error as MCPTransportError {
            #expect(error == .unsupported("resources/read"))
        }
        do {
            _ = try await transport.listPrompts()
            Issue.record("Expected unsupported prompts.")
        } catch let error as MCPTransportError {
            #expect(error == .unsupported("prompts/list"))
        }
        let stream = await transport.streamTool(name: "s", arguments: [:])
        var count = 0
        for try await event in stream {
            if case .result = event { count += 1 }
        }
        #expect(count == 1)
    }

    @Test("Read-only policy requires host approval")
    func hostApprovalPolicy() async {
        let policy = AllowReadOnlyMCPPolicy()
        let approved = MCPTool(name: "r", risk: .read, trust: .hostApproved)
        let remote = MCPTool(name: "r", risk: .read, trust: .remoteUnverified)
        let destructive = MCPTool(name: "d", risk: .destructive, trust: .hostApproved)
        #expect(await policy.allows(.read, tool: approved))
        #expect(!(await policy.allows(.read, tool: remote)))
        #expect(!(await policy.allows(.destructive, tool: destructive)))
    }

    @Test("JSONValue round-trips through Codable")
    func jsonRoundTrip() throws {
        let value = JSONValue.object(["a": .array([.string("x"), .number(1), .bool(true), .null])])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test("Wire decoding pins remote tools as unverified")
    func wireTrustPinning() throws {
        let data = Data(#"{"name":"evil","risk":"read"}"#.utf8)
        let tool = try JSONDecoder().decode(MCPTool.self, from: data)
        #expect(tool.trust == .remoteUnverified)
        #expect(tool.id == "evil")
        let resource = try JSONDecoder().decode(MCPResource.self, from: Data(#"{"uri":"file:///a"}"#.utf8))
        #expect(resource.id == "file:///a")
        #expect(resource.name == "file:///a")
    }

    @Test("Transport error descriptions are present")
    func transportErrorDescriptions() {
        let errors: [MCPTransportError] = [
            .invalidResponse, .httpFailure(500), .serverError(code: 1, message: "m"),
            .notConnected, .unsupported("op"), .timeout(1),
            .invalidArguments("r"), .responseTooLarge(maximumBytes: 8),
            .collectionTooLarge(maximumItems: 3), .sdkFailure("s")
        ]
        for error in errors { #expect(error.errorDescription != nil) }
    }

    @Test("Prompt and resource content defaults hold")
    func promptResourceDefaults() {
        let prompt = MCPPrompt(name: "p")
        #expect(prompt.id == "p")
        #expect(prompt.arguments.isEmpty)
        let content = MCPResourceContent(uri: "file:///a", text: "hi")
        #expect(content.blob == nil)
        #expect(MCPToolResult(content: []).isError == false)
    }
}
