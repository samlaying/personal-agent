import Foundation

/// Compresses the part of a conversation that would be trimmed away into a short
/// summary, so old turns are remembered in gist instead of vanishing.
public struct ContextSummarizer: Sendable {
    /// How much of the dropped transcript to feed the model.
    public var maxInputChars: Int
    /// Hint for the summary length, in characters.
    public var maxSummaryChars: Int
    public var timeout: TimeInterval

    public init(maxInputChars: Int = 24_000, maxSummaryChars: Int = 800, timeout: TimeInterval = 45) {
        self.maxInputChars = maxInputChars
        self.maxSummaryChars = maxSummaryChars
        self.timeout = timeout
    }

    public func summarize(
        existing: String,
        dropped: [ChatMessage],
        client: any ModelClient,
        model: String
    ) async throws -> String {
        let transcript = Self.render(dropped, limit: maxInputChars)
        guard !transcript.isEmpty else {
            throw ProviderError.emptyResponse
        }

        var sections: [String] = []
        if !existing.isEmpty {
            sections.append("已有摘要：\n\(existing)")
        }
        sections.append("新增对话：\n\(transcript)")

        let request = ChatRequest(
            model: model,
            messages: [
                RequestMessage(role: .system, content: Self.instructions(maxChars: maxSummaryChars)),
                RequestMessage(role: .user, content: sections.joined(separator: "\n\n")),
            ],
            temperature: 0.2,
            maxTokens: 900
        )

        let summary = try await withTimeout(seconds: timeout) {
            var aggregate = StreamAggregator()
            for try await event in client.stream(request) {
                aggregate.apply(event)
            }
            return aggregate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !summary.isEmpty else {
            throw ProviderError.emptyResponse
        }
        return summary
    }

    private static func instructions(maxChars: Int) -> String {
        """
        你是上下文压缩助手。把给定的对话压缩成简洁的中文要点，供后续对话参考。

        保留：事实、决定、用户偏好、未完成的任务、关键数字与路径、工具得出的结论。
        丢弃：寒暄、重复内容、思考过程。
        不要编造，不要输出问候语或解释，只输出要点列表，不超过 \(maxChars) 字。
        """
    }

    private static func render(_ messages: [ChatMessage], limit: Int) -> String {
        let lines = messages.compactMap { message -> String? in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            switch message.role {
            case .user:
                return content.isEmpty ? nil : "用户：\(content)"
            case .assistant:
                var line = content.isEmpty ? "" : "助手：\(content)"
                if !message.toolCalls.isEmpty {
                    let names = message.toolCalls.map(\.name).joined(separator: "、")
                    line += (line.isEmpty ? "" : "\n") + "（调用工具：\(names)）"
                }
                return line.isEmpty ? nil : line
            case .tool:
                let name = message.name ?? "工具"
                return content.isEmpty ? nil : "工具 \(name) 返回：\(content)"
            case .system:
                return nil
            }
        }
        let full = lines.joined(separator: "\n")
        // Keep the tail: it is the part closest to the messages that stay in context.
        return full.count > limit ? String(full.suffix(limit)) : full
    }
}
