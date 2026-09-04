import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

/// Sync Engine handling delta synchronization across Apple devices using Private CloudKit Database and CRDT resolution.
public actor CloudKitSyncEngine {
    #if canImport(CloudKit)
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    #endif
    
    private let offlineQueue = SyncOfflineQueue()
    private var changeToken: Any? // CKServerChangeToken on platforms with CloudKit
    private var cachedWorkspaces: [UUID: SandboxWorkspace] = [:]
    private static let maxPayloadBytes = 32 * 1024 * 1024
    private static let maxFileCount = 2_000
    private static let maxFileBytes = 8 * 1024 * 1024
    
    public init(containerIdentifier: String = "iCloud.com.archonsandbox.sandbox") {
        #if canImport(CloudKit)
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: "SwiftSandboxZone", ownerName: CKCurrentUserDefaultName)
        #endif
    }
    
    // MARK: - Zone Setup
    
    /// Initializes CloudKit custom zone layout in private database.
    public func setupZone() async throws {
        #if canImport(CloudKit)
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.save(zone)
        #endif
    }
    
    // MARK: - Sync Workspace
    
    /// Uploads delta updates of a Sandbox Workspace to CloudKit private database with CRDT resolution.
    public func syncWorkspace(_ workspace: SandboxWorkspace) async throws {
        #if canImport(CloudKit)
        let recordID = CKRecord.ID(recordName: workspace.id.uuidString, zoneID: zoneID)
        
        // Fetch existing record if any to merge
        var recordToSave: CKRecord
        do {
            let existingRecord = try await database.record(for: recordID)
            recordToSave = existingRecord
            
            // If remote record has file payload, perform CRDT merge
            if let existingPayload = existingRecord["filePayload"] as? Data,
               existingPayload.count <= Self.maxPayloadBytes,
               let remoteFiles = try? JSONDecoder().decode([SandboxFile].self, from: existingPayload),
               Self.isValid(files: remoteFiles, entryPoint: (existingRecord["entryPoint"] as? String) ?? workspace.entryPointPath) {
                let remoteWorkspace = SandboxWorkspace(
                    id: workspace.id,
                    name: (existingRecord["name"] as? String) ?? workspace.name,
                    files: remoteFiles,
                    entryPointPath: (existingRecord["entryPoint"] as? String) ?? workspace.entryPointPath,
                    lastModified: (existingRecord["lastModified"] as? Date) ?? Date.distantPast
                )
                let mergeResult = WorkspaceCRDT.merge(local: workspace, remote: remoteWorkspace)
                cachedWorkspaces[workspace.id] = mergeResult.mergedWorkspace
            } else {
                cachedWorkspaces[workspace.id] = workspace
            }
        } catch {
            recordToSave = CKRecord(recordType: "SandboxWorkspaceRecord", recordID: recordID)
            cachedWorkspaces[workspace.id] = workspace
        }
        
        let targetWorkspace = cachedWorkspaces[workspace.id] ?? workspace
        guard Self.isValid(files: targetWorkspace.files, entryPoint: targetWorkspace.entryPointPath) else {
            throw SandboxError.securityViolation("Workspace exceeds sync safety limits.")
        }
        recordToSave["name"] = targetWorkspace.name as CKRecordValue
        recordToSave["lastModified"] = targetWorkspace.lastModified as CKRecordValue
        recordToSave["entryPoint"] = targetWorkspace.entryPointPath as CKRecordValue
        
        let fileData = try JSONEncoder().encode(targetWorkspace.files)
        guard fileData.count <= Self.maxPayloadBytes else {
            throw SandboxError.securityViolation("Workspace sync payload exceeds 32 MB.")
        }
        recordToSave["filePayload"] = fileData as CKRecordValue
        
        _ = try await database.save(recordToSave)
        #else
        cachedWorkspaces[workspace.id] = workspace
        #endif
    }
    
    // MARK: - Fetch Updates
    
    /// Fetches incremental workspace updates from CloudKit.
    public func fetchLatestWorkspace(id: UUID) async throws -> SandboxWorkspace? {
        #if canImport(CloudKit)
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = try await database.record(for: recordID)
        guard let name = record["name"] as? String,
              let entryPoint = record["entryPoint"] as? String,
              let lastModified = record["lastModified"] as? Date,
              let filePayload = record["filePayload"] as? Data else {
            return nil
        }
        guard filePayload.count <= Self.maxPayloadBytes else {
            throw SandboxError.securityViolation("Remote workspace payload exceeds 32 MB.")
        }
        let files = try JSONDecoder().decode([SandboxFile].self, from: filePayload)
        guard Self.isValid(files: files, entryPoint: entryPoint) else {
            throw SandboxError.securityViolation("Remote workspace failed safety validation.")
        }
        let workspace = SandboxWorkspace(
            id: id,
            name: name,
            files: files,
            entryPointPath: entryPoint,
            lastModified: lastModified
        )
        cachedWorkspaces[id] = workspace
        return workspace
        #else
        return cachedWorkspaces[id]
        #endif
    }
    
    public func getCachedWorkspace(id: UUID) -> SandboxWorkspace? {
        cachedWorkspaces[id]
    }

    private static func isValid(files: [SandboxFile], entryPoint: String) -> Bool {
        guard files.count <= maxFileCount,
              !entryPoint.isEmpty,
              !entryPoint.hasPrefix("/"),
              !entryPoint.split(separator: "/").contains("..") else { return false }
        return files.allSatisfy { file in
            !file.path.isEmpty && file.path.utf8.count <= 512 &&
            !file.path.hasPrefix("/") && !file.path.split(separator: "/").contains("..") &&
            file.sizeInBytes <= maxFileBytes
        }
    }
}
