import Foundation

/// One node in the call chain shown in the trace viewer.
public struct TraceStep: Codable, Hashable, Sendable {
    public var name: String
    public var detail: String
    public var durationMs: Double
    public var status: String
    public var meta: [String: String]

    public init(name: String, detail: String = "", durationMs: Double = 0, status: String = "成功", meta: [String: String] = [:]) {
        self.name = name
        self.detail = detail
        self.durationMs = durationMs
        self.status = status
        self.meta = meta
    }
}

/// A piece of the system prompt, with where it came from.
public struct TraceSection: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var source: String
    public var origin: String
    public var rule: String
    public var text: String

    public init(
        id: String = "",
        title: String,
        source: String,
        origin: String = "",
        rule: String = "",
        text: String
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.origin = origin
        self.rule = rule
        self.text = text
    }
}

public struct TraceMessage: Codable, Hashable, Sendable {
    public var id: String
    public var role: String
    public var name: String?
    public var seq: Int?
    public var chars: Int
    public var text: String
    public var truncated: Bool
    /// Where this message came from (table + seq, this turn's input, tool result…).
    public var origin: String
    /// Which windowing rule kept it in the request.
    public var rule: String

    public init(
        id: String = "",
        role: String,
        name: String? = nil,
        seq: Int? = nil,
        text: String,
        cap: Int = 4000,
        origin: String = "",
        rule: String = ""
    ) {
        self.id = id
        self.role = role
        self.name = name
        self.seq = seq
        self.chars = text.count
        let cut = text.count > cap
        self.text = cut ? String(text.suffix(cap)) : text
        self.truncated = cut
        self.origin = origin
        self.rule = rule
    }
}

public struct TraceToolCall: Codable, Hashable, Sendable {
    public var name: String
    public var arguments: String
    public var durationMs: Double
    public var outcome: String
    public var resultPreview: String

    public init(name: String, arguments: String, durationMs: Double, outcome: String, resultPreview: String) {
        self.name = name
        self.arguments = arguments
        self.durationMs = durationMs
        self.outcome = outcome
        self.resultPreview = resultPreview
    }
}

/// Everything one turn did, serialized into `turn_traces.payload`.
public struct TracePayload: Codable, Hashable, Sendable {
    public var route: String
    public var model: String
    public var temperature: Double?
    public var durationMs: Double
    public var steps: [TraceStep]
    public var systemSections: [TraceSection]
    public var messages: [TraceMessage]
    public var toolNames: [String]
    public var budget: [String: String]
    public var toolCalls: [TraceToolCall]

    public init(
        route: String, model: String, temperature: Double? = nil, durationMs: Double = 0,
        steps: [TraceStep] = [], systemSections: [TraceSection] = [], messages: [TraceMessage] = [],
        toolNames: [String] = [], budget: [String: String] = [:], toolCalls: [TraceToolCall] = []
    ) {
        self.route = route
        self.model = model
        self.temperature = temperature
        self.durationMs = durationMs
        self.steps = steps
        self.systemSections = systemSections
        self.messages = messages
        self.toolNames = toolNames
        self.budget = budget
        self.toolCalls = toolCalls
    }

    public func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> TracePayload? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TracePayload.self, from: data)
    }
}

/// Row summary for the trace list (all sessions, newest first).
public struct TraceSummary: Codable, Hashable, Sendable {
    public var id: String
    public var sessionID: String
    public var sessionTitle: String
    public var createdAt: Date
    public var model: String
    public var route: String
    public var durationMs: Double
    public var promptChars: Int
}

/// Collects what one run did. Held by `RunRequest`; the runner fills it in as it goes.
/// Thread-safe because tool runs and the stream loop may interleave on different executors.
public final class TraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var payload: TracePayload
    private let startedAt = Date()

    public init(route: String, model: String, temperature: Double? = nil) {
        payload = TracePayload(route: route, model: model, temperature: temperature)
    }

    public func step(_ step: TraceStep) {
        lock.withLock { payload.steps.append(step) }
    }

    /// Times an async body and records it as a step.
    public func span<T>(
        _ name: String, detail: String = "", meta: [String: String] = [:],
        _ body: () async throws -> T
    ) async rethrows -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await body()
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        step(TraceStep(name: name, detail: detail, durationMs: (ms * 100).rounded() / 100, meta: meta))
        return value
    }

    /// The final assembly wins: later loop iterations overwrite earlier ones.
    public func setPrompt(sections: [TraceSection], messages: [TraceMessage], budget: [String: String], toolNames: [String]) {
        lock.withLock {
            payload.systemSections = sections
            payload.messages = messages
            payload.budget = budget
            payload.toolNames = toolNames
        }
    }

    public func appendToolCall(_ call: TraceToolCall) {
        lock.withLock { payload.toolCalls.append(call) }
    }

    public func finish() -> TracePayload {
        lock.withLock {
            payload.durationMs = Date().timeIntervalSince(startedAt) * 1000
            return payload
        }
    }
}
