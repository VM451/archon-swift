import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

/// A request executed by an OS-managed background URLSession.
///
/// The destination is a staging file. Callers must still verify the file and
/// atomically install it through `ModelLibrary` after receiving `.ready`.
public struct ModelBackgroundDownloadRequest: Codable, Equatable, Sendable {
    public let identifier: String
    public let url: URL
    public let destinationURL: URL
    public let headers: [String: String]

    public init(
        identifier: String,
        url: URL,
        destinationURL: URL,
        headers: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.url = url
        self.destinationURL = destinationURL
        self.headers = headers
    }
}

public enum ModelBackgroundTransferStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case downloading
    case paused
    case ready
    case failed
    case cancelled
}

/// Persistent state needed to reconnect to a background transfer after the
/// host application has been relaunched by the operating system.
public struct ModelBackgroundDownloadRecord: Codable, Equatable, Sendable {
    public let request: ModelBackgroundDownloadRequest
    public var taskIdentifier: Int?
    public var resumeData: Data?
    public var status: ModelBackgroundTransferStatus
    public var bytesDownloaded: Int64
    public var totalBytes: Int64?
    public var lastError: String?

    public init(
        request: ModelBackgroundDownloadRequest,
        taskIdentifier: Int? = nil,
        resumeData: Data? = nil,
        status: ModelBackgroundTransferStatus = .queued,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64? = nil,
        lastError: String? = nil
    ) {
        self.request = request
        self.taskIdentifier = taskIdentifier
        self.resumeData = resumeData
        self.status = status
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.lastError = lastError
    }
}

public enum ModelBackgroundTransferState: Sendable, Equatable {
    case queued
    case downloading(bytesDownloaded: Int64, totalBytes: Int64?)
    case paused
    case ready(URL)
    case failed(String)
    case cancelled
}

public struct ModelBackgroundTransferEvent: Sendable {
    public let identifier: String
    public let state: ModelBackgroundTransferState

    public init(identifier: String, state: ModelBackgroundTransferState) {
        self.identifier = identifier
        self.state = state
    }
}

public enum ModelBackgroundTransferError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case alreadyActive(String)
    case noRecord(String)
    case notActive(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): "Invalid background download request: \(reason)"
        case .alreadyActive(let identifier): "A background download is already active: \(identifier)"
        case .noRecord(let identifier): "No background download record exists: \(identifier)"
        case .notActive(let identifier): "No active background download exists: \(identifier)"
        case .persistence(let reason): "Unable to persist background download state: \(reason)"
        }
    }
}

private struct PersistedModelBackgroundDownloadRecord: Codable {
    let request: ModelBackgroundDownloadRequest
    let taskIdentifier: Int?
    let encryptedResumeData: Data?
    let status: ModelBackgroundTransferStatus
    let bytesDownloaded: Int64
    let totalBytes: Int64?
    let lastError: String?
}

/// Persistence boundary for background transfers. A file-backed store lets a
/// host reconstruct the coordinator after a process relaunch; an in-memory
/// store is useful for tests and short-lived foreground hosts.
public protocol ModelBackgroundDownloadStore: Sendable {
    func record(for identifier: String) async throws -> ModelBackgroundDownloadRecord?
    func save(_ record: ModelBackgroundDownloadRecord) async throws
    func remove(identifier: String) async throws
    func allRecords() async throws -> [ModelBackgroundDownloadRecord]
}

public actor InMemoryModelBackgroundDownloadStore: ModelBackgroundDownloadStore {
    private var records: [String: ModelBackgroundDownloadRecord] = [:]

    public init() {}

    public func record(for identifier: String) async throws -> ModelBackgroundDownloadRecord? {
        records[identifier]
    }

    public func save(_ record: ModelBackgroundDownloadRecord) async throws {
        records[record.request.identifier] = record
    }

    public func remove(identifier: String) async throws {
        records[identifier] = nil
    }

    public func allRecords() async throws -> [ModelBackgroundDownloadRecord] {
        records.values.sorted { $0.request.identifier < $1.request.identifier }
    }
}

/// Small JSON-backed store intended for an app-owned Application Support URL.
/// The SDK never chooses a broad filesystem location for this store.
public actor FileModelBackgroundDownloadStore: ModelBackgroundDownloadStore {
    public let fileURL: URL
    private var loaded = false
    private var records: [String: ModelBackgroundDownloadRecord] = [:]

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func record(for identifier: String) async throws -> ModelBackgroundDownloadRecord? {
        try loadIfNeeded()
        return records[identifier]
    }

    public func save(_ record: ModelBackgroundDownloadRecord) async throws {
        try loadIfNeeded()
        records[record.request.identifier] = Self.sanitized(record)
        try persist()
    }

    public func remove(identifier: String) async throws {
        try loadIfNeeded()
        records[identifier] = nil
        try persist()
    }

    public func allRecords() async throws -> [ModelBackgroundDownloadRecord] {
        try loadIfNeeded()
        return records.values.sorted { $0.request.identifier < $1.request.identifier }
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loaded = true
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            if let decoded = try? JSONDecoder().decode([PersistedModelBackgroundDownloadRecord].self, from: data) {
                let restored = decoded.map(restore)
                records = Dictionary(uniqueKeysWithValues: restored.map { ($0.request.identifier, $0) })
            } else {
                // Accept records written by an earlier SDK revision, but do
                // not carry opaque resume data forward into plaintext state.
                let legacy = try JSONDecoder().decode([ModelBackgroundDownloadRecord].self, from: data)
                records = Dictionary(uniqueKeysWithValues: legacy.map { record in
                    var safe = Self.sanitized(record)
                    safe.resumeData = nil
                    return (safe.request.identifier, safe)
                })
            }
            // Mark the store loaded only after a complete, valid decode. A
            // corrupt file must remain retryable and observable rather than
            // being silently converted into an empty in-memory store.
            loaded = true
        } catch {
            throw ModelBackgroundTransferError.persistence(error.localizedDescription)
        }
    }

    private func persist() throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let persisted = try records.values
                .sorted { $0.request.identifier < $1.request.identifier }
                .map { try persisted($0) }
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ModelBackgroundTransferError.persistence(error.localizedDescription)
        }
    }

    private static func sanitized(_ record: ModelBackgroundDownloadRecord) -> ModelBackgroundDownloadRecord {
        let safeHeaders = record.request.headers.filter { field, _ in
            let normalized = field.lowercased().replacingOccurrences(of: "_", with: "-")
            let sensitiveMarkers = [
                "authorization", "proxy-authorization", "cookie", "set-cookie",
                "token", "secret", "password", "credential", "api-key"
            ]
            return !sensitiveMarkers.contains(where: normalized.contains)
        }
        guard safeHeaders.count != record.request.headers.count else { return record }
        let safeRequest = ModelBackgroundDownloadRequest(
            identifier: record.request.identifier,
            url: record.request.url,
            destinationURL: record.request.destinationURL,
            headers: safeHeaders
        )
        return ModelBackgroundDownloadRecord(
            request: safeRequest,
            taskIdentifier: record.taskIdentifier,
            resumeData: record.resumeData,
            status: record.status,
            bytesDownloaded: record.bytesDownloaded,
            totalBytes: record.totalBytes,
            lastError: record.lastError
        )
    }

    private func persisted(_ record: ModelBackgroundDownloadRecord) throws -> PersistedModelBackgroundDownloadRecord {
        let safe = Self.sanitized(record)
        return PersistedModelBackgroundDownloadRecord(
            request: safe.request,
            taskIdentifier: safe.taskIdentifier,
            encryptedResumeData: encryptResumeData(safe.resumeData),
            status: safe.status,
            bytesDownloaded: safe.bytesDownloaded,
            totalBytes: safe.totalBytes,
            lastError: safe.lastError
        )
    }

    private func restore(_ record: PersistedModelBackgroundDownloadRecord) -> ModelBackgroundDownloadRecord {
        ModelBackgroundDownloadRecord(
            request: record.request,
            taskIdentifier: record.taskIdentifier,
            resumeData: decryptResumeData(record.encryptedResumeData),
            status: record.status,
            bytesDownloaded: record.bytesDownloaded,
            totalBytes: record.totalBytes,
            lastError: record.lastError
        )
    }

    /// URLSession resume data may contain the original request headers. Keep
    /// it encrypted at rest and fall back to nil if the platform Keychain is
    /// unavailable; callers can then resume with a fresh Keychain token.
    private func encryptResumeData(_ data: Data?) -> Data? {
        guard let data, let key = keychainKey() else { return nil }
        return try? AES.GCM.seal(data, using: key).combined
    }

    private func decryptResumeData(_ data: Data?) -> Data? {
        guard let data, let key = keychainKey(),
              let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    private func keychainKey() -> SymmetricKey? {
        #if canImport(Security)
        let pathDigest = SHA256.hash(data: Data(fileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let service = "com.archon.models.background-resume"
        let account = pathDigest
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let keyData = result as? Data,
           keyData.count == 32 {
            return SymmetricKey(data: keyData)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = keyData
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else { return nil }
        return key
        #else
        return nil
        #endif
    }
}

/// Actor-backed bridge to an Apple background URLSession.
///
/// Recreate this coordinator with the same session identifier and a
/// persistent store after a process relaunch, then call `reconnect()`. The
/// coordinator only transfers bytes; callers must verify checksums/resources
/// and use `ModelLibrary` for atomic installation.
public actor ModelBackgroundTransferCoordinator {
    private let session: URLSession
    private let delegate: ModelBackgroundURLSessionDelegate
    private let store: any ModelBackgroundDownloadStore
    private var taskIdentifiers: [String: Int] = [:]
    private var identifiersByTask: [Int: String] = [:]
    private var continuations: [String: AsyncThrowingStream<ModelBackgroundTransferEvent, Error>.Continuation] = [:]
    private var continuationTokens: [String: UUID] = [:]
    private var pauseRequested: Set<String> = []
    private var cancelRequested: Set<String> = []
    private var finishedTaskIdentifiers: Set<Int> = []

    public init(
        sessionIdentifier: String,
        store: any ModelBackgroundDownloadStore = InMemoryModelBackgroundDownloadStore(),
        waitsForConnectivity: Bool = true
    ) {
        let delegate = ModelBackgroundURLSessionDelegate()
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.waitsForConnectivity = waitsForConnectivity
        self.delegate = delegate
        self.store = store
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegate.queue)
        delegate.owner = self
    }

    public func start(_ request: ModelBackgroundDownloadRequest) async throws -> AsyncThrowingStream<ModelBackgroundTransferEvent, Error> {
        try validate(request)
        guard taskIdentifiers[request.identifier] == nil else {
            throw ModelBackgroundTransferError.alreadyActive(request.identifier)
        }
        if let existing = try await store.record(for: request.identifier),
           existing.status == .queued || existing.status == .downloading {
            throw ModelBackgroundTransferError.alreadyActive(request.identifier)
        }
        return try await begin(request: request, resumeData: nil)
    }

    public func resume(
        identifier: String,
        request replacementRequest: ModelBackgroundDownloadRequest? = nil
    ) async throws -> AsyncThrowingStream<ModelBackgroundTransferEvent, Error> {
        guard taskIdentifiers[identifier] == nil else {
            throw ModelBackgroundTransferError.alreadyActive(identifier)
        }
        guard let record = try await store.record(for: identifier) else {
            throw ModelBackgroundTransferError.noRecord(identifier)
        }
        let request = replacementRequest ?? record.request
        guard request.identifier == identifier else {
            throw ModelBackgroundTransferError.invalidRequest("replacement request identifier must match the stored identifier")
        }
        try validate(request)
        guard record.status == .paused || record.status == .failed || record.status == .cancelled else {
            throw ModelBackgroundTransferError.alreadyActive(identifier)
        }
        return try await begin(request: request, resumeData: record.resumeData)
    }

    public func pause(identifier: String) async throws {
        if taskIdentifiers[identifier] == nil {
            _ = try await reconnect()
        }
        guard let taskIdentifier = taskIdentifiers[identifier],
              let task = delegate.task(withIdentifier: taskIdentifier) else {
            throw ModelBackgroundTransferError.notActive(identifier)
        }
        pauseRequested.insert(identifier)
        let resumeData = await task.cancelByProducingResumeData()
        await receiveResumeData(identifier: identifier, resumeData: resumeData)
    }

    public func cancel(identifier: String) async throws {
        if taskIdentifiers[identifier] == nil {
            _ = try await reconnect()
        }
        guard let taskIdentifier = taskIdentifiers[identifier],
              let task = delegate.task(withIdentifier: taskIdentifier) else {
            guard let record = try await store.record(for: identifier) else {
                throw ModelBackgroundTransferError.noRecord(identifier)
            }
            try? FileManager.default.removeItem(at: record.request.destinationURL)
            await finish(identifier: identifier, status: .cancelled, state: .cancelled, errorMessage: nil)
            return
        }
        cancelRequested.insert(identifier)
        task.cancel()
    }

    public func events(for identifier: String) async throws -> AsyncThrowingStream<ModelBackgroundTransferEvent, Error> {
        guard let record = try await store.record(for: identifier) else {
            throw ModelBackgroundTransferError.noRecord(identifier)
        }
        guard continuations[identifier] == nil else {
            throw ModelBackgroundTransferError.alreadyActive(identifier)
        }
        let (stream, continuation) = AsyncThrowingStream<ModelBackgroundTransferEvent, Error>.makeStream()
        let continuationToken = UUID()
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(for: identifier, token: continuationToken)
            }
        }
        continuations[identifier] = continuation
        continuationTokens[identifier] = continuationToken
        if taskIdentifiers[identifier] == nil {
            switch record.status {
            case .queued:
                continuation.yield(.init(identifier: identifier, state: .queued))
            case .downloading:
                continuation.yield(.init(identifier: identifier, state: .downloading(
                    bytesDownloaded: record.bytesDownloaded,
                    totalBytes: record.totalBytes
                )))
            case .paused:
                continuation.yield(.init(identifier: identifier, state: .paused))
                continuation.finish()
                clearContinuation(for: identifier)
            case .ready:
                continuation.yield(.init(identifier: identifier, state: .ready(record.request.destinationURL)))
                continuation.finish()
                clearContinuation(for: identifier)
            case .failed:
                continuation.yield(.init(identifier: identifier, state: .failed(record.lastError ?? "Background download failed.")))
                continuation.finish()
                clearContinuation(for: identifier)
            case .cancelled:
                continuation.yield(.init(identifier: identifier, state: .cancelled))
                continuation.finish()
                clearContinuation(for: identifier)
            }
        } else {
            switch record.status {
            case .queued:
                continuation.yield(.init(identifier: identifier, state: .queued))
            case .downloading:
                continuation.yield(.init(identifier: identifier, state: .downloading(
                    bytesDownloaded: record.bytesDownloaded,
                    totalBytes: record.totalBytes
                )))
            case .paused, .ready, .failed, .cancelled:
                break
            }
        }
        return stream
    }

    /// Reattaches this coordinator to transfers owned by the OS after a host
    /// process relaunch. The returned records are the authoritative persisted
    /// metadata; use `events(for:)` to observe a reconnected transfer.
    public func reconnect() async throws -> [ModelBackgroundDownloadRecord] {
        let tasks = await sessionTaskSnapshots()
        var records = try await store.allRecords()
        var reconnectedIdentifiers = Set<String>()
        for task in tasks {
            guard let identifier = task.taskDescription,
                  let index = records.firstIndex(where: { $0.request.identifier == identifier }),
                  let downloadTask = delegate.task(withIdentifier: task.taskIdentifier) else { continue }
            reconnectedIdentifiers.insert(identifier)
            taskIdentifiers[identifier] = task.taskIdentifier
            identifiersByTask[task.taskIdentifier] = identifier
            delegate.register(task: downloadTask, destinationURL: records[index].request.destinationURL)
            records[index].taskIdentifier = task.taskIdentifier
            if records[index].status == .queued { records[index].status = .downloading }
            try await store.save(records[index])
        }

        // A process can be relaunched after the persisted record is written
        // but before URLSession has adopted the task, or after the OS has
        // discarded a task. Do not leave those records permanently stuck in
        // an active state: mark them failed so the normal resume path can
        // create a fresh transfer while preserving the staged artifact.
        let recoveryMessage = "Background transfer was not found after reconnect."
        for index in records.indices where
            (records[index].status == .queued || records[index].status == .downloading) &&
            !reconnectedIdentifiers.contains(records[index].request.identifier) {
            records[index].taskIdentifier = nil
            records[index].resumeData = nil
            records[index].status = .failed
            records[index].lastError = recoveryMessage
            try await store.save(records[index])
        }
        return try await store.allRecords()
    }

    public func record(for identifier: String) async throws -> ModelBackgroundDownloadRecord? {
        try await store.record(for: identifier)
    }

    public func isActive(identifier: String) -> Bool {
        taskIdentifiers[identifier] != nil
    }

    private func begin(
        request: ModelBackgroundDownloadRequest,
        resumeData: Data?
    ) async throws -> AsyncThrowingStream<ModelBackgroundTransferEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ModelBackgroundTransferEvent, Error>.makeStream()
        let continuationToken = UUID()
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(for: request.identifier, token: continuationToken)
            }
        }
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var urlRequest = URLRequest(url: request.url)
            for (field, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: field)
            }
            task = session.downloadTask(with: urlRequest)
        }
        task.taskDescription = request.identifier
        taskIdentifiers[request.identifier] = task.taskIdentifier
        identifiersByTask[task.taskIdentifier] = request.identifier
        continuations[request.identifier] = continuation
        continuationTokens[request.identifier] = continuationToken
        delegate.register(task: task, destinationURL: request.destinationURL)
        var record = ModelBackgroundDownloadRecord(
            request: request,
            taskIdentifier: task.taskIdentifier,
            resumeData: nil,
            status: .queued
        )
        if resumeData != nil, let previous = try await store.record(for: request.identifier) {
            record.bytesDownloaded = previous.bytesDownloaded
            record.totalBytes = previous.totalBytes
        }
        try await store.save(record)
        continuation.yield(.init(identifier: request.identifier, state: .queued))
        task.resume()
        return stream
    }

    private func validate(_ request: ModelBackgroundDownloadRequest) throws {
        guard !request.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelBackgroundTransferError.invalidRequest("identifier is empty")
        }
        do {
            try ModelDownloadURLPolicy.validate(request.url)
        } catch {
            throw ModelBackgroundTransferError.invalidRequest(
                "url must be an HTTPS model endpoint"
            )
        }
        guard request.destinationURL.isFileURL else {
            throw ModelBackgroundTransferError.invalidRequest("destinationURL must be a file URL")
        }
    }

    private func sessionTaskSnapshots() async -> [ModelBackgroundTaskSnapshot] {
        let session = self.session
        let delegate = self.delegate
        return await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                delegate.adopt(tasks: tasks)
                let snapshots = tasks.map {
                    ModelBackgroundTaskSnapshot(
                        taskIdentifier: $0.taskIdentifier,
                        taskDescription: $0.taskDescription,
                        state: $0.state.rawValue
                    )
                }
                continuation.resume(returning: snapshots)
            }
        }
    }

    func receiveProgress(taskIdentifier: Int, bytesWritten: Int64, totalBytes: Int64) async {
        guard let identifier = identifiersByTask[taskIdentifier] ?? delegate.taskDescription(withIdentifier: taskIdentifier),
              var record = try? await store.record(for: identifier) else { return }
        record.taskIdentifier = taskIdentifier
        record.status = .downloading
        record.bytesDownloaded = bytesWritten
        record.totalBytes = totalBytes > 0 ? totalBytes : nil
        try? await store.save(record)
        continuations[identifier]?.yield(.init(identifier: identifier, state: .downloading(
            bytesDownloaded: bytesWritten,
            totalBytes: totalBytes > 0 ? totalBytes : nil
        )))
    }

    func receiveFinished(taskIdentifier: Int, destinationURL: URL?, errorMessage: String?) async {
        guard let identifier = identifiersByTask[taskIdentifier] ?? delegate.taskDescription(withIdentifier: taskIdentifier) else { return }
        finishedTaskIdentifiers.insert(taskIdentifier)
        guard var record = try? await store.record(for: identifier) else { return }
        let cancellationWasRequested = cancelRequested.remove(identifier) != nil
        record.taskIdentifier = nil
        taskIdentifiers[identifier] = nil
        identifiersByTask[taskIdentifier] = nil
        delegate.unregister(taskIdentifier: taskIdentifier)
        if cancellationWasRequested {
            try? FileManager.default.removeItem(at: destinationURL ?? record.request.destinationURL)
            await finish(identifier: identifier, status: .cancelled, state: .cancelled, errorMessage: nil)
            return
        }
        if let errorMessage {
            record.status = .failed
            record.lastError = errorMessage
            try? await store.save(record)
            continuations[identifier]?.yield(.init(identifier: identifier, state: .failed(errorMessage)))
            continuations[identifier]?.finish()
            clearContinuation(for: identifier)
            return
        }
        record.status = .ready
        record.resumeData = nil
        record.lastError = nil
        try? await store.save(record)
        continuations[identifier]?.yield(.init(identifier: identifier, state: .ready(destinationURL ?? record.request.destinationURL)))
        continuations[identifier]?.finish()
        clearContinuation(for: identifier)
    }

    func receiveCompleted(taskIdentifier: Int, errorMessage: String?) async {
        guard finishedTaskIdentifiers.remove(taskIdentifier) == nil,
              let identifier = identifiersByTask[taskIdentifier] ?? delegate.taskDescription(withIdentifier: taskIdentifier) else { return }
        if pauseRequested.contains(identifier) {
            return
        }
        if cancelRequested.remove(identifier) != nil {
            if let record = try? await store.record(for: identifier) {
                try? FileManager.default.removeItem(at: record.request.destinationURL)
            }
            await finish(identifier: identifier, status: .cancelled, state: .cancelled, errorMessage: nil)
            return
        }
        let message = errorMessage ?? "Background download completed without a downloaded file."
        await finish(identifier: identifier, status: .failed, state: .failed(message), errorMessage: message)
    }

    private func receiveResumeData(identifier: String, resumeData: Data?) async {
        guard pauseRequested.remove(identifier) != nil,
              var record = try? await store.record(for: identifier) else { return }
        // A completion callback can win while URLSession is producing resume
        // data. Never move an already terminal transfer back to Paused.
        guard record.status == .queued || record.status == .downloading else { return }
        let taskIdentifier = taskIdentifiers.removeValue(forKey: identifier)
        if let taskIdentifier {
            identifiersByTask[taskIdentifier] = nil
            delegate.unregister(taskIdentifier: taskIdentifier)
        }
        record.taskIdentifier = nil
        record.resumeData = resumeData
        record.status = .paused
        try? await store.save(record)
        continuations[identifier]?.yield(.init(identifier: identifier, state: .paused))
        continuations[identifier]?.finish()
        clearContinuation(for: identifier)
    }

    private func finish(
        identifier: String,
        status: ModelBackgroundTransferStatus,
        state: ModelBackgroundTransferState,
        errorMessage: String?
    ) async {
        guard var record = try? await store.record(for: identifier) else { return }
        pauseRequested.remove(identifier)
        cancelRequested.remove(identifier)
        let taskIdentifier = taskIdentifiers.removeValue(forKey: identifier)
        if let taskIdentifier {
            identifiersByTask[taskIdentifier] = nil
            delegate.unregister(taskIdentifier: taskIdentifier)
        }
        record.taskIdentifier = nil
        record.status = status
        record.lastError = errorMessage
        record.resumeData = nil
        try? await store.save(record)
        continuations[identifier]?.yield(.init(identifier: identifier, state: state))
        continuations[identifier]?.finish()
        clearContinuation(for: identifier)
    }

    private func removeContinuation(for identifier: String, token: UUID) {
        guard continuationTokens[identifier] == token else { return }
        clearContinuation(for: identifier)
    }

    private func clearContinuation(for identifier: String) {
        continuations[identifier] = nil
        continuationTokens[identifier] = nil
    }

}

private struct ModelBackgroundTaskSnapshot: Sendable {
    let taskIdentifier: Int
    let taskDescription: String?
    let state: Int
}

private final class ModelBackgroundURLSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let queue: OperationQueue
    weak var owner: ModelBackgroundTransferCoordinator?
    private let lock = NSLock()
    private var destinations: [Int: URL] = [:]
    private var tasks: [Int: URLSessionDownloadTask] = [:]

    override init() {
        self.queue = OperationQueue()
        self.queue.maxConcurrentOperationCount = 1
        super.init()
    }

    func register(task: URLSessionDownloadTask, destinationURL: URL) {
        lock.lock()
        tasks[task.taskIdentifier] = task
        destinations[task.taskIdentifier] = destinationURL
        lock.unlock()
    }

    func unregister(taskIdentifier: Int) {
        lock.lock()
        tasks[taskIdentifier] = nil
        destinations[taskIdentifier] = nil
        lock.unlock()
    }

    func task(withIdentifier taskIdentifier: Int) -> URLSessionDownloadTask? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[taskIdentifier]
    }

    func taskDescription(withIdentifier taskIdentifier: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[taskIdentifier]?.taskDescription
    }

    /// `getAllTasks` is invoked by URLSession's callback queue. Adopt the
    /// objects synchronously so the actor can later cancel or pause them.
    func adopt(tasks: [URLSessionTask]) {
        lock.lock()
        for task in tasks {
            if let downloadTask = task as? URLSessionDownloadTask {
                self.tasks[downloadTask.taskIdentifier] = downloadTask
            }
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task {
            await owner?.receiveProgress(
                taskIdentifier: downloadTask.taskIdentifier,
                bytesWritten: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination: URL?
        lock.lock()
        destination = destinations[downloadTask.taskIdentifier]
        lock.unlock()
        guard let destination else {
            Task { await owner?.receiveFinished(taskIdentifier: downloadTask.taskIdentifier, destinationURL: nil, errorMessage: "No destination was registered for the background task.") }
            return
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: location)
            } else {
                try FileManager.default.moveItem(at: location, to: destination)
            }
            Task { await owner?.receiveFinished(taskIdentifier: downloadTask.taskIdentifier, destinationURL: destination, errorMessage: nil) }
        } catch {
            Task { await owner?.receiveFinished(taskIdentifier: downloadTask.taskIdentifier, destinationURL: nil, errorMessage: error.localizedDescription) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task {
            await owner?.receiveCompleted(taskIdentifier: task.taskIdentifier, errorMessage: error?.localizedDescription)
        }
    }
}
