import Foundation

public struct RequestToolCall: Hashable, Sendable, Encodable {
    public struct Function: Hashable, Sendable, Encodable {
        public var name: String
        public var arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public var id: String
    public var type = "function"
    public var function: Function

    public init(id: String, function: Function) {
        self.id = id
        self.function = function
    }

    public init(_ call: ToolCall) {
        self.init(
            id: call.id,
            function: Function(name: call.name, arguments: call.arguments)
        )
    }
}

public struct RequestMessage: Hashable, Sendable, Encodable {
    public var role: MessageRole
    /// Always encoded, as a string or null, because several providers reject the key being absent.
    public var content: String?
    public var toolCalls: [RequestToolCall]?
    public var toolCallID: String?
    /// The tool's name, which some providers echo back in the next turn.
    public var name: String?

    public init(
        role: MessageRole,
        content: String?,
        toolCalls: [RequestToolCall]? = nil,
        toolCallID: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }

    public init(_ message: ChatMessage) {
        let hasToolCalls = !message.toolCalls.isEmpty
        self.init(
            role: message.role,
            content: message.content.isEmpty && hasToolCalls ? nil : message.content,
            toolCalls: hasToolCalls ? message.toolCalls.map(RequestToolCall.init) : nil,
            toolCallID: message.toolCallID,
            name: message.name
        )
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case name
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(name, forKey: .name)
    }
}

public struct ToolDefinition: Hashable, Sendable, Encodable {
    public struct Function: Hashable, Sendable, Encodable {
        public var name: String
        public var description: String
        public var parameters: JSONValue

        public init(name: String, description: String, parameters: JSONValue) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }

    public var type = "function"
    public var function: Function

    public init(function: Function) {
        self.function = function
    }
}

public struct ChatRequest: Hashable, Sendable {
    public var model: String
    public var messages: [RequestMessage]
    public var tools: [ToolDefinition]
    public var temperature: Double?
    public var maxTokens: Int?

    public init(
        model: String,
        messages: [RequestMessage],
        tools: [ToolDefinition] = [],
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

public enum StreamEvent: Sendable, Hashable {
    case reasoningDelta(String)
    case textDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsFragment: String)
    case finish(reason: String?)
}

public enum ProviderError: Error, LocalizedError, Sendable, Hashable {
    case invalidBaseURL(String)
    case http(status: Int, message: String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let baseURL):
            return "API 地址无效：\(baseURL)"
        case .http(let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "模型接口返回 HTTP \(status)"
            }
            return "模型接口返回 HTTP \(status)：\(String(detail.prefix(400)))"
        case .emptyResponse:
            return "模型返回了空回复"
        }
    }
}

/// A protocol so the runner can be driven by any backend (another vendor, a recorder, a fake).
public protocol ModelClient: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

public struct TrimResult: Sendable, Hashable {
    /// Oldest-first messages that fit the budget and form a valid transcript head.
    public var messages: [ChatMessage]
    /// Everything left out, in chronological order. Candidates for summarization.
    public var dropped: [ChatMessage]

    public init(messages: [ChatMessage], dropped: [ChatMessage]) {
        self.messages = messages
        self.dropped = dropped
    }
}

/// Keeps the newest messages within a character budget, then repairs the head so the
/// transcript never opens with a tool result whose request was cut off.
public enum TranscriptBuilder {
    public static func trim(_ history: [ChatMessage], budgetChars: Int) -> [ChatMessage] {
        split(history, budgetChars: budgetChars).messages
    }

    /// Like `trim`, but also reports what did not fit, so it can be summarized instead of lost.
    public static func split(_ history: [ChatMessage], budgetChars: Int) -> TrimResult {
        guard !history.isEmpty else {
            return TrimResult(messages: [], dropped: [])
        }

        var kept: [ChatMessage] = []
        var used = 0
        for index in stride(from: history.count - 1, through: 0, by: -1) {
            let message = history[index]
            let size = size(of: message)
            if !kept.isEmpty, used + size > budgetChars {
                break
            }
            kept.append(message)
            used += size
        }

        // `kept` is newest-first, so the transcript head is its last element. The head must
        // never be a tool result whose request was trimmed away, or a request whose results
        // are missing; providers reject both. A request whose results are all present is valid.
        while let head = kept.last {
            if head.role == .tool {
                kept.removeLast()
                continue
            }
            if head.role == .assistant, !head.toolCalls.isEmpty {
                let answered = head.toolCalls.allSatisfy { call in
                    kept.contains { $0.role == .tool && $0.toolCallID == call.id }
                }
                if answered {
                    break
                }
                kept.removeLast()
                continue
            }
            break
        }

        let keptIDs = Set(kept.map(\.id))
        let dropped = history.filter { !keptIDs.contains($0.id) }
        return TrimResult(messages: kept.reversed(), dropped: dropped)
    }

    static func size(of message: ChatMessage) -> Int {
        message.content.count + message.toolCalls.reduce(0) { $0 + $1.arguments.count } + 32
    }
}
