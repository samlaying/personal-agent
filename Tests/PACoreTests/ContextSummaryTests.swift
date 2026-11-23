import Foundation
import Testing
@testable import PACore

/// A client that answers summarization requests differently from normal ones, and
/// records what it was sent.
final class RecordingClient: ModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ChatRequest] = []

    var summaryText: String
    var answer: String
    var failSummarization: Bool

    init(summaryText: String = "- 用户想要一份周报", answer: String = "好的", failSummarization: Bool = false) {
        self.summaryText = summaryText
        self.answer = answer
        self.failSummarization = failSummarization
    }

    var requests: [ChatRequest] {
        lock.withLock { recorded }
    }

    func isSummarizationRequest(_ request: ChatRequest) -> Bool {
        request.tools.isEmpty
            && request.messages.first?.content?.contains("上下文压缩助手") == true
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock { recorded.append(request) }
        let summarizing = isSummarizationRequest(request)
        return AsyncThrowingStream { continuation in
            Task {
                if summarizing && self.failSummarization {
                    continuation.finish(throwing: ProviderError.http(status: 500, message: "boom"))
                    return
                }
                continuation.yield(.textDelta(summarizing ? self.summaryText : self.answer))
                continuation.yield(.finish(reason: "stop"))
                continuation.finish()
            }
        }
    }
}

struct ContextSummarizerTests {
    private func message(_ seq: Int, _ role: MessageRole, _ content: String, name: String? = nil) -> ChatMessage {
        ChatMessage(seq: seq, role: role, author: role == .user ? .user : .agent("a"), content: content, name: name)
    }

    @Test func rendersEveryRoleAndSkipsEmpty() async throws {
        let client = RecordingClient(summaryText: "要点")
        var summarizer = ContextSummarizer()
        summarizer.maxInputChars = 10_000

        let dropped = [
            message(1, .user, "帮我写周报"),
            message(2, .assistant, ""),
            message(3, .assistant, "好的", name: nil),
            message(4, .tool, "文件已写入", name: "write_file"),
        ]
        let summary = try await summarizer.summarize(existing: "", dropped: dropped, client: client, model: "m")
        #expect(summary == "要点")

        let prompt = try #require(client.requests.first?.messages.last?.content)
        #expect(prompt.contains("用户：帮我写周报"))
        #expect(prompt.contains("工具 write_file 返回：文件已写入"))
        #expect(!prompt.contains("已有摘要"))
    }

    @Test func keepsTailWhenInputTooLong() async throws {
        let client = RecordingClient(summaryText: "要点")
        var summarizer = ContextSummarizer()
        summarizer.maxInputChars = 60

        let dropped = (1...20).map { message($0, .user, "第\($0)条消息内容") }
        _ = try await summarizer.summarize(existing: "", dropped: dropped, client: client, model: "m")

        let prompt = try #require(client.requests.first?.messages.last?.content)
        #expect(prompt.contains("第20条消息内容"))
        #expect(!prompt.contains("用户：第1条消息内容"))
    }

    @Test func mergesExistingSummaryIntoThePrompt() async throws {
        let client = RecordingClient(summaryText: "新要点")
        let summarizer = ContextSummarizer()
        _ = try await summarizer.summarize(
            existing: "旧要点：用户在做简历筛选",
            dropped: [message(9, .user, "继续")],
            client: client,
            model: "m"
        )
        let prompt = try #require(client.requests.first?.messages.last?.content)
        #expect(prompt.contains("旧要点：用户在做简历筛选"))
        #expect(prompt.contains("新增对话"))
    }

    @Test func emptyDroppedThrows() async {
        let client = RecordingClient()
        let summarizer = ContextSummarizer()
        await #expect(throws: (any Error).self) {
            _ = try await summarizer.summarize(existing: "", dropped: [], client: client, model: "m")
        }
    }
}

struct AgentRunnerSummaryTests {
    private func history(count: Int, chars: Int) -> [ChatMessage] {
        (1...count).map { index in
            ChatMessage(
                seq: index,
                role: index.isMultiple(of: 2) ? .assistant : .user,
                author: index.isMultiple(of: 2) ? .agent("assistant") : .user,
                content: String(repeating: "字", count: chars) + "#\(index);"
            )
        }
    }

    private func runner(_ client: any ModelClient, budget: Int) -> AgentRunner {
        var runner = AgentRunner(
            client: client,
            tools: ToolRegistry([]),
            prompt: PromptContext(environmentSummary: "macOS 测试机"),
            defaultModel: "m"
        )
        runner.transcriptBudgetChars = budget
        return runner
    }

    private func run(_ runner: AgentRunner, history: [ChatMessage], summary: ConversationSummary? = nil) async -> (events: [String], text: String) {
        var events: [String] = []
        var text = ""
        let request = RunRequest(
            profile: .makeDefault(),
            history: history,
            input: "继续",
            sessionID: "s",
            summary: summary
        )
        for await event in runner.events(for: request) {
            switch event {
            case .textDelta(let fragment):
                text += fragment
            case .summaryUpdated(let summary):
                events.append("summary:\(summary.throughSeq)")
            case .note(let note):
                events.append("note:\(note)")
            case .finished(let reason):
                events.append("finished:\(reason)")
            default:
                break
            }
        }
        return (events, text)
    }

    @Test func overBudgetHistoryIsSummarizedInsteadOfDropped() async throws {
        let client = RecordingClient(summaryText: "- 之前的要点", answer: "收到")
        let agent = runner(client, budget: 1_200)
        let full = history(count: 12, chars: 300)

        let result = await run(agent, history: full)
        #expect(result.text == "收到")
        #expect(result.events.contains { $0.hasPrefix("summary:") })

        #expect(client.requests.count == 2, "一次压缩请求 + 一次正式请求")
        let summarization = client.requests[0]
        #expect(client.isSummarizationRequest(summarization))

        let main = client.requests[1]
        #expect(!client.isSummarizationRequest(main))
        let system = try #require(main.messages.first?.content)
        #expect(system.contains("更早的对话（摘要）"))
        #expect(system.contains("- 之前的要点"))

        // Dropped messages must not appear in the request that follows.
        let sent = main.messages.compactMap(\.content).joined()
        #expect(!sent.contains("#1;"))

        let summaryEvent = result.events.first { $0.hasPrefix("summary:") }
        let throughSeq = Int(try #require(summaryEvent).dropFirst("summary:".count))
        #expect((throughSeq ?? 0) > 0)
        #expect((throughSeq ?? 0) < 12)
    }

    @Test func existingSummaryIsReusedWithoutPayingAgain() async throws {
        let client = RecordingClient(answer: "好的")
        let agent = runner(client, budget: 5_000)
        // seq 1...4 already summarized; only the rest is sent.
        let full = history(count: 8, chars: 40)
        let summary = ConversationSummary(text: "旧摘要", throughSeq: 4)

        let result = await run(agent, history: full, summary: summary)
        #expect(result.text == "好的")
        #expect(!result.events.contains { $0.hasPrefix("summary:") }, "没有新增溢出时不应再压缩")
        #expect(client.requests.count == 1)

        let system = try #require(client.requests[0].messages.first?.content)
        #expect(system.contains("旧摘要"))
        let sent = client.requests[0].messages.compactMap(\.content).joined()
        #expect(!sent.contains("#2;"))
        #expect(sent.contains("#5;"))
    }

    @Test func summarizationFailureFallsBackToPlainTrimming() async throws {
        let client = RecordingClient(answer: "仍然可以回答", failSummarization: true)
        let agent = runner(client, budget: 800)

        let result = await run(agent, history: history(count: 10, chars: 300))
        #expect(result.text == "仍然可以回答")
        #expect(result.events.contains { $0.contains("压缩失败") })
        #expect(!result.events.contains { $0.hasPrefix("summary:") })
    }
}

struct SystemPromptSummaryTests {
    @Test func includesEarlierSummarySection() {
        let prompt = SystemPrompt.make(
            profile: .makeDefault(),
            context: PromptContext(earlierSummary: "用户在做简历筛选，已排除 3 家公司"),
            toolNames: ["read_file"],
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(prompt.contains("更早的对话（摘要）"))
        #expect(prompt.contains("已排除 3 家公司"))
    }
}
