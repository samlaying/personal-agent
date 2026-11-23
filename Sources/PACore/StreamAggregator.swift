import Foundation

/// Folds streamed deltas into the assistant turn they belong to.
public struct StreamAggregator: Sendable {
    public private(set) var text = ""
    public private(set) var reasoning = ""
    public private(set) var toolCalls: [ToolCall] = []
    public private(set) var finishReason: String?

    public init() {}

    public mutating func apply(_ event: StreamEvent) {
        switch event {
        case .textDelta(let fragment):
            text += fragment
        case .reasoningDelta(let fragment):
            reasoning += fragment
        case .toolCallDelta(let index, let id, let name, let fragment):
            // Deltas carry only their own slice, so identity and name arrive once, in the first slice.
            while toolCalls.count <= index {
                toolCalls.append(ToolCall(id: "", name: "", arguments: ""))
            }
            if let id, !id.isEmpty, toolCalls[index].id.isEmpty {
                toolCalls[index].id = id
            }
            if let name, !name.isEmpty, toolCalls[index].name.isEmpty {
                toolCalls[index].name = name
            }
            toolCalls[index].arguments += fragment
        case .finish(let reason):
            if reason != nil {
                finishReason = reason
            }
        }
    }

    /// Some providers never send a call id; the transcript still needs one to pair results with.
    public func normalizedToolCalls() -> [ToolCall] {
        toolCalls.enumerated().map { index, call in
            call.id.isEmpty ? ToolCall(id: "call_\(index)", name: call.name, arguments: call.arguments) : call
        }
    }
}

/// Turns OpenAI-compatible chat completion payloads into `StreamEvent`s.
///
/// Parsing goes through JSONSerialization rather than Codable: it keeps booleans and
/// numbers distinct, and tolerates the field variations between providers (content as
/// string or as parts, arguments as string or as an object) without a wall of decoders.
public enum StreamDecoder {
    public static func events(fromChunkJSON line: String) throws -> [StreamEvent] {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed])
        guard let document = object as? [String: Any] else { return [] }
        return (document["choices"] as? [[String: Any]] ?? []).flatMap {
            makeEvents(from: $0["delta"] as? [String: Any], finishReason: $0["finish_reason"] as? String)
        }
    }

    /// For providers that answer a streaming request with one plain JSON document.
    public static func events(fromCompleteJSON data: Data) throws -> [StreamEvent] {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let document = object as? [String: Any] else { return [] }
        return (document["choices"] as? [[String: Any]] ?? []).flatMap {
            makeEvents(from: $0["message"] as? [String: Any], finishReason: $0["finish_reason"] as? String)
        }
    }

    private static func makeEvents(from payload: [String: Any]?, finishReason: String?) -> [StreamEvent] {
        var events: [StreamEvent] = []
        if let payload {
            if let reasoning = text(from: payload, keys: ["reasoning_content", "reasoning"]), !reasoning.isEmpty {
                events.append(.reasoningDelta(reasoning))
            }
            if let content = text(from: payload, keys: ["content"]), !content.isEmpty {
                events.append(.textDelta(content))
            }
            for (offset, call) in (payload["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                let function = call["function"] as? [String: Any] ?? [:]
                events.append(
                    .toolCallDelta(
                        index: (call["index"] as? Int) ?? offset,
                        id: call["id"] as? String,
                        name: function["name"] as? String,
                        argumentsFragment: argumentsText(from: function["arguments"])
                    )
                )
            }
        }
        if let finishReason {
            events.append(.finish(reason: finishReason))
        }
        return events
    }

    /// A field that is either a string or an array of `{text: ...}` parts.
    private static func text(from payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = payload[key] as? String {
                return string
            }
            if let parts = payload[key] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined()
            }
        }
        return nil
    }

    /// The spec says `arguments` is a JSON string; some providers send the parsed object instead.
    private static func argumentsText(from value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let object as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: object) {
                return String(decoding: data, as: UTF8.self)
            }
            return ""
        default:
            return ""
        }
    }
}
