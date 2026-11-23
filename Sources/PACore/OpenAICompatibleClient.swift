import Foundation

/// Streams chat completions from any OpenAI-compatible `/chat/completions` endpoint.
public struct OpenAICompatibleClient: ModelClient {
    public let baseURL: String
    public let apiKey: String
    public let session: URLSession
    public let extraHeaders: [String: String]

    public init(
        baseURL: String,
        apiKey: String,
        session: URLSession = OpenAICompatibleClient.makeSession(),
        extraHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.extraHeaders = extraHeaders
    }

    /// Ephemeral: no shared cookie or URL-cache storage, which keeps the app's footprint down.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3_600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public var chatCompletionsURL: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") {
            text.removeLast()
        }
        if !text.hasSuffix("/chat/completions") {
            text += "/chat/completions"
        }
        return URL(string: text)
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeURLRequest(request)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        throw ProviderError.http(status: status, message: try await Self.text(from: bytes, limit: 2_048))
                    }
                    if (response.mimeType ?? "").contains("event-stream") {
                        try await Self.decodeSSE(bytes) { continuation.yield($0) }
                    } else {
                        try await Self.decodeComplete(bytes) { continuation.yield($0) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeURLRequest(_ request: ChatRequest) throws -> URLRequest {
        guard let url = chatCompletionsURL, url.scheme != nil, url.host != nil else {
            throw ProviderError.invalidBaseURL(baseURL)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        urlRequest.httpBody = try Self.encoder.encode(Body(request))
        return urlRequest
    }

    /// Sorted keys keep the request prefix byte-identical across turns, which helps provider-side prompt caching.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private struct Body: Encodable {
        let model: String
        let messages: [RequestMessage]
        let tools: [ToolDefinition]
        let toolChoice = "auto"
        let stream = true
        let temperature: Double?
        let maxTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case model
            case messages
            case tools
            case toolChoice = "tool_choice"
            case stream
            case temperature
            case maxTokens = "max_tokens"
        }

        init(_ request: ChatRequest) {
            model = request.model
            messages = request.messages
            tools = request.tools
            temperature = request.temperature
            maxTokens = request.maxTokens
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(messages, forKey: .messages)
            if !tools.isEmpty {
                try container.encode(tools, forKey: .tools)
                try container.encode(toolChoice, forKey: .toolChoice)
            }
            try container.encode(stream, forKey: .stream)
            try container.encodeIfPresent(temperature, forKey: .temperature)
            try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
        }
    }

    /// Reads a bounded amount of a body, for error messages.
    private static func text(from bytes: URLSession.AsyncBytes, limit: Int) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit {
                break
            }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeSSE(
        _ bytes: URLSession.AsyncBytes, emit: (StreamEvent) -> Void
    ) async throws {
        var splitter = LineSplitter()
        var parser = SSEParser()
        var done = false

        for try await byte in bytes {
            guard let line = splitter.feed(byte), !done else { continue }
            for event in parser.feed(line: line) {
                if event.data == "[DONE]" {
                    done = true
                    break
                }
                try decodeData(event.data, emit: emit)
            }
        }

        // Some providers end the stream without the blank line that terminates the last event.
        if !done, let rest = splitter.finish() {
            for event in parser.feed(line: rest) + parser.finish() where event.data != "[DONE]" {
                try decodeData(event.data, emit: emit)
            }
        }
    }

    private static func decodeData(_ data: String, emit: (StreamEvent) -> Void) throws {
        guard let first = data.first, first == "{" || first == "[" else { return }
        for event in try StreamDecoder.events(fromChunkJSON: data) {
            emit(event)
        }
    }

    private static func decodeComplete(
        _ bytes: URLSession.AsyncBytes, emit: (StreamEvent) -> Void
    ) async throws {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        for event in try StreamDecoder.events(fromCompleteJSON: data) {
            emit(event)
        }
    }
}
