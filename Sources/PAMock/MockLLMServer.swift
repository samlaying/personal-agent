import Foundation

public struct MockRequest: Sendable, Hashable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    /// The request body as a JSON object, or an empty dictionary when it is not one.
    public func json() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    /// Convenience accessors on the decoded messages array.
    public var messages: [[String: Any]] { json()["messages"] as? [[String: Any]] ?? [] }

    public var concatenatedContent: String {
        messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
    }
}

/// A local OpenAI-compatible `/v1/chat/completions` server with scripted, slowly streamed
/// answers. Exists so the client, the agent loop and the app can be exercised end to end
/// without a real provider, a real key, or any spend.
///
/// Plain BSD sockets behind a lock: one thread per connection, no dependency on anything
/// outside the system libraries.
public final class MockLLMServer: @unchecked Sendable {
    public struct Options: Sendable {
        /// 0 picks a free port.
        public var port: UInt16 = 0
        /// Pause between stream events, to make streaming visible to the caller.
        public var chunkDelay: TimeInterval = 0.02
        /// When set, requests carrying any other bearer token are rejected with 401.
        public var requiredAPIKey: String?
        /// What a `write_file` call scripted by the `[[write]]` marker should write.
        public var writeTarget: (path: String, content: String) = ("/tmp/pa-mock-write.txt", "written by mock")

        public init() {}
    }

    public struct Failure: Error, LocalizedError, Hashable, Sendable {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var errorDescription: String? { message }
    }

    public let modelID = "mock-model"
    public let options: Options
    public private(set) var port: UInt16 = 0

    private let lock = NSLock()
    private var recorded: [MockRequest] = []
    private var listener: Int32 = -1
    private var stopping = false
    private var acceptThread: Thread?

    public init(options: Options = Options()) throws {
        self.options = options
        try start()
    }

    deinit {
        stop()
    }

    public var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    /// Every request served so far, oldest first.
    public func requests() -> [MockRequest] {
        lock.withLock { recorded }
    }

    public func stop() {
        let shouldStop: Bool = lock.withLock {
            guard listener >= 0, !stopping else { return false }
            stopping = true
            return true
        }
        guard shouldStop else { return }

        // Shutting the listener down wakes the thread blocked in accept(), which then closes the
        // descriptor itself. Closing it from here would race with that thread still using it.
        shutdown(listener, SHUT_RDWR)
    }

    // MARK: Socket plumbing

    private func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("socket() failed: \(errno)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = options.port.bigEndian

        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            close(fd)
            throw Failure("bind() failed: \(errno)")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw Failure("listen() failed: \(errno)")
        }

        var name = sockaddr_in()
        var length = size
        let named = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            close(fd)
            throw Failure("getsockname() failed: \(errno)")
        }

        port = UInt16(bigEndian: name.sin_port)
        lock.withLock { listener = fd }

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "pa.mock-llm.accept"
        thread.start()
        acceptThread = thread
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listener, nil, nil)
            // A failed accept after stop() is the normal way out of this loop.
            guard fd >= 0 else {
                close(listener)
                return
            }
            let isStopping: Bool = lock.withLock { stopping }
            guard !isStopping else {
                close(fd)
                close(listener)
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.serve(fd)
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536)
        defer { chunk.deallocate() }

        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        var headEnd = buffer.range(of: separator)
        while headEnd == nil {
            let count = recv(fd, chunk, 65_536, 0)
            guard count > 0 else { return }
            buffer.append(chunk, count: count)
            headEnd = buffer.range(of: separator)
        }
        guard let headEnd else { return }

        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n").makeIterator()
        let requestLine = lines.next() ?? ""
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        while buffer.count - bodyStart < contentLength {
            let count = recv(fd, chunk, 65_536, 0)
            guard count > 0 else { return }
            buffer.append(chunk, count: count)
        }

        let parts = requestLine.split(separator: " ")
        let request = MockRequest(
            method: parts.count > 0 ? String(parts[0]) : "",
            path: parts.count > 1 ? String(parts[1]) : "/",
            headers: headers,
            body: Data(buffer[bodyStart...])
        )
        lock.withLock { recorded.append(request) }
        respond(to: request, on: fd)
    }

    private func write(_ fd: Int32, _ text: String) -> Bool {
        var data = Data(text.utf8)
        while !data.isEmpty {
            let remaining = data.count
            let sent = data.withUnsafeBytes { raw in send(fd, raw.baseAddress, remaining, 0) }
            guard sent > 0 else { return false }
            data.removeFirst(sent)
        }
        return true
    }

    // MARK: Responses

    private func respond(to request: MockRequest, on fd: Int32) {
        if request.method == "GET", request.path == "/" || request.path == "/v1" || request.path == "/v1/" {
            return sendInfoPage(fd)
        }
        if request.method == "GET", request.path.hasSuffix("/models") {
            return sendJSON(fd, status: 200, body: ["object": "list", "data": [["id": modelID, "object": "model"]]])
        }
        guard request.method == "POST", request.path.hasSuffix("/chat/completions") else {
            return sendJSON(fd, status: 404, body: ["error": ["message": "not found"]])
        }
        if let key = options.requiredAPIKey, request.headers["authorization"] != "Bearer \(key)" {
            return sendJSON(
                fd, status: 401,
                body: ["error": ["message": "Invalid API key", "type": "invalid_request_error"]]
            )
        }

        let body = request.json()
        if request.concatenatedContent.contains("[[http500]]") {
            return sendJSON(fd, status: 500, body: ["error": ["message": "mock server exploded"]])
        }

        let payloads = events(for: request)
        if (body["stream"] as? Bool) != true {
            let text = payloads.compactMap { payload -> String? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      let choices = object["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any] else { return nil }
                return delta["content"] as? String
            }.joined()
            return sendJSON(
                fd, status: 200,
                body: [
                    "id": "chatcmpl-mock", "object": "chat.completion", "model": modelID,
                    "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
                ]
            )
        }

        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream; charset=utf-8\r
        Cache-Control: no-cache\r
        Connection: close\r
        \r

        """
        guard write(fd, head) else { return }
        for payload in payloads {
            if options.chunkDelay > 0 {
                Thread.sleep(forTimeInterval: options.chunkDelay)
            }
            guard write(fd, "data: \(payload)\n\n") else { return }
        }
    }

    private func sendJSON(_ fd: Int32, status: Int, body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let reason = status == 200 ? "OK" : "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        _ = write(fd, head)
        _ = write(fd, String(decoding: data, as: UTF8.self))
    }

    /// The page a person sees when they open the server URL in a browser. The API itself
    /// is for the app, not for browsers.
    private func sendInfoPage(_ fd: Int32) {
        let html = """
        <!doctype html><html lang="zh"><meta charset="utf-8">
        <title>mock-llm</title>
        <style>
        body{font-family:-apple-system,system-ui,sans-serif;max-width:560px;margin:48px auto;padding:0 16px;color:#1d1d1f}
        h1{font-size:20px}code,pre{background:#f5f5f7;border-radius:6px}
        code{padding:2px 6px}pre{padding:12px;overflow:auto;font-size:13px}
        .ok{color:#34c759;font-weight:600}.muted{color:#86868b;font-size:13px}
        </style>
        <h1><span class="ok">●</span> mock-llm 正在运行</h1>
        <p>这是 PersonalAgent 的本地模拟模型服务，给应用当 API 用的，本身没有页面。你现在看到的是它的说明页。</p>
        <h3>让应用连上它</h3>
        <p>打开应用（菜单栏 ✨ 图标 → 设置…）：</p>
        <pre>Base URL: http://127.0.0.1:\(port)/v1
        模型:     mock-model
        API Key:  随便填或留空</pre>
        <p>然后 ⌥Space 打开面板就能对话，不需要任何真实 key。</p>
        <h3>接口</h3>
        <pre>POST /v1/chat/completions   流式对话（SSE）
        GET  /v1/models             模型列表</pre>
        <h3>测试口令（写在消息里触发）</h3>
        <pre>[[plain]]  纯文本回复（测流式显示）
        [[write]]  触发 write_file 工具调用（测审批卡片）
        [[http500]]  返回 500（测错误提示）</pre>
        <p class="muted">用完 Ctrl-C 关掉即可；真实使用请在设置里填你的模型 API。</p>
        """
        let payload = Data(html.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        _ = write(fd, head)
        _ = write(fd, String(decoding: payload, as: UTF8.self))
    }

    /// Which reply the request scripts, decided from the transcript the client sent.
    private func events(for request: MockRequest) -> [String] {
        let messages = request.messages
        let last = messages.last ?? [:]
        let prompt = request.concatenatedContent

        if last["role"] as? String == "tool" {
            let toolName = last["name"] as? String ?? "tool"
            let toolOutput = (last["content"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return Self.textEvents(
                "已经帮你查到了：\n\n> \(toolOutput)\n\n- 结果来自 `\(toolName)` 工具\n- **以上信息可以直接使用**\n\n还有什么需要我做的吗？"
            )
        }
        if prompt.contains("[[plain]]") {
            return Self.textEvents("这是一段**纯文字**回答，用来确认流式显示正常。")
        }
        if prompt.contains("[[write]]") {
            return Self.toolCallEvents(
                name: "write_file",
                arguments: ["path": options.writeTarget.path, "content": options.writeTarget.content],
                reasoning: "用户让我写文件，这需要先获得批准。"
            )
        }
        return Self.toolCallEvents(name: "get_current_time", arguments: [:], reasoning: "用户想知道时间，先调用工具查询。")
    }

    private static func encode(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func chunk(_ delta: [String: Any], finish: String? = nil) -> String {
        let finishValue: Any = finish ?? NSNull()
        return encode([
            "id": "chatcmpl-mock", "object": "chat.completion.chunk", "model": "mock-model",
            "choices": [["index": 0, "delta": delta, "finish_reason": finishValue]],
        ])
    }

    private static func textEvents(_ answer: String) -> [String] {
        var events = [chunk(["role": "assistant", "content": ""])]
        var piece = ""
        for character in answer {
            piece.append(character)
            if piece.count >= 3 {
                events.append(chunk(["content": piece]))
                piece = ""
            }
        }
        if !piece.isEmpty {
            events.append(chunk(["content": piece]))
        }
        events.append(chunk([:], finish: "stop"))
        events.append("[DONE]")
        return events
    }

    /// The arguments are split across several partial chunks on purpose: that is the shape
    /// real providers send, and merging the fragments is where clients tend to break.
    private static func toolCallEvents(name: String, arguments: [String: Any], reasoning: String) -> [String] {
        let json = encode(arguments)
        let cut = json.index(json.startIndex, offsetBy: json.count / 2)

        var events = [chunk(["role": "assistant", "reasoning_content": String(reasoning.prefix(reasoning.count / 2))])]
        events.append(chunk(["reasoning_content": String(reasoning[reasoning.index(reasoning.startIndex, offsetBy: reasoning.count / 2)...])]))
        events.append(chunk(["tool_calls": [["index": 0, "id": "call_mock_1", "type": "function", "function": ["name": name, "arguments": ""]]]]))
        events.append(chunk(["tool_calls": [["index": 0, "function": ["arguments": String(json[..<cut])]]]]))
        events.append(chunk(["tool_calls": [["index": 0, "function": ["arguments": String(json[cut...])]]]]))
        events.append(chunk([:], finish: "tool_calls"))
        events.append("[DONE]")
        return events
    }
}
