import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

private final class SQLiteHandle: @unchecked Sendable {
    var dbPointer: OpaquePointer?

    init(path: String) {
        #if canImport(SQLite3)
        var db: OpaquePointer?
        if sqlite3_open(path, &db) == SQLITE_OK {
            let createTableSQL = """
            CREATE TABLE IF NOT EXISTS checkpoints (
                id TEXT PRIMARY KEY,
                checkpoint_id TEXT,
                thread_id TEXT,
                run_id TEXT,
                node_id TEXT,
                step_index INTEGER,
                timestamp REAL,
                state_data BLOB,
                is_interrupted INTEGER,
                interrupt_message TEXT,
                metadata TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_thread_step ON checkpoints(thread_id, step_index);
            """
            sqlite3_exec(db, createTableSQL, nil, nil, nil)
        }
        self.dbPointer = db
        #else
        self.dbPointer = nil
        #endif
    }

    deinit {
        #if canImport(SQLite3)
        if let db = dbPointer {
            sqlite3_close(db)
        }
        #endif
    }
}

/// Robust, native SQLite3 checkpointer providing file-backed state persistence
/// on iOS and macOS with zero external C/Python dependencies.
public actor SQLiteCheckpointer: StateCheckpointer {
    private let handle: SQLiteHandle
    private let databasePath: String

    public init(databasePath: String = "") {
        if databasePath.isEmpty {
            let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            let dir = paths.first ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.databasePath = dir.appendingPathComponent("archon_checkpoints.sqlite").path
        } else {
            self.databasePath = databasePath
        }

        self.handle = SQLiteHandle(path: self.databasePath)
    }

    public func save(record: CheckpointRecord) async throws {
        #if canImport(SQLite3)
        guard let db = handle.dbPointer else {
            throw GraphError.stateDeserializationFailed("SQLite database is not open.")
        }

        let insertSQL = """
        INSERT OR REPLACE INTO checkpoints (
            id, checkpoint_id, thread_id, run_id, node_id, step_index,
            timestamp, state_data, is_interrupted, interrupt_message, metadata
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
            let metaJson = (try? JSONSerialization.data(withJSONObject: record.metadata)) ?? Data()
            let metaString = String(data: metaJson, encoding: .utf8) ?? "{}"

            sqlite3_bind_text(statement, 1, (record.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (record.checkpointId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (record.threadId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (record.runId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 5, (record.nodeId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 6, Int32(record.stepIndex))
            sqlite3_bind_double(statement, 7, record.timestamp.timeIntervalSince1970)

            let protectedState = try CheckpointStateProtector.seal(record.stateData)
            _ = protectedState.withUnsafeBytes { rawBufferPointer in
                sqlite3_bind_blob(statement, 8, rawBufferPointer.baseAddress, Int32(protectedState.count), nil)
            }

            sqlite3_bind_int(statement, 9, record.isInterrupted ? 1 : 0)

            if let msg = record.interruptMessage {
                sqlite3_bind_text(statement, 10, (msg as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 10)
            }

            sqlite3_bind_text(statement, 11, (metaString as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                let err = String(cString: sqlite3_errmsg(db))
                sqlite3_finalize(statement)
                throw GraphError.stateDeserializationFailed("SQLite insert failed: \(err)")
            }
            sqlite3_finalize(statement)
        }
        #endif
    }

    public func getLatest<S: AgentState>(threadId: String, as type: S.Type) async throws -> TypedCheckpoint<S>? {
        let history = try await getHistory(threadId: threadId)
        guard let latest = history.last else {
            return nil
        }
        let decodedState = try latest.decodeState(as: S.self)
        return TypedCheckpoint(
            checkpointId: latest.checkpointId,
            threadId: latest.threadId,
            runId: latest.runId,
            nodeId: latest.nodeId,
            stepIndex: latest.stepIndex,
            timestamp: latest.timestamp,
            state: decodedState,
            isInterrupted: latest.isInterrupted,
            interruptMessage: latest.interruptMessage,
            metadata: latest.metadata
        )
    }

    public func getHistory(threadId: String) async throws -> [CheckpointRecord] {
        #if canImport(SQLite3)
        guard let db = handle.dbPointer else {
            throw GraphError.stateDeserializationFailed("SQLite database is not open.")
        }

        let selectSQL = """
        SELECT id, checkpoint_id, thread_id, run_id, node_id, step_index,
               timestamp, state_data, is_interrupted, interrupt_message, metadata
        FROM checkpoints
        WHERE thread_id = ?
        ORDER BY step_index ASC;
        """

        var statement: OpaquePointer?
        var results: [CheckpointRecord] = []

        if sqlite3_prepare_v2(db, selectSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (threadId as NSString).utf8String, -1, nil)

            while sqlite3_step(statement) == SQLITE_ROW {
                let checkpointId = String(cString: sqlite3_column_text(statement, 1))
                let thread = String(cString: sqlite3_column_text(statement, 2))
                let runId = String(cString: sqlite3_column_text(statement, 3))
                let nodeId = String(cString: sqlite3_column_text(statement, 4))
                let step = Int(sqlite3_column_int(statement, 5))
                let time = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))

                let blobPtr = sqlite3_column_blob(statement, 7)
                let blobBytes = sqlite3_column_bytes(statement, 7)
                let encryptedState = blobPtr != nil ? Data(bytes: blobPtr!, count: Int(blobBytes)) : Data()
                let stateData = try CheckpointStateProtector.open(encryptedState)

                let interrupted = sqlite3_column_int(statement, 8) == 1
                var interruptMsg: String? = nil
                if let msgPtr = sqlite3_column_text(statement, 9) {
                    interruptMsg = String(cString: msgPtr)
                }

                var meta: [String: String] = [:]
                if let metaPtr = sqlite3_column_text(statement, 10) {
                    let metaStr = String(cString: metaPtr)
                    if let metaData = metaStr.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: metaData) as? [String: String] {
                        meta = parsed
                    }
                }

                let rec = CheckpointRecord(
                    checkpointId: checkpointId,
                    threadId: thread,
                    runId: runId,
                    nodeId: nodeId,
                    stepIndex: step,
                    timestamp: time,
                    stateData: stateData,
                    isInterrupted: interrupted,
                    interruptMessage: interruptMsg,
                    metadata: meta
                )
                results.append(rec)
            }
            sqlite3_finalize(statement)
        }
        return results
        #else
        return []
        #endif
    }

    public func deleteThread(threadId: String) async throws {
        #if canImport(SQLite3)
        guard let db = handle.dbPointer else { return }
        let deleteSQL = "DELETE FROM checkpoints WHERE thread_id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (threadId as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        #endif
    }

    public func fork(threadId: String, fromCheckpointId: String, newThreadId: String) async throws -> CheckpointRecord {
        let history = try await getHistory(threadId: threadId)
        guard let target = history.first(where: { $0.checkpointId == fromCheckpointId }) else {
            throw GraphError.graphHalted(reason: "Checkpoint '\(fromCheckpointId)' not found in SQLite.")
        }

        let forked = CheckpointRecord(
            checkpointId: UUID().uuidString,
            threadId: newThreadId,
            runId: UUID().uuidString,
            nodeId: target.nodeId,
            stepIndex: 0,
            timestamp: Date(),
            stateData: target.stateData,
            isInterrupted: false,
            interruptMessage: nil,
            metadata: target.metadata
        )

        try await save(record: forked)
        return forked
    }
}
