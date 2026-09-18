import Foundation
import ArchonCore
#if canImport(WebKit)
import WebKit
#endif

/// Thread-safe actor managing the runtime lifecycle, WebKit context, script evaluation, and event stream of a single sandbox instance.
public actor SandboxEngine {
    private var workspace: SandboxWorkspace
    nonisolated public let configuration: SandboxConfiguration
    private let toolAuthorizationPolicy: SandboxToolAuthorizationPolicy
    
    private var registeredTools: [String: any SandboxAgentTool] = [:]
    private var eventContinuation: AsyncStream<SandboxEvent>.Continuation?
    private var auditContinuation: AsyncStream<SandboxAuditRecord>.Continuation?
    private var auditBuffer: [SandboxAuditRecord] = []
    private let maxAuditBufferRecords = 500
    private var outstandingToolCalls = 0
    private let maxOutstandingToolCalls = 32
    private let maxBridgeMessageBytes = 256 * 1024

    /// Real-time stream of all events emitted by the sandbox (console logs, DOM mutations, errors, tool calls).
    nonisolated public let eventStream: AsyncStream<SandboxEvent>

    /// Real-time stream of audited policy decisions (capability checks, WASM
    /// loads). Bounded to the newest records, mirroring `eventStream`.
    nonisolated public let auditStream: AsyncStream<SandboxAuditRecord>
    
    /// Low-level JS evaluation closure provided by the platform view representable / web view.
    private var jsEvaluator: (@MainActor @Sendable (String) async throws -> String)?
    
    public init(workspace: SandboxWorkspace, configuration: SandboxConfiguration = .default) {
        self.workspace = workspace
        self.configuration = configuration
        self.toolAuthorizationPolicy = SandboxToolAuthorizationPolicy(
            allowedToolNames: configuration.allowedSandboxToolNames
        )
        
        var continuation: AsyncStream<SandboxEvent>.Continuation!
        self.eventStream = AsyncStream(bufferingPolicy: .bufferingNewest(500)) { continuation = $0 }
        self.eventContinuation = continuation

        var auditContinuation: AsyncStream<SandboxAuditRecord>.Continuation!
        self.auditStream = AsyncStream(bufferingPolicy: .bufferingNewest(500)) { auditContinuation = $0 }
        self.auditContinuation = auditContinuation

        // Emit initial lifecycle state
        self.eventContinuation?.yield(.lifecycle(.initializing))
    }

    deinit {
        eventContinuation?.finish()
        auditContinuation?.finish()
    }
    
    // MARK: - Workspace Accessors
    
    public func getWorkspace() -> SandboxWorkspace {
        return workspace
    }
    
    public func updateWorkspace(_ newWorkspace: SandboxWorkspace) {
        self.workspace = newWorkspace
        self.eventContinuation?.yield(.lifecycle(.reloading))
    }
    
    public func updateFile(_ file: SandboxFile) {
        let maxWorkspaceBytes = max(1, configuration.maxMemoryMB) * 1_024 * 1_024
        let previousSize = workspace.file(at: file.path)?.sizeInBytes ?? 0
        guard file.sizeInBytes <= maxWorkspaceBytes,
              workspace.totalSizeInBytes - previousSize + file.sizeInBytes <= maxWorkspaceBytes else {
            emitEvent(.uncaughtError(message: "Sandbox workspace quota exceeded.", stackTrace: nil))
            return
        }
        self.workspace.upsertFile(file)
    }
    
    // MARK: - Evaluator Binding
    
    public func bindEvaluator(_ evaluator: @escaping @MainActor @Sendable (String) async throws -> String) {
        self.jsEvaluator = evaluator
        self.eventContinuation?.yield(.lifecycle(.ready))
    }
    
    public func unbindEvaluator() {
        self.jsEvaluator = nil
        self.eventContinuation?.yield(.lifecycle(.terminated))
    }
    
    // MARK: - Tool Registration & Dispatch
    
    public func registerTool(_ tool: any SandboxAgentTool) {
        registeredTools[tool.name] = tool
    }
    
    public func removeTool(named name: String) {
        registeredTools.removeValue(forKey: name)
    }
    
    public func getRegisteredToolNames() -> [String] {
        Array(registeredTools.keys)
    }
    
    public func getTool(named name: String) -> (any SandboxAgentTool)? {
        registeredTools[name]
    }
    
    // MARK: - Native JS Evaluation
    
    /// Evaluates raw JavaScript in the running sandbox context and returns the raw string result.
    public func evaluateScript(_ script: String) async throws -> String {
        guard let evaluator = jsEvaluator else {
            throw SandboxError.engineDeallocated
        }
        return try await evaluator(script)
    }
    
    /// Safely invokes a JavaScript function with JSON arguments.
    public func dispatchFunctionCall(name: String, args: [String]) async throws -> String {
        guard Self.isSafeJavaScriptFunctionPath(name) else {
            throw SandboxError.securityViolation("Function name contains executable JavaScript syntax.")
        }
        let jsonArguments = try args.map { argument -> String in
            guard let data = argument.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let normalizedData = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                  let normalized = String(data: normalizedData, encoding: .utf8) else {
                throw SandboxError.serializationFailed("Function arguments must be valid JSON values.")
            }
            return Self.escapeJavaScriptLineSeparators(in: normalized)
        }
        let joinedArgs = jsonArguments.joined(separator: ", ")
        let script = "\(name)(\(joinedArgs));"
        return try await evaluateScript(script)
    }
    
    // MARK: - DOM & CSS Patching
    
    public func applyCSSPatch(_ css: String) async throws -> String {
        let script = DOMPatcher.generateCSSPatchScript(css: css)
        return try await evaluateScript(script)
    }
    
    public func applyDOMPatch(selector: String, html: String, mode: DOMPatcher.PatchMode = .outerHTML) async throws -> String {
        let script = DOMPatcher.generateSubtreePatchScript(selector: selector, newHTML: html, mode: mode)
        return try await evaluateScript(script)
    }
    
    public func applyJSPatch(_ jsCode: String) async throws -> String {
        let script = DOMPatcher.generateJSPatchScript(jsCode: jsCode)
        return try await evaluateScript(script)
    }
    
    // MARK: - Incoming Bridge IPC Handling
    
    /// Processes messages serialized as JSON string sent from JavaScript `window.SwiftSandboxBridge` or `console` interception.
    public func handleIncomingJSON(_ jsonString: String) async {
        guard jsonString.utf8.count <= maxBridgeMessageBytes else {
            emitEvent(.uncaughtError(message: "Sandbox bridge message exceeds the configured size limit.", stackTrace: nil))
            return
        }
        guard let data = jsonString.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = jsonObject["type"] as? String else {
            return
        }
        
        switch type {
        case "CONSOLE":
            let levelStr = (jsonObject["level"] as? String) ?? "info"
            let level: SandboxEvent.LogLevel
            switch levelStr {
            case "debug": level = .debug
            case "warning", "warn": level = .warning
            case "error": level = .error
            default: level = .info
            }
            let message = (jsonObject["message"] as? String) ?? ""
            emitEvent(.consoleLog(level: level, message: message, timestamp: Date()))
            
        case "UNCAUGHT_ERROR":
            let message = (jsonObject["message"] as? String) ?? "Unknown error"
            let stack = jsonObject["stack"] as? String
            emitEvent(.uncaughtError(message: message, stackTrace: stack))
            
        case "DOM_MUTATION":
            let summary = (jsonObject["summary"] as? String) ?? "DOM mutation observed"
            let selector = jsonObject["targetSelector"] as? String
            emitEvent(.domMutation(summary: summary, targetSelector: selector, timestamp: Date()))
            
        case "TOOL_CALL":
            let id = (jsonObject["id"] as? String) ?? UUID().uuidString
            let toolName = (jsonObject["toolName"] as? String) ?? ""
            let argsObject = jsonObject["arguments"] ?? [:]
            var argsJSON = "{}"
            if let argsData = try? JSONSerialization.data(withJSONObject: argsObject),
               let str = String(data: argsData, encoding: .utf8) {
                argsJSON = str
            }
            
            guard outstandingToolCalls < maxOutstandingToolCalls else {
                emitEvent(.uncaughtError(message: "Sandbox tool-call concurrency limit exceeded.", stackTrace: nil))
                return
            }
            outstandingToolCalls += 1
            emitEvent(.toolCall(id: id, toolName: toolName, argumentsJSON: argsJSON))
            Task {
                await self.executeAndReplyToolCall(id: id, toolName: toolName, argumentsJSON: argsJSON)
            }
            
        case "CUSTOM_MESSAGE":
            let name = (jsonObject["name"] as? String) ?? "Unknown"
            let dataPayload = (jsonObject["payload"] as? String) ?? ""
            emitEvent(.customMessage(name: name, payload: dataPayload))
            
        default:
            break
        }
    }
    
    private func executeAndReplyToolCall(id: String, toolName: String, argumentsJSON: String) async {
        defer { outstandingToolCalls = max(0, outstandingToolCalls - 1) }
        guard let tool = registeredTools[toolName] else {
            let errorMsg = "Tool '\(toolName)' is not registered."
            emitEvent(.uncaughtError(message: errorMsg, stackTrace: nil))
            return
        }

        guard toolAuthorizationPolicy.allows(tool) else {
            let errorMsg = "Tool '\(toolName)' is not authorized for page-originated sandbox calls."
            let safeID = Self.javascriptStringLiteral(id)
            let safeError = Self.javascriptStringLiteral(errorMsg)
            let callbackScript = """
            if (window.__handleAgentResponse) {
                window.__handleAgentResponse(\(safeID), null, \(safeError));
            }
            """
            _ = try? await evaluateScript(callbackScript)
            emitEvent(.uncaughtError(message: errorMsg, stackTrace: nil))
            return
        }
        
        do {
            let resultJSON = try await tool.execute(argumentsJSON: argumentsJSON)
            let safeID = Self.javascriptStringLiteral(id)
            let safeResult = Self.javascriptJSONValue(resultJSON)
            let callbackScript = """
            if (window.__handleAgentResponse) {
                window.__handleAgentResponse(\(safeID), \(safeResult), null);
            }
            """
            _ = try? await evaluateScript(callbackScript)
        } catch {
            let safeID = Self.javascriptStringLiteral(id)
            let safeError = Self.javascriptStringLiteral(error.localizedDescription)
            let callbackScript = """
            if (window.__handleAgentResponse) {
                window.__handleAgentResponse(\(safeID), null, \(safeError));
            }
            """
            _ = try? await evaluateScript(callbackScript)
            emitEvent(.uncaughtError(message: "Tool \(toolName) execution failed: \(error.localizedDescription)", stackTrace: nil))
        }
    }
    
    public func emitEvent(_ event: SandboxEvent) {
        eventContinuation?.yield(event)
    }

    // MARK: - Capability Policy & Audit

    /// Bounded snapshot of audited policy decisions, oldest first.
    public func auditRecords() -> [SandboxAuditRecord] {
        auditBuffer
    }

    public func emitAudit(_ record: SandboxAuditRecord) {
        auditBuffer.append(record)
        if auditBuffer.count > maxAuditBufferRecords {
            auditBuffer.removeFirst(auditBuffer.count - maxAuditBufferRecords)
        }
        auditContinuation?.yield(record)
    }

    /// Evaluates a scoped capability against the configuration and emits both
    /// a `.capabilityDecision` event and a `SandboxAuditRecord`. Fail closed:
    /// expired or mismatched grants deny.
    @discardableResult
    public func checkCapability(
        _ permission: ArchonPermission,
        scope: SandboxScope = .session,
        at date: Date = Date()
    ) -> Bool {
        let allowed = configuration.allows(permission, scope: scope, at: date)
        let event = SandboxEvent.capabilityDecision(
            permission: permission.rawValue,
            scope: Self.scopeLabel(scope),
            allowed: allowed,
            timestamp: date
        )
        emitEvent(event)
        emitAudit(SandboxAuditRecord(
            event: event,
            outcome: allowed ? .allowed : .denied,
            capability: permission,
            recordedAt: date
        ))
        return allowed
    }

    private static func scopeLabel(_ scope: SandboxScope) -> String {
        switch scope {
        case .session: return "session"
        case .workspaceFile(let path): return "file:\(path)"
        case .scheme(let scheme): return "scheme:\(scheme)"
        }
    }

    // MARK: - WASM-in-WebKit

    /// Validates a workspace `.wasm` asset and asks page JavaScript to
    /// instantiate it inside the existing in-process WebKit isolation
    /// (`.inProcessWebKit`, never a VM). The module bytes never leave the
    /// workspace; only a bounded loader script referencing the validated
    /// `sandbox://` path is evaluated.
    public func loadWasmModule(_ module: SandboxWasmModule) async throws {
        try Task.checkCancellation()
        let file: SandboxFile
        do {
            file = try SandboxWasmPolicy.validatedFile(
                for: module,
                in: workspace,
                configuration: configuration
            )
        } catch {
            let event = SandboxEvent.uncaughtError(
                message: "WASM module rejected: \(error.localizedDescription)",
                stackTrace: nil
            )
            emitEvent(event)
            emitAudit(SandboxAuditRecord(
                event: event,
                outcome: .error,
                capability: nil
            ))
            throw error
        }
        let script = """
        (async () => {
          const response = await fetch(\(Self.javascriptStringLiteral("sandbox://app/\(file.path)")));
          const bytes = await response.arrayBuffer();
          return await WebAssembly.compile(bytes).then(() => "wasm-loaded", (error) => { throw new Error(String(error)); });
        })();
        """
        let outcome: SandboxAuditOutcome
        do {
            _ = try await evaluateScript(script)
            outcome = .allowed
        } catch {
            outcome = .error
            let event = SandboxEvent.uncaughtError(
                message: "WASM module load failed: \(error.localizedDescription)",
                stackTrace: nil
            )
            emitEvent(event)
            emitAudit(SandboxAuditRecord(event: event, outcome: outcome, capability: nil))
            throw error
        }
        let event = SandboxEvent.customMessage(name: "wasm-loaded", payload: file.path)
        emitEvent(event)
        emitAudit(SandboxAuditRecord(event: event, outcome: outcome, capability: nil))
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        let encoded = String(data: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        return escapeJavaScriptLineSeparators(in: encoded)
    }

    private static func javascriptJSONValue(_ value: String) -> String {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let normalizedData = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]),
              let normalized = String(data: normalizedData, encoding: .utf8) else {
            return javascriptStringLiteral(value)
        }
        return escapeJavaScriptLineSeparators(in: normalized)
    }

    private static func isSafeJavaScriptFunctionPath(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            guard let first = component.unicodeScalars.first,
                  isIdentifierStart(first) else { return false }
            return component.unicodeScalars.dropFirst().allSatisfy(isIdentifierContinue)
        }
    }

    private static func isIdentifierStart(_ scalar: UnicodeScalar) -> Bool {
        scalar == "_" || scalar == "$" || ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
    }

    private static func isIdentifierContinue(_ scalar: UnicodeScalar) -> Bool {
        isIdentifierStart(scalar) || ("0"..."9").contains(scalar)
    }

    private static func escapeJavaScriptLineSeparators(in value: String) -> String {
        value
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
