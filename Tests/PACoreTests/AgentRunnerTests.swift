import Testing
import Foundation
@testable import PACore

/// A scriptable ModelClient for runner tests that must not depend on the mock server.
/// The step for each API round is picked by counting assistant turns already in the
/// transcript: round 0 (system+user only) takes steps[0], the round after one tool
/// exchange takes steps[1], and so on. The last step repeats from there.
struct ScriptedClient: ModelClient {
    enum Step: Sendable {
        case text(String)
        case tool(name: String, arguments: String)
        case nothing
    }

    var steps: [Step]

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let assistantTurns = request.messages.filter { $0.role == .assistant }.count
        let step = steps[min(assistantTurns, steps.count - 1)]
        return AsyncThrowingStream { continuation in
            Task {
                switch step {
                case .text(let text):
                    continuation.yield(.textDelta(text))
                    continuation.yield(.finish(reason: "stop"))
                case .tool(let name, let arguments):
                    continuation.yield(.toolCallDelta(index: 0, id: "call_\(name)", name: name, argumentsFragment: arguments))
                    continuation.yield(.finish(reason: "tool_calls"))
                case .nothing:
                    continuation.yield(.finish(reason: "stop"))
                }
                continuation.finish()
            }
        }
    }
}

struct AgentRunnerTests {
    private func runner(
        _ client: any ModelClient,
        tools: [any AgentTool],
        maxSteps: Int = 12
    ) -> AgentRunner {
        AgentRunner(
            client: client,
            tools: ToolRegistry(tools),
            prompt: PromptContext(userProfile: "", memoryNotes: "", environmentSummary: "macOS 测试机"),
            defaultModel: "mock-model",
            maxSteps: maxSteps
        )
    }

    private func run(_ agent: AgentRunner, input: String, autoApprove: Bool = true) async -> RunOutcome {
        var outcome = RunOutcome()
        for await event in agent.events(for: RunRequest(
            profile: .makeDefault(), history: [], input: input, sessionID: "s1"
        )) {
            switch event {
            case .textDelta(let fragment):
                outcome.text += fragment
            case .assistantMessage(let message):
                outcome.messages.append(message)
            case .toolMessage(let message):
                outcome.toolResults.append(message.content)
            case .approvalRequired(let request):
                outcome.approvals.append(request.call.name)
                request.ticket.resolve(autoApprove ? .allowOnce : .deny)
            case .toolFinished(_, _, let status):
                outcome.toolOutcomes.append(status)
            case .toolStarted, .reasoningDelta, .note, .summaryUpdated:
                break
            case .finished(let reason):
                outcome.finish = reason
            }
        }
        return outcome
    }

    struct RunOutcome {
        var text = ""
        var messages: [ChatMessage] = []
        var toolResults: [String] = []
        var toolOutcomes: [ToolOutcome] = []
        var approvals: [String] = []
        var finish: FinishReason?
    }

    @Test func plainTextRun() async {
        let agent = runner(ScriptedClient(steps: [.text("你好，我是助手")]), tools: [])
        let outcome = await run(agent, input: "打个招呼")
        #expect(outcome.text == "你好，我是助手")
        #expect(outcome.messages.count == 1)
        #expect(outcome.finish == .completed)
    }

    @Test func toolLoopReachesFinalAnswer() async {
        let agent = runner(
            ScriptedClient(steps: [.tool(name: "get_current_time", arguments: "{}"), .text("时间已经查好了")]),
            tools: [CurrentTimeTool()]
        )
        let outcome = await run(agent, input: "现在几点")
        #expect(outcome.approvals.isEmpty, "只读工具不应请求批准")
        #expect(outcome.toolOutcomes == [.ok])
        #expect(outcome.toolResults.count == 1)
        #expect(!outcome.toolResults[0].isEmpty)
        #expect(outcome.text == "时间已经查好了")
        #expect(outcome.finish == .completed)
    }

    @Test func writeToolRequiresApproval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pa-runner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("out.txt").path
        let agent = runner(
            ScriptedClient(steps: [
                .tool(name: "write_file", arguments: #"{"path":"\#(target)","content":"写点东西"}"#),
                .text("写完了"),
            ]),
            tools: [WriteFileTool()]
        )
        let outcome = await run(agent, input: "帮我写文件")
        #expect(outcome.approvals == ["write_file"])
        #expect(outcome.toolOutcomes == [.ok])
        let written = try String(contentsOf: URL(fileURLWithPath: target), encoding: .utf8)
        #expect(written == "写点东西")
        #expect(outcome.finish == .completed)
    }

    @Test func denialFeedsBackToModel() async {
        let agent = runner(
            ScriptedClient(steps: [
                .tool(name: "run_shell_command", arguments: #"{"command":"echo hi"}"#),
                .text("好的，不执行了"),
            ]),
            tools: [ShellTool()]
        )
        let outcome = await run(agent, input: "执行命令", autoApprove: false)
        #expect(outcome.approvals == ["run_shell_command"])
        #expect(outcome.toolOutcomes == [.denied])
        #expect(outcome.toolResults.count == 1)
        #expect(outcome.toolResults[0].contains("拒绝"))
        #expect(outcome.text == "好的，不执行了")
        #expect(outcome.finish == .completed)
    }

    @Test func unknownToolReportsInsteadOfCrashing() async {
        let agent = runner(
            ScriptedClient(steps: [.tool(name: "no_such_tool", arguments: "{}"), .text("抱歉没有这个工具")]),
            tools: []
        )
        let outcome = await run(agent, input: "试试")
        #expect(outcome.toolOutcomes == [.error])
        #expect(outcome.toolResults.count == 1)
        #expect(outcome.toolResults[0].contains("没有名为"))
        #expect(outcome.finish == .completed)
    }

    @Test func maxStepsStopsTheLoop() async {
        let agent = runner(
            ScriptedClient(steps: [
                .tool(name: "get_current_time", arguments: "{}"),
                .tool(name: "get_current_time", arguments: "{}"),
                .tool(name: "get_current_time", arguments: "{}"),
            ]),
            tools: [CurrentTimeTool()],
            maxSteps: 3
        )
        let outcome = await run(agent, input: "一直查时间")
        #expect(outcome.finish == .maxSteps)
    }

    @Test func emptyStreamFails() async {
        let agent = runner(ScriptedClient(steps: [.nothing]), tools: [])
        let outcome = await run(agent, input: "空回复")
        #expect(outcome.finish?.errorMessage?.contains("空回复") == true)
    }

    @Test func systemPromptCarriesContextAndRules() {
        let profile = AgentProfile(id: "x", name: "小助手", instructions: "保持简短")
        let prompt = SystemPrompt.make(
            profile: profile,
            context: PromptContext(userProfile: "用户喜欢喝拿铁", memoryNotes: "上次聊过 Swift", environmentSummary: "macOS 26"),
            toolNames: ["read_file", "write_file"],
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(prompt.contains("小助手"))
        #expect(prompt.contains("保持简短"))
        #expect(prompt.contains("用户喜欢喝拿铁"))
        #expect(prompt.contains("上次聊过 Swift"))
        #expect(prompt.contains("read_file"))
        #expect(prompt.contains("不要换一种方式重试"))
        #expect(prompt.contains("当前时间"))
    }
}
