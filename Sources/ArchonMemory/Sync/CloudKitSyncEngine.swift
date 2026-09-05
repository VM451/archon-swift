import Foundation
import CloudKit
import OSLog

public enum ArchonCloudKitError: Error, LocalizedError, Equatable, Sendable {
    case containerIdentifierRequired
    case noAccount
    case restricted
    case temporarilyUnavailable
    case accountStatusUnknown
    case syncInProgress

    public var errorDescription: String? {
        switch self {
        case .containerIdentifierRequired: "A CloudKit container identifier is required."
        case .noAccount: "No iCloud account is available for CloudKit sync."
        case .restricted: "CloudKit access is restricted for this account or device."
        case .temporarilyUnavailable: "The iCloud account is temporarily unavailable."
        case .accountStatusUnknown: "CloudKit account status could not be determined."
        case .syncInProgress: "A CloudKit sync fetch is already in progress."
        }
    }
}

/// Actor handling atomic CloudKit delta sync, push subscriptions, and multi-device state synchronization.
public actor CloudKitSyncEngine {
    public let containerId: String
    private lazy var container: CKContainer = CKContainer(identifier: containerId)
    private lazy var privateDatabase: CKDatabase = container.privateCloudDatabase
    private lazy var customZone: CKRecordZone = CKRecordZone(zoneName: Self.defaultZoneName)
    private let logger = Logger(subsystem: "com.archon.memory.swift", category: "CloudKitSyncEngine")
    
    public static let defaultZoneName = "ArchonPrivateZone"
    public static let subscriptionID = "archon-db-changes"
    
    private var changeToken: CKServerChangeToken?
    private let changeTokenURL: URL?
    private var fetchInProgress = false
    
    public init(containerId: String? = nil, changeTokenURL: URL? = nil) {
        let normalizedContainerID = containerId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedChangeTokenURL = changeTokenURL ?? Self.defaultChangeTokenURL(for: normalizedContainerID)
        self.containerId = normalizedContainerID
        self.changeTokenURL = resolvedChangeTokenURL
        self.changeToken = Self.loadChangeToken(from: resolvedChangeTokenURL)
    }

    public func accountStatus() async throws -> CKAccountStatus {
        guard !containerId.isEmpty else { throw ArchonCloudKitError.containerIdentifierRequired }
        return try await container.accountStatus()
    }

    private func requireAvailableAccount() async throws {
        switch try await accountStatus() {
        case .available:
            break
        case .noAccount:
            throw ArchonCloudKitError.noAccount
        case .restricted:
            throw ArchonCloudKitError.restricted
        case .temporarilyUnavailable:
            throw ArchonCloudKitError.temporarilyUnavailable
        case .couldNotDetermine:
            throw ArchonCloudKitError.accountStatusUnknown
        @unknown default:
            throw ArchonCloudKitError.accountStatusUnknown
        }
    }

    /// Sets up the private custom CKRecordZone and registers push notification subscriptions.
    public func setupZoneAndSubscriptions() async throws {
        try await requireAvailableAccount()
        do {
            _ = try await privateDatabase.save(customZone)
            logger.info("Successfully created custom CKRecordZone: \(Self.defaultZoneName)")
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .serverRecordChanged {
            // Zone already exists
        } catch {
            throw error
        }
        
        let subscription = CKRecordZoneSubscription(zoneID: customZone.zoneID, subscriptionID: Self.subscriptionID)
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        
        do {
            _ = try await privateDatabase.save(subscription)
            logger.info("Successfully registered CloudKit Push Subscription.")
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // The subscription may already exist. Other setup failures remain
            // visible to the host so entitlements and container configuration
            // cannot fail silently.
        } catch {
            throw error
        }
    }

    /// Upload modified or deleted memory items to CloudKit private database.
    public func upload(memories: [MemoryItem]) async throws {
        guard !memories.isEmpty else { return }
        try await requireAvailableAccount()
        
        let records = memories.map { $0.toCKRecord(zoneID: customZone.zoneID) }
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        operation.qualityOfService = .userInitiated
        
        return try await withCheckedThrowingContinuation { continuation in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            self.privateDatabase.add(operation)
        }
    }

    /// Upload modified or deleted knowledge graph entities and relations to CloudKit.
    public func uploadGraph(entities: [Entity], relations: [Relation]) async throws {
        var records: [CKRecord] = []
        records.append(contentsOf: entities.map { $0.toCKRecord(zoneID: customZone.zoneID) })
        records.append(contentsOf: relations.map { $0.toCKRecord(zoneID: customZone.zoneID) })
        
        guard !records.isEmpty else { return }
        try await requireAvailableAccount()
        
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        operation.qualityOfService = .userInitiated
        
        return try await withCheckedThrowingContinuation { continuation in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            self.privateDatabase.add(operation)
        }
    }

    /// Result structure for incremental sync fetches.
    public struct SyncFetchResult: Sendable {
        public let updatedMemories: [MemoryItem]
        public let updatedEntities: [Entity]
        public let updatedRelations: [Relation]
        public let deletedRecords: [DeletedRecord]
        public let newChangeToken: CKServerChangeToken?

        public var deletedRecordIDs: [UUID] { deletedRecords.map(\.id) }
    }

    public struct DeletedRecord: Sendable, Equatable {
        public let id: UUID
        public let recordType: String

        public init(id: UUID, recordType: String) {
            self.id = id
            self.recordType = recordType
        }
    }

    /// Fetches changes from the last committed token and persists the new
    /// token only after the caller has applied the returned records.
    public func fetchChanges() async throws -> SyncFetchResult {
        guard !fetchInProgress else { throw ArchonCloudKitError.syncInProgress }
        fetchInProgress = true
        defer { fetchInProgress = false }
        do {
            let result = try await fetchChanges(currentToken: changeToken)
            return result
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
            removePersistedChangeToken()
            throw error
        }
    }

    /// Commits a token after local application of a complete fetch result.
    public func commitChangeToken(_ token: CKServerChangeToken?) throws {
        changeToken = token
        guard let token else {
            removePersistedChangeToken()
            return
        }
        try persistChangeToken(token)
    }

    /// Fetch incremental delta changes from CloudKit using stored change token.
    public func fetchChanges(currentToken: CKServerChangeToken?) async throws -> SyncFetchResult {
        try await requireAvailableAccount()
        var updatedMemories: [MemoryItem] = []
        var updatedEntities: [Entity] = []
        var updatedRelations: [Relation] = []
        var deletedRecords: [DeletedRecord] = []
        var newServerToken: CKServerChangeToken? = currentToken

        let zoneConfig = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        zoneConfig.previousServerChangeToken = currentToken

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [customZone.zoneID],
            configurationsByRecordZoneID: [customZone.zoneID: zoneConfig]
        )

        return try await withCheckedThrowingContinuation { continuation in
            operation.recordWasChangedBlock = { recordID, result in
                if case .success(let record) = result {
                    if record.recordType == "ArchonMemory", let memory = MemoryItem.fromCKRecord(record) {
                        updatedMemories.append(memory)
                    } else if record.recordType == "ArchonEntity", let entity = Entity.fromCKRecord(record) {
                        updatedEntities.append(entity)
                    } else if record.recordType == "ArchonRelation", let relation = Relation.fromCKRecord(record) {
                        updatedRelations.append(relation)
                    }
                }
            }

            operation.recordWithIDWasDeletedBlock = { recordID, recordType in
                if let uuid = UUID(uuidString: recordID.recordName) {
                    deletedRecords.append(DeletedRecord(id: uuid, recordType: recordType))
                }
            }

            operation.recordZoneFetchResultBlock = { zoneID, result in
                if case .success(let (token, _, _)) = result {
                    newServerToken = token
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: SyncFetchResult(
                        updatedMemories: updatedMemories,
                        updatedEntities: updatedEntities,
                        updatedRelations: updatedRelations,
                        deletedRecords: deletedRecords,
                        newChangeToken: newServerToken
                    ))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            self.privateDatabase.add(operation)
        }
    }

    /// Reconciles local items with incoming remote items using Last-Write-Wins (LWW) conflict resolution strategy.
    public nonisolated func resolveConflicts(local: MemoryItem, remote: MemoryItem) -> MemoryItem {
        if remote.version > local.version {
            return remote
        } else if local.version > remote.version {
            return local
        } else {
            return remote.updatedAt >= local.updatedAt ? remote : local
        }
    }

    public nonisolated func resolveEntityConflicts(local: Entity, remote: Entity) -> Entity {
        if remote.version > local.version {
            return remote
        } else if local.version > remote.version {
            return local
        } else {
            return remote.updatedAt >= local.updatedAt ? remote : local
        }
    }

    public nonisolated func resolveRelationConflicts(local: Relation, remote: Relation) -> Relation {
        if remote.version > local.version {
            return remote
        } else if local.version > remote.version {
            return local
        } else {
            return remote.updatedAt >= local.updatedAt ? remote : local
        }
    }

    private func persistChangeToken(_ token: CKServerChangeToken) throws {
        guard let changeTokenURL else { return }
        try FileManager.default.createDirectory(at: changeTokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        try data.write(to: changeTokenURL, options: .atomic)
    }

    private func removePersistedChangeToken() {
        guard let changeTokenURL else { return }
        try? FileManager.default.removeItem(at: changeTokenURL)
    }

    private static func loadChangeToken(from url: URL?) -> CKServerChangeToken? {
        guard let url,
              let tokenData = try? Data(contentsOf: url) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: tokenData)
    }

    private static func defaultChangeTokenURL(for containerId: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let safeContainerID = containerId.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains(scalar)
                ? Character(String(scalar))
                : "_"
        }
        return support
            .appendingPathComponent("ArchonMemory", isDirectory: true)
            .appendingPathComponent("cloudkit-\(String(safeContainerID)).data")
    }
}
