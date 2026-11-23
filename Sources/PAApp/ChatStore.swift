import Foundation
import PACore

/// What the chat list renders for one turn.
struct DisplayItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case user
        case assistant
        case reasoning
        case toolResult(name: String, outcome: ToolOutcome)
    }

    enum Content: Hashable {
        case none
        case text(String)
    }

    let id: String
    var kind: Kind
    var content: Content
    var isStreaming: Bool

    var text: String {
        if case .text(let value) = content { value } else { "" }
    }
}

/// Owns the current session, drives the agent and persists everything.
@MainActor
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    enum Phase: Equatable {
        case idle
        case thinking
        case streaming
        case runningTool(String)
    }

    @Published private(set) var session: ChatSession?
    @Published private(set) var items: [DisplayItem] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pendingApproval: ApprovalRequest?
    @Published private(set) var lastError: String?
    @Published private(set) var note: String?
    @Published private(set) var preApprovedTools: Set<String> = []

    func report(_ text: String?) {
        lastError = text
    }

    func dismissError() {
        lastError = nil
    }

    let dataDirectory: URL
    let store: MemoryStore
    private var runTask: Task<Void, Never>?
    private var activeToolName: String?
    /// Gist of turns already compressed out of this session's transcript.
    private var currentSummary: ConversationSummary?

    init() {
        let preferred = Self.defaultDirectory()
        do {
            try MemoryFiles.ensure(in: preferred)
            store = try MemoryStore(url: preferred.appendingPathComponent("memory.sqlite"))
            dataDirectory = preferred
        } catch {
            // Keep the app usable even if the normal location is broken (full disk, permissions).
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("PersonalAgent-fallback", isDirectory: true)
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            store = (try? MemoryStore(url: fallback.appendingPathComponent("memory.sqlite")))
                ?? (try! MemoryStore(url: URL(fileURLWithPath: "/tmp/pa-emergency.sqlite")))
            dataDirectory = fallback
            lastError = "记忆存储位置不可用，已临时改用 \(fallback.path)：\(error.localizedDescription)"
        }
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalAgent", isDirectory: true)
    }

    // MARK: Session management

    func newSession(agent: AgentProfile) {
        cancel()
        session = nil
        items = []
        preApprovedTools = []
        currentSummary = nil
        Task {
            do {
                session = try await store.createSession(principalID: agent.id)
            } catch {
                lastError = "新建会话失败：\(error.localizedDescription)"
            }
        }
    }

    /// Loads the most recent session on launch, or starts a fresh one.
    func bootstrap(agent: AgentProfile) async {
        guard session == nil else { return }
        do {
            if let latest = try await store.listSessions(limit: 1).first {
                session = latest
                items = Self.displayItems(for: try await store.messages(in: latest.id))
                currentSummary = try await store.summary(for: latest.id)
            } else {
                session = try await store.createSession(principalID: agent.id)
            }
        } catch {
            lastError = "读取会话失败：\(error.localizedDescription)"
        }
    }

    func open(_ target: ChatSession) async {
        cancel()
        do {
            session = target
            items = Self.displayItems(for: try await store.messages(in: target.id))
            preApprovedTools = []
            currentSummary = try await store.summary(for: target.id)
        } catch {
            lastError = "打开会话失败：\(error.localizedDescription)"
        }
    }

    func delete(_ target: ChatSession, agent: AgentProfile) {
        cancel()
        Task {
            do {
                try await store.deleteSession(target.id)
                if target.id == session?.id {
                    newSession(agent: agent)
                }
            } catch {
                lastError = "删除会话失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: Running the agent

    var isBusy: Bool { phase != .idle }

    func send(_ input: String, agent: AgentProfile) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        guard AppSettings.shared.isConfigured else {
            lastError = "还没有配置模型 API（菜单 → 设置）"
            return
        }
        let sessionID = session?.id ?? ""
        guard !sessionID.isEmpty else {
            lastError = "会话尚未就绪，再试一次"
            return
        }

        let settings = AppSettings.shared.snapshot()
        items.append(DisplayItem(id: UUID().uuidString, kind: .user, content: .text(text), isStreaming: false))
        phase = .thinking
        lastError = nil

        let runner = makeRunner(settings: settings, agent: agent)
        runTask = Task { [weak self] in
            guard let self else { return }

            let userMessage = ChatMessage(
                id: UUID().uuidString,
                seq: self.items.count,
                role: .user,
                author: .user,
                content: text
            )
            do {
                try await self.store.append(userMessage, to: sessionID)
                if self.session?.title.isEmpty == true {
                    let title = String(text.prefix(30))
                    try? await self.store.renameSession(sessionID, title: title)
                    self.session?.title = title
                }
            } catch {
                self.lastError = "保存消息失败：\(error.localizedDescription)"
            }

            let history = ((try? await self.store.messages(in: sessionID)) ?? []).dropLast()
            let request = RunRequest(
                profile: agent,
                history: Array(history),
                input: text,
                sessionID: sessionID,
                preApprovedTools: self.preApprovedTools,
                summary: self.currentSummary
            )

            for await event in runner.events(for: request) {
                if Task.isCancelled { break }
                self.handle(event)
            }
            self.phase = .idle
            self.note = nil
            self.runTask = nil
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if let request = pendingApproval {
            request.ticket.resolve(.deny)
            pendingApproval = nil
        }
        if let last = items.last, last.isStreaming {
            items[items.count - 1].isStreaming = false
        }
        phase = .idle
        note = nil
    }

    func resolve(approval decision: Decision) {
        guard let request = pendingApproval else { return }
        if decision == .allowAlways {
            preApprovedTools.insert(request.call.name)
        }
        request.ticket.resolve(decision)
        pendingApproval = nil
        phase = .thinking
    }

    private func makeRunner(settings: AppSettings.Snapshot, agent: AgentProfile) -> AgentRunner {
        let client = OpenAICompatibleClient(baseURL: settings.baseURL, apiKey: settings.modelKey)
        let tavilyKey = settings.tavilyKey
        let tools = ToolRegistry([
            CurrentTimeTool(),
            ListDirectoryTool(),
            ReadFileTool(),
            WriteFileTool(),
            ShellTool(),
            RememberTool(directory: dataDirectory),
            SearchHistoryTool(store: store),
            WebSearchTool(apiKey: { tavilyKey }),
        ])
        return AgentRunner(
            client: client,
            tools: tools,
            prompt: promptContext(),
            defaultModel: agent.model ?? settings.model,
            temperature: settings.temperature
        )
    }

    private func promptContext() -> PromptContext {
        PromptContext(
            userProfile: MemoryFiles.promptSnippet(MemoryFiles.read(MemoryFiles.userProfile, in: dataDirectory)),
            memoryNotes: MemoryFiles.promptSnippet(MemoryFiles.read(MemoryFiles.notes, in: dataDirectory)),
            environmentSummary: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
    }

    // MARK: Event handling

    private func handle(_ event: AgentEvent) {
        switch event {
        case .reasoningDelta(let fragment):
            if let last = items.last, last.isStreaming, case .reasoning = last.kind {
                items[items.count - 1].content = .text(last.text + fragment)
            } else {
                items.append(DisplayItem(id: UUID().uuidString, kind: .reasoning, content: .text(fragment), isStreaming: true))
            }
            phase = .streaming

        case .textDelta(let fragment):
            if let last = items.last, last.isStreaming, case .assistant = last.kind {
                items[items.count - 1].content = .text(last.text + fragment)
            } else {
                if let last = items.last, last.isStreaming, case .reasoning = last.kind {
                    items[items.count - 1].isStreaming = false
                }
                items.append(DisplayItem(id: UUID().uuidString, kind: .assistant, content: .text(fragment), isStreaming: true))
            }
            phase = .streaming

        case .assistantMessage(let message):
            if let last = items.last, last.isStreaming {
                items.removeLast()
            }
            guard !message.content.isEmpty else { return }
            items.append(DisplayItem(id: message.id, kind: .assistant, content: .text(message.content), isStreaming: false))
            persist(message)

        case .toolStarted(_, let name, _):
            activeToolName = name
            note = "正在执行 \(name)…"
            phase = .runningTool(name)

        case .toolFinished(_, let result, let outcome):
            if let last = items.last, last.isStreaming {
                items[items.count - 1].isStreaming = false
            }
            items.append(DisplayItem(
                id: UUID().uuidString,
                kind: .toolResult(name: activeToolName ?? "工具", outcome: outcome),
                content: .text(result),
                isStreaming: false
            ))
            activeToolName = nil
            note = nil

        case .toolMessage(let message):
            persist(message)

        case .summaryUpdated(let summary):
            currentSummary = summary
            note = "已把较早的对话压缩成摘要"
            if let sessionID = session?.id {
                Task { [store] in
                    try? await store.saveSummary(summary, for: sessionID)
                }
            }

        case .approvalRequired(let request):
            pendingApproval = request
            if let last = items.last, last.isStreaming {
                items[items.count - 1].isStreaming = false
            }

        case .note(let text):
            note = text

        case .finished(let reason):
            if let message = reason.errorMessage {
                lastError = message
            }
            if let last = items.last, last.isStreaming {
                items[items.count - 1].isStreaming = false
            }
            note = nil
        }
    }

    private func persist(_ message: ChatMessage) {
        guard let sessionID = session?.id else { return }
        let seq = items.count
        Task { [store] in
            try? await store.append(
                ChatMessage(
                    id: message.id,
                    seq: seq,
                    role: message.role,
                    author: message.author,
                    content: message.content,
                    toolCalls: message.toolCalls,
                    toolCallID: message.toolCallID,
                    name: message.name
                ),
                to: sessionID
            )
        }
    }

    private static func displayItems(for messages: [ChatMessage]) -> [DisplayItem] {
        messages.compactMap { message in
            switch message.role {
            case .user:
                return DisplayItem(id: message.id, kind: .user, content: .text(message.content), isStreaming: false)
            case .assistant:
                guard !message.content.isEmpty else { return nil }
                return DisplayItem(id: message.id, kind: .assistant, content: .text(message.content), isStreaming: false)
            case .tool:
                return DisplayItem(
                    id: message.id,
                    kind: .toolResult(name: message.name ?? "工具", outcome: .ok),
                    content: .text(message.content),
                    isStreaming: false
                )
            case .system:
                return nil
            }
        }
    }
}
