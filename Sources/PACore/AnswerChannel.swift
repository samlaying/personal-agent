import Foundation

/// Who produces the reply the user sees.
public enum AnswerRoute: String, Codable, Sendable, CaseIterable {
    /// The main model, running the full agent loop (tools, history, approvals).
    case agent
    /// A second, separate channel: one question in, one answer out, no tools.
    case second

    public var label: String {
        switch self {
        case .agent: "主模型（完整 agent，带工具）"
        case .second: "第二通道（只回文字）"
        }
    }
}

/// The "final answer" hop: a single exchange with its own endpoint, model and key.
///
/// It deliberately carries no history, no tool schema and no agent loop. The caller decides
/// what to hand it — typically the latest user message, optionally rewritten by the main
/// model first — and shows the text it streams back verbatim.
public struct AnswerChannel: Sendable {
    public static let instruction = """
    你负责给出最终答案。只输出答案正文，不要复述任务，不要提及自己是在被转发，不要输出工具调用或思考过程。
    """

    public var instruction: String
    /// Anything longer is cut tail-first: the end of a prompt usually carries the question.
    public var maxPromptChars: Int

    public init(instruction: String = AnswerChannel.instruction, maxPromptChars: Int = 24_000) {
        self.instruction = instruction
        self.maxPromptChars = maxPromptChars
    }

    /// Question first, then optional context from an earlier model. Context is dropped before
    /// the question when trimming, because the question is what must survive.
    public func prompt(question: String, context: String = "") -> String {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContext.isEmpty else {
            return Self.trim(trimmedQuestion, to: maxPromptChars)
        }
        let joined = "## 参考信息\n\(trimmedContext)\n\n## 问题\n\(trimmedQuestion)"
        guard joined.count > maxPromptChars else { return joined }
        // Keep the question whole, spend what is left on the tail of the context.
        let budget = max(maxPromptChars - trimmedQuestion.count - 40, 0)
        let tail = String(trimmedContext.suffix(budget))
        return "## 参考信息\n\(tail)\n\n## 问题\n\(trimmedQuestion)"
    }

    public func request(model: String, prompt: String, temperature: Double? = nil) -> ChatRequest {
        ChatRequest(
            model: model,
            messages: [
                RequestMessage(role: .system, content: instruction),
                RequestMessage(role: .user, content: prompt),
            ],
            tools: [],
            temperature: temperature
        )
    }

    private static func trim(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }
}
