import Foundation

/// How much harm a tool call could do, which decides whether the user must approve it first.
public enum RiskLevel: String, Codable, Sendable, Hashable {
    /// Runs without asking.
    case readOnly
    /// Changes something on disk or in the agent's memory.
    case write
    /// Can run arbitrary code or touch things outside the workspace.
    case dangerous

    public var needsApproval: Bool { self != .readOnly }

    public var label: String {
        switch self {
        case .readOnly: "只读"
        case .write: "写入"
        case .dangerous: "高风险"
        }
    }
}

/// What a tool is allowed to touch while it runs. Carries the agent identity so a
/// teammate's tool calls stay attributable to that teammate.
public struct ToolContext: Sendable {
    public var sessionID: String
    public var agentID: String
    /// Posts a one-line progress note to the user.
    public var report: @Sendable (String) -> Void

    public init(
        sessionID: String,
        agentID: String,
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.report = report
    }
}

public protocol AgentTool: Sendable {
    var name: String { get }
    var summary: String { get }
    var risk: RiskLevel { get }
    var parameters: JSONValue { get }

    func run(arguments: String, context: ToolContext) async throws -> String
}

public extension AgentTool {
    /// One line on the approval card describing what the call is about to do.
    func approvalSummary(for arguments: String) -> String {
        (try? JSONValue.parse(arguments).prettyPrinted()) ?? arguments
    }

    func decode<A: Decodable>(_ type: A.Type, from arguments: String) throws -> A {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data((trimmed.isEmpty ? "{}" : trimmed).utf8)
        do {
            return try JSONDecoder().decode(A.self, from: data)
        } catch {
            throw ToolError.invalidArguments("\(name) 的参数不合法：\(error.localizedDescription)")
        }
    }

    var definition: ToolDefinition {
        ToolDefinition(
            function: ToolDefinition.Function(name: name, description: summary, parameters: parameters)
        )
    }
}

public enum ToolError: Error, LocalizedError, Sendable, Hashable {
    case invalidArguments(String)
    case notConfigured(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let message), .notConfigured(let message), .failed(let message):
            message
        }
    }
}

public struct ToolRegistry: Sendable {
    public let tools: [any AgentTool]

    public init(_ tools: [any AgentTool]) {
        self.tools = tools
    }

    public subscript(name: String) -> (any AgentTool)? {
        tools.first { $0.name == name }
    }

    public var definitions: [ToolDefinition] {
        tools.map { $0.definition }
    }

    public var names: [String] {
        tools.map { $0.name }
    }
}

/// A thread-safe holder for a value that tools running off the main actor need to read.
public final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public func get() -> Value {
        lock.withLock { value }
    }

    public func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }
}

public struct CommandTimeout: Error {}

/// Races an operation against a deadline.
public func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CommandTimeout()
        }
        guard let first = try await group.next() else {
            throw CommandTimeout()
        }
        group.cancelAll()
        return first
    }
}
