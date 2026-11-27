import Testing
import Foundation
import SQLite3
@testable import PACore

struct MemoryStoreTests {
    private static func makeStore() throws -> (MemoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pa-tests-\(UUID().uuidString)", isDirectory: true)
        let store = try MemoryStore(url: directory.appendingPathComponent("memory.sqlite"))
        return (store, directory)
    }

    @Test func sessionsAndMessagesRoundTrip() async throws {
        let (store, _) = try Self.makeStore()
        let session = try await store.createSession(principalID: "assistant", title: "测试会话")

        try await store.append(ChatMessage(role: .user, author: .user, content: "你好世界"), to: session.id)
        try await store.append(
            ChatMessage(
                role: .assistant, author: .agent("assistant"), content: "这是回答",
                toolCalls: [ToolCall(id: "c1", name: "get_current_time", arguments: "{}")]
            ),
            to: session.id
        )
        try await store.append(
            ChatMessage(role: .tool, author: .agent("assistant"), content: "10:00", toolCallID: "c1", name: "get_current_time"),
            to: session.id
        )

        let messages = try await store.messages(in: session.id)
        #expect(messages.count == 3)
        #expect(messages.map(\.role) == [.user, .assistant, .tool])
        #expect(messages[1].toolCalls[0].name == "get_current_time")
        #expect(messages[2].toolCallID == "c1")

        let sessions = try await store.listSessions()
        #expect(sessions.count == 1)
        #expect(sessions[0].displayTitle == "测试会话")
    }

    @Test func recentMessagesPagesBackwards() async throws {
        let (store, _) = try Self.makeStore()
        let session = try await store.createSession(principalID: "assistant")
        for index in 0..<450 {
            try await store.append(
                ChatMessage(seq: index, role: .user, author: .user, content: "消息 \(index)"),
                to: session.id
            )
        }

        let last = try await store.recentMessages(in: session.id, limit: 200)
        #expect(last.count == 200)
        #expect(last.first?.seq == 250)      // oldest of the page
        #expect(last.last?.seq == 449)       // newest overall
        #expect(last.map(\.seq) == (250...449).map { $0 })   // still ascending

        let earlier = try await store.recentMessages(in: session.id, limit: 200, beforeSeq: 250)
        #expect(earlier.count == 200)
        #expect(earlier.first?.seq == 50)
        #expect(earlier.last?.seq == 249)

        let oldest = try await store.recentMessages(in: session.id, limit: 200, beforeSeq: 50)
        #expect(oldest.count == 50)          // 0...49
        #expect(oldest.first?.seq == 0)
    }

    @Test func maxSeqReportsTheHighWaterMark() async throws {
        let (store, _) = try Self.makeStore()
        let session = try await store.createSession(principalID: "assistant")
        #expect(try await store.maxSeq(in: session.id) == -1)
        for index in 0..<5 {
            try await store.append(ChatMessage(seq: index, role: .user, author: .user, content: "m"), to: session.id)
        }
        #expect(try await store.maxSeq(in: session.id) == 4)
    }

    @Test func chineseFullTextSearch() async throws {
        let (store, _) = try Self.makeStore()
        let session = try await store.createSession(principalID: "assistant", title: "搜索会话")
        try await store.append(ChatMessage(role: .user, author: .user, content: "我最喜欢的咖啡店在徐汇区"), to: session.id)
        try await store.append(ChatMessage(role: .assistant, author: .agent("assistant"), content: "今天天气不错适合散步"), to: session.id)

        let hits = try await store.searchHistory("徐汇")
        #expect(hits.count == 1)
        #expect(hits[0].sessionTitle == "搜索会话")
        #expect(hits[0].snippet.contains("徐汇区"))

        let weather = try await store.searchHistory("天气")
        #expect(weather.count == 1)
        #expect(weather[0].role == .assistant)

        let english = try await store.searchHistory("coffee shop")
        #expect(english.isEmpty)
    }

    @Test func deleteSessionRemovesEverything() async throws {
        let (store, _) = try Self.makeStore()
        let session = try await store.createSession(principalID: "assistant")
        try await store.append(ChatMessage(role: .user, author: .user, content: "被删除的内容xyz"), to: session.id)
        #expect(try await store.searchHistory("删除的内容").count == 1)

        try await store.deleteSession(session.id)
        #expect(try await store.listSessions().isEmpty)
        #expect(try await store.messages(in: session.id).isEmpty)
        #expect(try await store.searchHistory("删除的内容").isEmpty)
    }

    @Test func defaultAgentIsSeededAndAgentsRoundTrip() async throws {        let (store, _) = try Self.makeStore()

        let seeded = try await store.agents()
        #expect(seeded.count == 1)
        #expect(seeded[0].id == AgentProfile.defaultID)

        var custom = AgentProfile(id: "writer", name: "写作助手", instructions: "帮我写东西", model: "m2")
        try await store.upsertAgent(custom)
        var agents = try await store.agents()
        #expect(agents.count == 2)

        custom.instructions = "改过的指令"
        try await store.upsertAgent(custom)
        agents = try await store.agents()
        #expect(agents.first { $0.id == "writer" }?.instructions == "改过的指令")

        try await store.deleteAgent(id: "writer")
        #expect(try await store.agents().count == 1)
    }
}

struct KeychainStoreTests {
    @Test func writeReadDelete() throws {
        let service = "pa.tests.\(UUID().uuidString)"
        defer { try? KeychainStore.delete(service: service, account: "k") }

        #expect(try KeychainStore.read(service: service, account: "k") == nil)
        try KeychainStore.write("秘密", service: service, account: "k")
        #expect(try KeychainStore.read(service: service, account: "k") == "秘密")
        try KeychainStore.write("新值", service: service, account: "k")
        #expect(try KeychainStore.read(service: service, account: "k") == "新值")
        try KeychainStore.delete(service: service, account: "k")
        #expect(try KeychainStore.read(service: service, account: "k") == nil)
        try KeychainStore.delete(service: service, account: "k")
    }
}

struct MemoryFilesTests {
    @Test func ensureTemplatesAndAppend() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pa-files-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try MemoryFiles.ensure(in: directory)
        #expect(FileManager.default.fileExists(atPath: MemoryFiles.url(for: MemoryFiles.userProfile, in: directory).path))

        try MemoryFiles.append(line: "用户喜欢喝拿铁", to: MemoryFiles.userProfile, in: directory)
        let raw = MemoryFiles.read(MemoryFiles.userProfile, in: directory)
        #expect(raw.contains("用户喜欢喝拿铁"))

        let snippet = MemoryFiles.promptSnippet(raw)
        #expect(snippet.contains("用户喜欢喝拿铁"))
        #expect(!snippet.contains("<!--"))
        #expect(!snippet.contains("#"))
    }
}

struct ConversationSummaryStoreTests {
    private static func makeStore(at url: URL) throws -> MemoryStore {
        try MemoryStore(url: url)
    }

    @Test func summaryRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pa-summary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Self.makeStore(at: directory.appendingPathComponent("m.sqlite"))

        let session = try await store.createSession(principalID: "assistant")
        #expect(try await store.summary(for: session.id) == nil)

        try await store.saveSummary(ConversationSummary(text: "第一条摘要", throughSeq: 4), for: session.id)
        let first = try await store.summary(for: session.id)
        #expect(first?.text == "第一条摘要")
        #expect(first?.throughSeq == 4)

        try await store.saveSummary(ConversationSummary(text: "第二条摘要", throughSeq: 9), for: session.id)
        let second = try await store.summary(for: session.id)
        #expect(second?.text == "第二条摘要")
        #expect(second?.throughSeq == 9)
    }

    /// A database created before summaries existed must gain the columns in place.
    @Test func traceRoundTrip() async throws {
        let store = try MemoryStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("pa-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("memory.sqlite"))
        let session = try await store.createSession(principalID: "assistant")

        var payload = TracePayload(route: "agent", model: "mock-model", temperature: 0.3)
        payload.steps = [TraceStep(name: "载入历史", detail: "2 条", durationMs: 1.5)]
        payload.systemSections = [TraceSection(title: "身份", source: "profile", text: "你是助理")]
        payload.messages = [TraceMessage(role: "user", seq: 0, text: "你好")]
        payload.budget = ["预算字符": "60000"]
        try await store.saveTrace(payload, sessionID: session.id)

        let summaries = try await store.traceSummaries()
        #expect(summaries.count == 1)
        #expect(summaries[0].model == "mock-model")
        #expect(summaries[0].route == "agent")
        #expect(summaries[0].sessionID == session.id)
        #expect(summaries[0].promptChars == 6)   // 你好(2) + 身份段(4)

        let loaded = try await store.tracePayload(id: summaries[0].id)
        #expect(loaded == payload)

        // 删除会话连轨迹一起删
        try await store.deleteSession(session.id)
        #expect(try await store.traceSummaries().isEmpty)
    }

    @Test func legacyDatabaseIsMigrated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pa-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("m.sqlite")

        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let legacy = """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                mode TEXT NOT NULL DEFAULT 'single',
                principal_id TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE messages (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                seq INTEGER NOT NULL,
                role TEXT NOT NULL,
                author TEXT NOT NULL,
                content TEXT NOT NULL DEFAULT '',
                tool_calls TEXT,
                tool_call_id TEXT,
                name TEXT,
                created_at REAL NOT NULL
            );
            CREATE TABLE agents (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                instructions TEXT NOT NULL DEFAULT '',
                model TEXT,
                created_at REAL NOT NULL
            );
            """
        #expect(sqlite3_exec(handle, legacy, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let store = try Self.makeStore(at: url)
        let session = try await store.createSession(principalID: "assistant")
        try await store.saveSummary(ConversationSummary(text: "迁移后的摘要", throughSeq: 2), for: session.id)
        let loaded = try await store.summary(for: session.id)
        #expect(loaded?.text == "迁移后的摘要")
        #expect(loaded?.throughSeq == 2)
    }
}
