import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, LocalizedError, Sendable, Hashable {
    case open(String)
    case sql(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): "无法打开数据库：\(message)"
        case .sql(let message): "数据库操作失败：\(message)"
        }
    }
}

public struct HistoryHit: Hashable, Sendable {
    public let messageID: String
    public let sessionID: String
    public let sessionTitle: String
    public let role: MessageRole
    public let createdAt: Date
    public let snippet: String
}

/// Boxes the raw SQLite handle so the actor can hold it as a Sendable value. Closing the
/// connection happens in this deinit, when the actor (and this box) are released.
private final class DBHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}

/// Conversation history, sessions and agent profiles in one SQLite file.
/// An actor, so every statement runs on one connection, one at a time.
public actor MemoryStore {
    private let db: DBHandle
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(code)"
            sqlite3_close(handle)
            throw StoreError.open(message)
        }
        // Stored properties are all Sendable, so init is nonisolated and cannot call the
        // actor-isolated helpers. Setup runs on the raw handle before it is stored.
        do {
            try Self.setUp(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        db = DBHandle(handle)
    }

    // MARK: Sessions

    public func createSession(
        mode: SessionMode = .single, principalID: String, title: String = ""
    ) throws -> ChatSession {
        let now = Date()
        let session = ChatSession(title: title, mode: mode, principalID: principalID, createdAt: now, updatedAt: now)
        try run(
            "INSERT INTO sessions (id, title, mode, principal_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text(session.id), .text(session.title), .text(session.mode.rawValue),
                .text(session.principalID), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970),
            ]
        )
        return session
    }

    public func listSessions(limit: Int = 200) throws -> [ChatSession] {
        try rows(
            "SELECT id, title, mode, principal_id, created_at, updated_at FROM sessions ORDER BY updated_at DESC LIMIT ?",
            [.int(limit)]
        ) { statement in
            ChatSession(
                id: statement.text(0),
                title: statement.text(1),
                mode: SessionMode(rawValue: statement.text(2)) ?? .single,
                principalID: statement.text(3),
                createdAt: Date(timeIntervalSince1970: statement.double(4)),
                updatedAt: Date(timeIntervalSince1970: statement.double(5))
            )
        }
    }

    public func renameSession(_ sessionID: String, title: String) throws {
        try run("UPDATE sessions SET title = ? WHERE id = ?", [.text(title), .text(sessionID)])
    }

    public func touchSession(_ sessionID: String) throws {
        try run(
            "UPDATE sessions SET updated_at = ? WHERE id = ?",
            [.real(Date().timeIntervalSince1970), .text(sessionID)]
        )
    }

    public func deleteSession(_ sessionID: String) throws {
        try transaction {
            try run("DELETE FROM messages_fts WHERE session_id = ?", [.text(sessionID)])
            try run("DELETE FROM messages WHERE session_id = ?", [.text(sessionID)])
            try run("DELETE FROM sessions WHERE id = ?", [.text(sessionID)])
        }
    }

    // MARK: Messages

    public func append(_ message: ChatMessage, to sessionID: String) throws {
        let toolCalls = message.toolCalls.isEmpty
            ? nil
            : String(decoding: try encoder.encode(message.toolCalls), as: UTF8.self)
        let now = Date().timeIntervalSince1970

        try transaction {
            try run(
                """
                INSERT INTO messages (id, session_id, seq, role, author, content, tool_calls, tool_call_id, name, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(message.id), .text(sessionID), .int(message.seq), .text(message.role.rawValue),
                    .text(message.author.storageValue), .text(message.content), .optionalText(toolCalls),
                    .optionalText(message.toolCallID), .optionalText(message.name), .real(message.createdAt.timeIntervalSince1970),
                ]
            )
            try run(
                "INSERT INTO messages_fts (message_id, session_id, body) VALUES (?, ?, ?)",
                [.text(message.id), .text(sessionID), .text(CJKText.tokenize(message.content))]
            )
            try run("UPDATE sessions SET updated_at = ? WHERE id = ?", [.real(now), .text(sessionID)])
        }
    }

    public func messages(in sessionID: String) throws -> [ChatMessage] {
        try rows(
            """
            SELECT id, seq, role, author, content, tool_calls, tool_call_id, name, created_at
            FROM messages WHERE session_id = ? ORDER BY seq
            """,
            [.text(sessionID)]
        ) { statement in
            let toolCalls = statement.optionalText(5).flatMap { text in
                try? decoder.decode([ToolCall].self, from: Data(text.utf8))
            }
            return ChatMessage(
                id: statement.text(0),
                seq: statement.int(1),
                role: MessageRole(rawValue: statement.text(2)) ?? .user,
                author: Author(storageValue: statement.text(3)),
                content: statement.text(4),
                toolCalls: toolCalls ?? [],
                toolCallID: statement.optionalText(6),
                name: statement.optionalText(7),
                createdAt: Date(timeIntervalSince1970: statement.double(8))
            )
        }
    }

    /// Newest `limit` messages, still returned oldest-first so it can be appended directly.
    /// `beforeSeq` pages further back. Long sessions are never loaded in full.
    public func recentMessages(
        in sessionID: String, limit: Int = 200, beforeSeq: Int? = nil
    ) throws -> [ChatMessage] {
        let upper = beforeSeq ?? Int.max
        let rows = try rows(
            """
            SELECT id, seq, role, author, content, tool_calls, tool_call_id, name, created_at
            FROM messages WHERE session_id = ? AND seq < ? ORDER BY seq DESC LIMIT ?
            """,
            [.text(sessionID), .int(upper), .int(limit)]
        ) { statement in
            let toolCalls = statement.optionalText(5).flatMap { text in
                try? decoder.decode([ToolCall].self, from: Data(text.utf8))
            }
            return ChatMessage(
                id: statement.text(0),
                seq: statement.int(1),
                role: MessageRole(rawValue: statement.text(2)) ?? .user,
                author: Author(storageValue: statement.text(3)),
                content: statement.text(4),
                toolCalls: toolCalls ?? [],
                toolCallID: statement.optionalText(6),
                name: statement.optionalText(7),
                createdAt: Date(timeIntervalSince1970: statement.double(8))
            )
        }
        return rows.reversed()
    }

    public func maxSeq(in sessionID: String) throws -> Int {
        try rows("SELECT COALESCE(MAX(seq), -1) FROM messages WHERE session_id = ?", [.text(sessionID)]) {
            $0.int(0)
        }.first ?? -1
    }

    /// Full-text search across every session, best matches first.
    public func searchHistory(_ text: String, limit: Int = 8) throws -> [HistoryHit] {
        guard let match = CJKText.ftsQuery(text) else { return [] }
        return try rows(
            """
            SELECT m.id, m.session_id, COALESCE(s.title, ''), m.role, m.created_at,
                   snippet(messages_fts, 2, '', '', '…', 40)
            FROM messages_fts JOIN messages m ON m.id = messages_fts.message_id
            LEFT JOIN sessions s ON s.id = m.session_id
            WHERE messages_fts MATCH ?1
            ORDER BY bm25(messages_fts)
            LIMIT ?2
            """,
            [.text(match), .int(limit)]
        ) { statement in
            HistoryHit(
                messageID: statement.text(0),
                sessionID: statement.text(1),
                sessionTitle: statement.text(2),
                role: MessageRole(rawValue: statement.text(3)) ?? .user,
                createdAt: Date(timeIntervalSince1970: statement.double(4)),
                snippet: CJKText.detokenize(statement.text(5))
            )
        }
    }

    // MARK: Agents

    public func agents() throws -> [AgentProfile] {
        try rows("SELECT id, name, instructions, model, created_at FROM agents ORDER BY created_at, id") { statement in
            AgentProfile(
                id: statement.text(0),
                name: statement.text(1),
                instructions: statement.text(2),
                model: statement.optionalText(3),
                createdAt: Date(timeIntervalSince1970: statement.double(4))
            )
        }
    }

    public func upsertAgent(_ profile: AgentProfile) throws {
        try run(
            """
            INSERT INTO agents (id, name, instructions, model, created_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, instructions = excluded.instructions, model = excluded.model
            """,
            [
                .text(profile.id), .text(profile.name), .text(profile.instructions),
                .optionalText(profile.model?.trimmingCharacters(in: .whitespaces).nilIfEmpty),
                .real(profile.createdAt.timeIntervalSince1970),
            ]
        )
    }

    public func deleteAgent(id: String) throws {
        try run("DELETE FROM agents WHERE id = ?", [.text(id)])
    }

    // MARK: Conversation summary

    public func summary(for sessionID: String) throws -> ConversationSummary? {
        let found = try rows(
            "SELECT summary, summary_through_seq FROM sessions WHERE id = ?",
            [.text(sessionID)]
        ) { statement in
            statement.optionalText(0).map {
                ConversationSummary(text: $0, throughSeq: statement.int(1))
            }
        }
        return found.first ?? nil
    }

    public func saveSummary(_ summary: ConversationSummary, for sessionID: String) throws {
        try run(
            "UPDATE sessions SET summary = ?, summary_through_seq = ? WHERE id = ?",
            [.text(summary.text), .int(summary.throughSeq), .text(sessionID)]
        )
    }

    // MARK: Setup (nonisolated; runs before the handle is stored)

    private static func setUp(_ db: OpaquePointer) throws {
        sqlite3_busy_timeout(db, 2_000)
        try exec(db, "PRAGMA journal_mode=WAL")
        try exec(db, "PRAGMA foreign_keys=ON")
        try exec(db, schemaSQL)
        try addSummaryColumnsIfNeeded(db)
        try seed(db)
    }

    /// Databases created before summaries existed get the columns added in place.
    private static func addSummaryColumnsIfNeeded(_ db: OpaquePointer) throws {
        let columns = try query(db, "PRAGMA table_info(sessions)") { $0.text(1) }
        if !columns.contains("summary") {
            try exec(db, "ALTER TABLE sessions ADD COLUMN summary TEXT")
        }
        if !columns.contains("summary_through_seq") {
            try exec(db, "ALTER TABLE sessions ADD COLUMN summary_through_seq INTEGER NOT NULL DEFAULT 0")
        }
    }

    private static func seed(_ db: OpaquePointer) throws {
        let statement = try Statement("SELECT COUNT(*) FROM agents", on: db)
        _ = try statement.step()
        guard statement.int(0) == 0 else { return }

        let fallback = AgentProfile.makeDefault()
        try run(
            db,
            "INSERT INTO agents (id, name, instructions, model, created_at) VALUES (?, ?, ?, NULL, ?)",
            [.text(fallback.id), .text(fallback.name), .text(fallback.instructions), .real(Date().timeIntervalSince1970)]
        )
    }

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            mode TEXT NOT NULL DEFAULT 'single',
            principal_id TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            summary TEXT,
            summary_through_seq INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            role TEXT NOT NULL,
            author TEXT NOT NULL,
            content TEXT NOT NULL DEFAULT '',
            tool_calls TEXT,
            tool_call_id TEXT,
            name TEXT,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS messages_session_seq ON messages(session_id, seq);
        CREATE TABLE IF NOT EXISTS agents (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            instructions TEXT NOT NULL DEFAULT '',
            model TEXT,
            created_at REAL NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            message_id UNINDEXED, session_id UNINDEXED, body, tokenize='unicode61'
        );
        """

    // MARK: Isolated statement helpers

    private func execute(_ sql: String) throws {
        try Self.exec(db.pointer, sql)
    }

    private func run(_ sql: String, _ values: [Statement.Value?] = []) throws {
        let statement = try Statement(sql, on: db.pointer)
        try statement.bind(values)
        _ = try statement.step()
    }

    private func rows<T>(
        _ sql: String, _ values: [Statement.Value?] = [], _ map: (Statement) throws -> T
    ) throws -> [T] {
        try Self.query(db.pointer, sql, values, map)
    }

    private static func query<T>(
        _ db: OpaquePointer, _ sql: String, _ values: [Statement.Value?] = [], _ map: (Statement) throws -> T
    ) throws -> [T] {
        let statement = try Statement(sql, on: db)
        try statement.bind(values)
        var result: [T] = []
        while try statement.step() {
            result.append(try map(statement))
        }
        return result
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Nonisolated statement helpers (also used by setUp)

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.sql(message)
        }
    }

    private static func run(_ db: OpaquePointer, _ sql: String, _ values: [Statement.Value?] = []) throws {
        let statement = try Statement(sql, on: db)
        try statement.bind(values)
        _ = try statement.step()
    }

    private final class Statement {
        enum Value {
            case text(String)
            case int(Int)
            case real(Double)

            static func optionalText(_ text: String?) -> Value? {
                text.map { .text($0) }
            }
        }

        private let handle: OpaquePointer
        private let db: OpaquePointer

        init(_ sql: String, on db: OpaquePointer) throws {
            var handle: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let handle else {
                throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
            }
            self.handle = handle
            self.db = db
        }

        deinit {
            sqlite3_finalize(handle)
        }

        func bind(_ values: [Value?]) throws {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case nil: sqlite3_bind_null(handle, index)
                case .text(let text): sqlite3_bind_text(handle, index, text, -1, sqliteTransient)
                case .int(let number): sqlite3_bind_int64(handle, index, sqlite3_int64(number))
                case .real(let number): sqlite3_bind_double(handle, index, number)
                }
            }
        }

        /// Returns true when a row is available.
        func step() throws -> Bool {
            switch sqlite3_step(handle) {
            case SQLITE_ROW: true
            case SQLITE_DONE: false
            default: throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
            }
        }

        func text(_ index: Int32) -> String {
            sqlite3_column_text(handle, index).map { String(cString: $0) } ?? ""
        }

        func optionalText(_ index: Int32) -> String? {
            sqlite3_column_type(handle, index) == SQLITE_NULL ? nil : text(index)
        }

        func int(_ index: Int32) -> Int {
            Int(sqlite3_column_int64(handle, index))
        }

        func double(_ index: Int32) -> Double {
            sqlite3_column_double(handle, index)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
