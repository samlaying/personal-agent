import Foundation

public enum MessageRole: String, Codable, Sendable, Hashable {
    case system
    case user
    case assistant
    case tool
}

/// Who authored a message. Every agent has its own identity so a transcript can hold
/// several participants (teams) without changing shape.
public struct Author: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable {
        case user
        case system
        case agent
    }

    public let kind: Kind
    public let id: String

    private init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    public static let user = Author(kind: .user, id: "user")
    public static let system = Author(kind: .system, id: "system")

    public static func agent(_ id: String) -> Author {
        Author(kind: .agent, id: id)
    }

    /// Wire and storage form: `user`, `system` or `agent:<id>`.
    public var storageValue: String {
        kind == .agent ? "agent:\(id)" : kind.rawValue
    }

    public init(storageValue: String) {
        if storageValue.hasPrefix("agent:") {
            kind = .agent
            id = String(storageValue.dropFirst(6))
        } else if storageValue == Kind.system.rawValue {
            self = .system
        } else {
            self = .user
        }
    }

    private enum CodingKeys: String, CodingKey {
        case storageValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(storageValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

public struct ToolCall: Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    /// Raw JSON text, as emitted by the model.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ChatMessage: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    /// Position within its session. Assigned by the caller so on-screen order always
    /// matches stored order, even when writes are in flight.
    public var seq: Int
    public var role: MessageRole
    public var author: Author
    public var content: String
    public var toolCalls: [ToolCall]
    public var toolCallID: String?
    public var name: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        seq: Int = 0,
        role: MessageRole,
        author: Author,
        content: String,
        toolCalls: [ToolCall] = [],
        toolCallID: String? = nil,
        name: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.seq = seq
        self.role = role
        self.author = author
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.createdAt = createdAt
    }
}

/// `mode` and `principalID` already reserve the team case: a single-agent session points at
/// an agent id, a team session will point at a team id.
public enum SessionMode: String, Codable, Sendable, Hashable {
    case single
    case team
}

public struct ChatSession: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var mode: SessionMode
    public var principalID: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String = "",
        mode: SessionMode = .single,
        principalID: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.mode = mode
        self.principalID = principalID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "新对话" : trimmed
    }
}

/// One configurable agent: its identity, instructions and tool set. A team is composed
/// from several of these, so an agent is the unit everything else builds on.
public struct AgentProfile: Hashable, Sendable, Codable, Identifiable {
    public static let defaultID = "assistant"

    public var id: String
    public var name: String
    public var instructions: String
    /// Overrides the global model when set.
    public var model: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        instructions: String,
        model: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.model = model
        self.createdAt = createdAt
    }

    public static func makeDefault() -> AgentProfile {
        AgentProfile(
            id: defaultID,
            name: "助手",
            instructions: "你是用户的个人助理，帮助处理日常事务：回答问题、查资料、整理信息、操作本机文件与命令。",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}
