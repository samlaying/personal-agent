import Testing
import Foundation
@testable import PACore

struct TranscriptBuilderTests {
    private func message(_ role: MessageRole, content: String, toolCalls: [ToolCall] = [], toolCallID: String? = nil) -> ChatMessage {
        ChatMessage(role: role, author: role == .user ? .user : .agent("a"), content: content, toolCalls: toolCalls, toolCallID: toolCallID)
    }

    @Test func keepsNewestWithinBudget() {
        // Per-message overhead is 32, so sizes are 35, 35, 37 — all inside a 120 budget.
        let history = [
            message(.user, content: "one"),
            message(.assistant, content: "two"),
            message(.user, content: "three"),
        ]
        let kept = TranscriptBuilder.trim(history, budgetChars: 120)
        #expect(kept.map(\.content) == ["one", "two", "three"])
    }

    @Test func dropsOldestFirst() {
        // Sizes 82, 82, 42. Budget 130 fits the newest two (124) but not all three (206).
        let history = [
            message(.user, content: String(repeating: "a", count: 50)),
            message(.assistant, content: String(repeating: "b", count: 50)),
            message(.user, content: String(repeating: "c", count: 10)),
        ]
        let kept = TranscriptBuilder.trim(history, budgetChars: 130)
        #expect(kept.map(\.content) == [String(repeating: "b", count: 50), String(repeating: "c", count: 10)])
    }

    @Test func orphanToolResultAtHeadIsDropped() {
        // Only the tool result fits (38 < 70); its request was trimmed away, so the
        // transcript would otherwise open with an orphan result. It must be dropped.
        let history = [
            message(.user, content: String(repeating: "a", count: 50)),
            message(.assistant, content: "", toolCalls: [ToolCall(id: "1", name: "t", arguments: String(repeating: "x", count: 60))]),
            message(.tool, content: "result", toolCallID: "1"),
        ]
        #expect(TranscriptBuilder.trim(history, budgetChars: 70).isEmpty)
    }

    @Test func completeToolPairAtHeadSurvives() {
        // Budget 175: tool (38) + assistant request (92) fit, the user message does not.
        // The request and its result stay together — that pair is valid.
        let history = [
            message(.user, content: String(repeating: "a", count: 50)),
            message(.assistant, content: "", toolCalls: [ToolCall(id: "1", name: "t", arguments: String(repeating: "x", count: 60))]),
            message(.tool, content: "result", toolCallID: "1"),
        ]
        let kept = TranscriptBuilder.trim(history, budgetChars: 175)
        #expect(kept.count == 2)
        #expect(kept[0].role == .assistant)
        #expect(kept[1].role == .tool)
    }

    @Test func singleOversizedMessageIsStillKept() {
        let history = [message(.user, content: String(repeating: "a", count: 1_000))]
        let kept = TranscriptBuilder.trim(history, budgetChars: 100)
        #expect(kept.count == 1)
    }

    @Test func emptyInput() {
        #expect(TranscriptBuilder.trim([], budgetChars: 10).isEmpty)
    }
}

struct JSONValueTests {
    @Test func roundTrip() throws {
        let original: JSONValue = ["name": "值", "count": 3, "ok": true, "tags": ["a", "b"], "none": .null]
        let parsed = try JSONValue.parse(original.encoded())
        #expect(parsed == original)
    }

    @Test func accessors() throws {
        let value = try JSONValue.parse(#"{"n": 1.5, "i": 2, "s": "x", "b": false}"#)
        #expect(value["n"]?.doubleValue == 1.5)
        #expect(value["i"]?.intValue == 2)
        #expect(value["s"]?.stringValue == "x")
        #expect(value["b"]?.boolValue == false)
        #expect(value["b"]?.doubleValue == nil, "false must decode as bool, not as 0")
        #expect(value["n"]?.boolValue == nil, "1.5 must not decode as bool")
        #expect(value.doubleValue == nil, "the document itself is an object, not a number")
    }

    @Test func schemaShape() throws {
        let schema = JSONSchema.object(
            ["path": "文件路径", "limit": .int("条数"), "flag": .bool("开关")],
            required: ["path"]
        )
        let object = schema.objectValue!
        #expect(object["type"]?.stringValue == "object")
        #expect(object["required"]?.arrayValue?.first?.stringValue == "path")
        let properties = object["properties"]!.objectValue!
        #expect(properties["limit"]?.objectValue?["type"]?.stringValue == "integer")
        #expect(properties["path"]?.objectValue?["description"]?.stringValue == "文件路径")
    }

    @Test func oneOfEnum() {
        let schema = JSONProperty.oneOf(["user", "note"], "种类").schema
        let object = schema.objectValue!
        #expect(object["enum"]?.arrayValue?.map(\.stringValue) == ["user", "note"])
    }
}

struct CJKTextTests {
    @Test func tokenizeAndBack() {
        let original = "你好世界 hello 世界!"
        let tokenized = CJKText.tokenize(original)
        #expect(tokenized == "你 好 世 界 hello 世 界!")
        #expect(CJKText.detokenize(tokenized) == original)
    }

    @Test func cjkToASCIIBoundaryGetsASpace() {
        // Without it, 容xyz is one unicode61 token and the phrase "内 容" cannot match.
        #expect(CJKText.tokenize("被删除的内容xyz") == "被 删 除 的 内 容 xyz")
        #expect(CJKText.tokenize("价格是3.5元") == "价 格 是 3.5 元")
    }

    @Test func asciiUntouched() {
        #expect(CJKText.tokenize("plain text") == "plain text")
        #expect(CJKText.detokenize("plain text") == "plain text")
    }

    @Test func ftsQueryBuildsPhrases() {
        #expect(CJKText.ftsQuery("世界") == "\"世 界\"")
        #expect(CJKText.ftsQuery("abc 123") == "\"abc\" \"123\"")
        #expect(CJKText.ftsQuery("天气 怎么样") == "\"天 气\" \"怎 么 样\"")
        #expect(CJKText.ftsQuery("   ") == nil)
    }
}

struct ApprovalTicketTests {
    @Test func resolveBeforeWait() async {
        let ticket = ApprovalTicket()
        ticket.resolve(.allowAlways)
        #expect(await ticket.wait() == .allowAlways)
    }

    @Test func resolveIsExactlyOnce() async {
        let ticket = ApprovalTicket()
        ticket.resolve(.deny)
        ticket.resolve(.allowOnce)
        #expect(await ticket.wait() == .deny)
    }

    @Test func waitThenResolve() async {
        let ticket = ApprovalTicket()
        let waiter = Task { await ticket.wait() }
        try? await Task.sleep(for: .milliseconds(20))
        ticket.resolve(.allowOnce)
        #expect(await waiter.value == .allowOnce)
    }
}

struct ToolRegistryTests {
    private struct Dummy: AgentTool {
        let name = "dummy"
        let summary = "测试工具"
        let risk = RiskLevel.readOnly
        let parameters = JSONSchema.object(["path": "路径"], required: ["path"])

        func run(arguments: String, context: ToolContext) async throws -> String { "" }
    }

    private struct EmptyArguments: Decodable {}

    @Test func lookupAndDefinitions() {
        let registry = ToolRegistry([Dummy()])
        #expect(registry["dummy"] != nil)
        #expect(registry["nope"] == nil)
        #expect(registry.definitions.count == 1)
        #expect(registry.definitions[0].function.name == "dummy")
        #expect(registry.names == ["dummy"])
    }

    @Test func decodeRejectsBadArguments() async throws {
        let tool = Dummy()
        do {
            _ = try tool.decode([String: String].self, from: "not json")
            Issue.record("should have thrown")
        } catch {
            #expect("\(error)".contains("参数不合法"))
        }
    }

    @Test func decodeTreatsEmptyAsEmptyObject() async throws {
        let tool = Dummy()
        _ = try tool.decode(EmptyArguments.self, from: "")
    }
}

struct WithTimeoutTests {
    @Test func fastOperationWins() async throws {
        let value = try await withTimeout(seconds: 1) { 42 }
        #expect(value == 42)
    }

    @Test func slowOperationTimesOut() async {
        do {
            _ = try await withTimeout(seconds: 0.05) {
                try await Task.sleep(for: .seconds(2))
                return "never"
            }
            Issue.record("should have timed out")
        } catch {
            #expect(error is CommandTimeout)
        }
    }
}
