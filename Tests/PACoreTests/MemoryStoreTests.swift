import Testing
import Foundation
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

    @Test func defaultAgentIsSeededAndAgentsRoundTrip() async throws {
        let (store, _) = try Self.makeStore()

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
