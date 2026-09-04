#if canImport(Network)

import ArchonConnect
import Foundation
import Network
import Testing

private enum LoopbackMCPServerMode: Sendable {
    case normal
    case holdToolCall
}

private actor LoopbackMCPServerState {
    private(set) var methods: [String] = []
    private var pendingToolCallConnectionID: UInt64?
    private var cancellationNotificationReceived = false
    private var toolCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func record(method: String, connectionID: UInt64, holdsToolCall: Bool) {
        methods.append(method)
        if method == "notifications/cancelled" {
            cancellationNotificationReceived = true
            for waiter in cancellationWaiters {
                waiter.resume()
            }
            cancellationWaiters.removeAll()
        }
        guard holdsToolCall, method == "tools/call" else { return }
        pendingToolCallConnectionID = connectionID
        for waiter in toolCallWaiters {
            waiter.resume()
        }
        toolCallWaiters.removeAll()
    }

    func waitForHeldToolCall() async {
        if pendingToolCallConnectionID != nil { return }
        await withCheckedContinuation { toolCallWaiters.append($0) }
    }

    func waitForCancellationNotification() async {
        if cancellationNotificationReceived { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func didReceiveCancellationNotification() -> Bool {
        cancellationNotificationReceived
    }
}

private final class LoopbackMCPServer: @unchecked Sendable {
    private final class StartGate: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = false

        func resolve(_ operation: () -> Void) {
            lock.lock()
            guard !resolved else {
                lock.unlock()
                return
            }
            resolved = true
            lock.unlock()
            operation()
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "archon.mcp.loopback-server")
    private let mode: LoopbackMCPServerMode
    private let state = LoopbackMCPServerState()
    private let connectionLock = NSLock()
    private var nextConnectionID: UInt64 = 0
    private var connections: [UInt64: NWConnection] = [:]

    init(mode: LoopbackMCPServerMode) throws {
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        self.listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        let gate = StartGate()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] listenerState in
                guard let self else { return }
                switch listenerState {
                case .ready:
                    guard let port = self.listener.port else {
                        gate.resolve {
                            continuation.resume(throwing: LoopbackMCPServerError.missingPort)
                        }
                        return
                    }
                    gate.resolve {
                        continuation.resume(
                            returning: URL(string: "http://127.0.0.1:\(port)/mcp")!
                        )
                    }
                case .failed(let error):
                    gate.resolve { continuation.resume(throwing: error) }
                case .cancelled:
                    gate.resolve { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        connectionLock.lock()
        let activeConnections = Array(connections.values)
        connections.removeAll()
        connectionLock.unlock()
        for connection in activeConnections {
            connection.cancel()
        }
    }

    func receivedMethods() async -> [String] {
        await state.methods
    }

    func waitForHeldToolCall() async {
        await state.waitForHeldToolCall()
    }

    func waitForCancellationNotification() async {
        await state.waitForCancellationNotification()
    }

    func didReceiveCancellationNotification() async -> Bool {
        await state.didReceiveCancellationNotification()
    }

    private func accept(_ connection: NWConnection) {
        let connectionID = allocateConnectionID()
        connectionLock.lock()
        connections[connectionID] = connection
        connectionLock.unlock()

        connection.stateUpdateHandler = { [weak self] connectionState in
            guard let self else { return }
            switch connectionState {
            case .cancelled, .failed:
                self.removeConnection(connectionID)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, connectionID: connectionID, buffer: Data())
    }

    private func allocateConnectionID() -> UInt64 {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        nextConnectionID += 1
        return nextConnectionID
    }

    private func removeConnection(_ connectionID: UInt64) {
        connectionLock.lock()
        connections.removeValue(forKey: connectionID)
        connectionLock.unlock()
    }

    private func receive(on connection: NWConnection, connectionID: UInt64, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let content {
                accumulated.append(content)
            }

            guard let requestBody = Self.requestBody(from: accumulated) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(
                        on: connection,
                        connectionID: connectionID,
                        buffer: accumulated
                    )
                }
                return
            }
            self.handle(requestBody, on: connection, connectionID: connectionID)
        }
    }

    private func handle(_ requestBody: Data, on connection: NWConnection, connectionID: UInt64) {
        guard
            let root = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
            let method = root["method"] as? String
        else {
            connection.cancel()
            return
        }

        let holdsToolCall = mode == .holdToolCall && method == "tools/call"
        Task {
            await state.record(
                method: method,
                connectionID: connectionID,
                holdsToolCall: holdsToolCall
            )
        }

        if holdsToolCall {
            // Leave this request open. The client must cancel the underlying
            // HTTP request when Archon's transport is disconnected.
            return
        }

        let response: [String: Any]
        if method == "notifications/initialized" {
            response = [:]
        } else {
            let requestID = root["id"] ?? NSNull()
            let result: [String: Any]
            switch method {
            case "initialize":
                result = [
                    "protocolVersion": "2025-11-25",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "Archon loopback", "version": "1"]
                ]
            case "tools/call":
                result = [
                    "content": [["type": "text", "text": "loopback-ok"]]
                ]
            default:
                result = [:]
            }
            response = ["jsonrpc": "2.0", "id": requestID, "result": result]
        }
        send(response, on: connection)
    }

    private func send(_ object: [String: Any], on connection: NWConnection) {
        let body: Data
        if object.isEmpty {
            body = Data()
        } else {
            guard let encoded = try? JSONSerialization.data(withJSONObject: object) else {
                connection.cancel()
                return
            }
            body = encoded
        }

        var response = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
        )
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func requestBody(from data: Data) -> Data? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        let headers = String(decoding: headerData, as: UTF8.self)
        let contentLength = headers
            .split(separator: "\r\n")
            .compactMap { line -> Int? in
                let pieces = line.split(separator: ":", maxSplits: 1)
                guard pieces.count == 2,
                      pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
                else { return nil }
                return Int(pieces[1].trimmingCharacters(in: .whitespaces))
            }
            .first ?? 0
        let bodyStart = headerRange.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= contentLength else {
            return nil
        }
        return data.subdata(in: bodyStart..<bodyStart + contentLength)
    }
}

private enum LoopbackMCPServerError: Error {
    case missingPort
}

private struct LoopbackTestTimeout: Error {}

private func withLoopbackTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw LoopbackTestTimeout()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw LoopbackTestTimeout()
        }
        return result
    }
}

struct LoopbackMCPServerTests {
    @Test("Official MCP adapter completes a real loopback HTTP client flow")
    func completesRealLoopbackFlow() async throws {
        let server = try LoopbackMCPServer(mode: .normal)
        defer { server.stop() }
        let endpoint = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral
        let transport = OfficialMCPTransport(
            endpoint: endpoint,
            configuration: configuration,
            streaming: false,
            requestTimeout: 2
        )

        try await withLoopbackTimeout(.seconds(3)) {
            try await transport.connect()
            let result = try await transport.callTool(name: "loopback", arguments: [:])
            #expect(result.content == [.object([
                "type": .string("text"),
                "text": .string("loopback-ok")
            ])])
            await transport.disconnect()
        }

        #expect(await server.receivedMethods() == [
            "initialize",
            "notifications/initialized",
            "tools/call"
        ])
    }

    @Test("Official MCP adapter disconnect cancels a real loopback request")
    func disconnectsRealLoopbackRequest() async throws {
        let server = try LoopbackMCPServer(mode: .holdToolCall)
        defer { server.stop() }
        let endpoint = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral
        let transport = OfficialMCPTransport(
            endpoint: endpoint,
            configuration: configuration,
            streaming: false,
            requestTimeout: 30
        )

        try await transport.connect()
        let events = await transport.streamTool(name: "held", arguments: [:])
        let consumer = Task {
            do {
                for try await _ in events {}
            } catch {
                // Cancellation/disconnect is the behavior under test.
            }
        }

        await server.waitForHeldToolCall()
        let disconnectCompleted: Bool
        do {
            try await withLoopbackTimeout(.seconds(3)) {
                await transport.disconnect()
            }
            disconnectCompleted = true
        } catch {
            disconnectCompleted = false
            Issue.record("Official MCP adapter disconnect timed out: \(error)")
        }
        #expect(disconnectCompleted)
        _ = await consumer.value

        let cancellationWasDelivered: Bool
        do {
            try await withLoopbackTimeout(.seconds(3)) {
                await server.waitForCancellationNotification()
            }
            cancellationWasDelivered = await server.didReceiveCancellationNotification()
        } catch {
            cancellationWasDelivered = false
            Issue.record("Loopback MCP server did not observe cancellation notification: \(error)")
        }
        #expect(cancellationWasDelivered)
    }
}

#endif
