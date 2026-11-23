import Foundation

/// `USER.md` and `MEMORY.md` next to the database: small, human-editable files whose
/// contents are injected into every system prompt. Everything searchable lives in SQLite.
public enum MemoryFiles {
    public static let userProfile = "USER.md"
    public static let notes = "MEMORY.md"

    private static let templates: [String: String] = [
        userProfile: """
        # 关于用户

        <!-- 这里写你的偏好、习惯和常用工具。Agent 每次对话都会读到这里的内容。 -->
        """,
        notes: """
        # Agent 的笔记

        <!-- Agent 通过 remember 工具写入的长期笔记，可以随时手动修改或删除。 -->
        """,
    ]

    public static func ensure(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, template) in templates {
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data(template.utf8).write(to: url, options: .atomic)
            }
        }
    }

    public static func url(for name: String, in directory: URL) -> URL {
        directory.appendingPathComponent(name)
    }

    public static func read(_ name: String, in directory: URL) -> String {
        let url = url(for: name, in: directory)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    public static func append(line: String, to name: String, in directory: URL) throws {
        let content = line
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { throw ToolError.invalidArguments("要记住的内容不能为空") }

        try ensure(in: directory)
        let url = url(for: name, in: directory)
        let stamp = Date.now.formatted(Date.FormatStyle().year().month().day())
        let entry = "\n- [\(stamp)] \(content)\n"
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(entry.utf8))
    }

    /// The file as the model should see it: comments, headings and template-only files removed.
    public static func promptSnippet(_ markdown: String, limit: Int = 4_000) -> String {
        let withoutComments = markdown.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        let lines = withoutComments
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(limit))
    }
}

public struct RememberTool: AgentTool {
    public let name = "remember"
    public let summary = "把一条信息记进长期记忆，之后每次对话都会带上。kind 为 user 时记用户的偏好和背景，为 note 时记你自己的工作笔记。"
    public let risk = RiskLevel.write
    public let parameters = JSONSchema.object([
        "kind": .oneOf(["user", "note"], "user 或 note"),
        "content": "要记住的内容，一句话",
    ], required: ["kind", "content"])

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private struct Arguments: Decodable {
        var kind: String
        var content: String
    }

    public func approvalSummary(for arguments: String) -> String {
        guard let args = try? decode(Arguments.self, from: arguments) else { return arguments }
        return args.kind == "user" ? "记入 USER.md：\(args.content)" : "记入 MEMORY.md：\(args.content)"
    }

    public func run(arguments: String, context: ToolContext) async throws -> String {
        let args = try decode(Arguments.self, from: arguments)
        guard args.kind == "user" || args.kind == "note" else {
            throw ToolError.invalidArguments("kind 只能是 user 或 note")
        }
        let file = args.kind == "user" ? MemoryFiles.userProfile : MemoryFiles.notes
        try MemoryFiles.append(line: args.content, to: file, in: directory)
        return "已记入 \(file)"
    }
}

public struct SearchHistoryTool: AgentTool {
    public let name = "search_history"
    public let summary = "在过去的对话记录里做全文检索，用来回忆以前聊过的内容。"
    public let risk = RiskLevel.readOnly
    public let parameters = JSONSchema.object([
        "query": "搜索词，支持中文",
        "limit": .int("返回条数，默认 5，最多 20"),
    ], required: ["query"])

    private let store: MemoryStore

    public init(store: MemoryStore) {
        self.store = store
    }

    private struct Arguments: Decodable {
        var query: String
        var limit: Int?
    }

    public func run(arguments: String, context: ToolContext) async throws -> String {
        let args = try decode(Arguments.self, from: arguments)
        let hits = try await store.searchHistory(args.query, limit: min(max(args.limit ?? 5, 1), 20))
        guard !hits.isEmpty else { return "没有找到和「\(args.query)」相关的历史记录。" }

        let formatter = Date.FormatStyle(date: .numeric, time: .shortened, locale: Locale(identifier: "zh_CN"))
        return hits.map { hit in
            let who = hit.role == .user ? "用户" : "助手"
            let snippet = hit.snippet.replacingOccurrences(of: "\n", with: " ")
            return "[\(hit.createdAt.formatted(formatter))] 《\(hit.sessionTitle)》 \(who)：\n\(snippet)"
        }.joined(separator: "\n\n")
    }
}

/// Tavily, on its cheapest `basic` depth: one request costs one credit.
public struct WebSearchTool: AgentTool {
    public let name = "web_search"
    public let summary = "联网搜索，返回若干条结果的标题、链接和摘要。"
    public let risk = RiskLevel.readOnly
    public let parameters = JSONSchema.object([
        "query": "搜索关键词",
        "max_results": .int("返回条数，默认 5，最多 10"),
    ], required: ["query"])

    private let apiKey: @Sendable () -> String?

    public init(apiKey: @Sendable @escaping () -> String?) {
        self.apiKey = apiKey
    }

    private struct Arguments: Decodable {
        var query: String
        var maxResults: Int?

        private enum CodingKeys: String, CodingKey {
            case query
            case maxResults = "max_results"
        }
    }

    private struct Response: Decodable {
        struct Result: Decodable {
            var title: String?
            var url: String?
            var content: String?
        }

        var results: [Result]
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public func run(arguments: String, context: ToolContext) async throws -> String {
        let args = try decode(Arguments.self, from: arguments)
        guard let key = apiKey(), !key.isEmpty else {
            throw ToolError.notConfigured("还没有配置 Tavily API Key（在设置里填写后才能联网搜索）")
        }
        context.report("正在搜索：\(args.query)")

        guard let url = URL(string: "https://api.tavily.com/search") else {
            throw ToolError.failed("搜索接口地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONValue.object([
            "query": .string(args.query),
            "max_results": .number(Double(min(max(args.maxResults ?? 5, 1), 10))),
            "search_depth": "basic",
        ]).encoded()

        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ToolError.failed("搜索接口返回 HTTP \(status)：\(String(decoding: data.prefix(300), as: UTF8.self))")
        }

        let results = try JSONDecoder().decode(Response.self, from: data).results
        guard !results.isEmpty else { return "没有搜到和「\(args.query)」相关的结果。" }
        return results.enumerated().map { index, result in
            let snippet = (result.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(index + 1). \(result.title ?? "（无标题）")\n   \(result.url ?? "")\n   \(String(snippet.prefix(300)))"
        }.joined(separator: "\n\n")
    }
}
