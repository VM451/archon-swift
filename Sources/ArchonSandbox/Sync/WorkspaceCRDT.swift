import Foundation

/// Conflict-Free Replicated Data Type (CRDT) engine implementing Last-Write-Wins (LWW) and text-delta resolution for offline workspace syncing.
public enum WorkspaceCRDT: Sendable {
    
    /// Summary report generated after resolving conflicts between two workspace replicas.
    public struct MergeResult: Sendable, Equatable {
        public let mergedWorkspace: SandboxWorkspace
        public let filesAdded: [String]
        public let filesUpdated: [String]
        public let filesPreserved: [String]
        public let conflictsResolved: Int
        
        public init(
            mergedWorkspace: SandboxWorkspace,
            filesAdded: [String],
            filesUpdated: [String],
            filesPreserved: [String],
            conflictsResolved: Int
        ) {
            self.mergedWorkspace = mergedWorkspace
            self.filesAdded = filesAdded
            self.filesUpdated = filesUpdated
            self.filesPreserved = filesPreserved
            self.conflictsResolved = conflictsResolved
        }
    }
    
    /// Merges a local workspace state with a remote workspace state using deterministic Last-Write-Wins (LWW) CRDT semantics.
    public static func merge(local: SandboxWorkspace, remote: SandboxWorkspace) -> MergeResult {
        var mergedFiles: [String: SandboxFile] = [:]
        var filesAdded: [String] = []
        var filesUpdated: [String] = []
        var filesPreserved: [String] = []
        var conflictsCount = 0
        
        // 1. Populate all local files
        for file in local.files {
            mergedFiles[file.path] = file
        }
        
        // 2. Iterate through remote files and apply LWW rules
        for remoteFile in remote.files {
            if let localFile = mergedFiles[remoteFile.path] {
                if localFile.checksum == remoteFile.checksum {
                    // Files are identical
                    filesPreserved.append(remoteFile.path)
                } else {
                    // Conflicting edits
                    conflictsCount += 1
                    if remoteFile.lastModified > localFile.lastModified {
                        // Remote is newer
                        mergedFiles[remoteFile.path] = remoteFile
                        filesUpdated.append(remoteFile.path)
                    } else {
                        // Local is newer or equal
                        mergedFiles[remoteFile.path] = localFile
                        filesPreserved.append(remoteFile.path)
                    }
                }
            } else {
                // New file from remote
                mergedFiles[remoteFile.path] = remoteFile
                filesAdded.append(remoteFile.path)
            }
        }
        
        // 3. Resolve metadata (Merge dictionaries, remote overrides on key collision if remote is newer)
        var mergedMetadata = local.metadata
        for (k, v) in remote.metadata {
            if remote.lastModified >= local.lastModified {
                mergedMetadata[k] = v
            } else if mergedMetadata[k] == nil {
                mergedMetadata[k] = v
            }
        }
        
        let newestTimestamp = max(local.lastModified, remote.lastModified)
        let resolvedName = remote.lastModified > local.lastModified ? remote.name : local.name
        let resolvedEntryPoint = remote.lastModified > local.lastModified ? remote.entryPointPath : local.entryPointPath
        
        let merged = SandboxWorkspace(
            id: local.id,
            name: resolvedName,
            files: Array(mergedFiles.values).sorted(by: { $0.path < $1.path }),
            entryPointPath: resolvedEntryPoint,
            metadata: mergedMetadata,
            createdAt: min(local.createdAt, remote.createdAt),
            lastModified: newestTimestamp
        )
        
        return MergeResult(
            mergedWorkspace: merged,
            filesAdded: filesAdded,
            filesUpdated: filesUpdated,
            filesPreserved: filesPreserved,
            conflictsResolved: conflictsCount
        )
    }
}
