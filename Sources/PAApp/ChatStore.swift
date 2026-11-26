import Foundation
import Observation
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
@Observable
final class ChatStore {
    static let shared = ChatStore()

    enum Phase: Equatable {
        case idle
        case thinking
        case streaming
        case runningTool(String)
    }

    private(set) var session: ChatSession?
    private(set) var items: [DisplayItem] = []
    private(set) var phase: Phase = .idle
    private(set) var pendingApproval: ApprovalRequest?
    private(set) var lastError: String?
    private(set) var note: String?
    private(set) var preApprovedTools: Set<String> = []
    private(set) var sessionList: [ChatSession] = []
    /// The session list lives in a sidebar of the chat window, not a separate screen.
    var showSidebar = true
    /// Older messages live behind this flag instead of being loaded up front.
    private(set) var hasEarlierMessages = false

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
    /// How many messages one page of history holds.
    private static let pageSize = 200
    private var oldestLoadedSeq: Int?
    /// Monotonic counter for `seq`; display order and storage order must not drift apart
    /// once a session is loaded in pages.
    private var nextSeq = 0
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

    func reloadSessions() async {
        sessionList = (try? await store.listSessions(limit: 100)) ?? []
    }

    func newSession(agent: AgentProfile) {
        cancel()
        // Reuse an untouched session instead of leaving a trail of empty ones.
        if session != nil, items.isEmpty {
            return
        }
        session = nil
        items = []
        preApprovedTools = []
        currentSummary = nil
        oldestLoadedSeq = nil
        hasEarlierMessages = false
        nextSeq = 0
        Task {
            do {
                session = try await store.createSession(principalID: agent.id)
                await reloadSessions()
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
                let page = try await store.recentMessages(in: latest.id, limit: Self.pageSize)
                items = Self.displayItems(for: page)
                apply(page: page, sessionID: latest.id)
                currentSummary = try await store.summary(for: latest.id)
            } else {
                session = try await store.createSession(principalID: agent.id)
            }
            await reloadSessions()
        } catch {
            lastError = "读取会话失败：\(error.localizedDescription)"
        }
    }

    func open(_ target: ChatSession) async {
        cancel()
        do {
            session = target
            let page = try await store.recentMessages(in: target.id, limit: Self.pageSize)
            items = Self.displayItems(for: page)
            apply(page: page, sessionID: target.id)
            preApprovedTools = []
            currentSummary = try await store.summary(for: target.id)
        } catch {
            lastError = "打开会话失败：\(error.localizedDescription)"
        }
    }

    /// Remembers where the loaded window starts and what the next `seq` should be.
    private func apply(page: [ChatMessage], sessionID: String) {
        oldestLoadedSeq = page.first?.seq
        hasEarlierMessages = (oldestLoadedSeq ?? 0) > 0
        nextSeq = ((page.last?.seq ?? -1) + 1)
        preApprovedTools = []
        _ = sessionID
    }

    /// Prepends the previous page. The scroll position is kept by the view, which pins the
    /// id of the message that was on top.
    func loadEarlier() async {
        guard let sessionID = session?.id, let oldest = oldestLoadedSeq, hasEarlierMessages else { return }
        do {
            let page = try await store.recentMessages(in: sessionID, limit: Self.pageSize, beforeSeq: oldest)
            guard !page.isEmpty else {
                hasEarlierMessages = false
                return
            }
            oldestLoadedSeq = page.first?.seq
            hasEarlierMessages = (oldestLoadedSeq ?? 0) > 0
            items = Self.displayItems(for: page) + items
        } catch {
            lastError = "加载更早的消息失败：\(error.localizedDescription)"
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
                await reloadSessions()
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
                seq: self.nextSeq,
                role: .user,
                author: .user,
                content: text
            )
            self.nextSeq += 1
            do {
                try await self.store.append(userMessage, to: sessionID)
                if self.session?.title.isEmpty == true {
                    let title = String(text.prefix(30))
                    try? await self.store.renameSession(sessionID, title: title)
                    self.session?.title = title
                    await self.reloadSessions()
                }
            } catch {
                self.lastError = "保存消息失败：\(error.localizedDescription)"
            }

            let isSecond = settings.answerRoute == .second
            let recorder = TraceRecorder(
                route: isSecond ? "second" : "agent",
                model: isSecond ? settings.secondModel : (agent.model ?? settings.model),
                temperature: settings.temperature
            )

            if isSecond {
                await self.answerViaSecondChannel(text, settings: settings, agent: agent, trace: recorder)
            } else {
                // The runner trims to a character budget anyway; hand it a bounded window.
                let history = ((try? await self.store.recentMessages(in: sessionID, limit: 400)) ?? []).dropLast()
                let request = RunRequest(
                    profile: agent,
                    history: Array(history),
                    input: text,
                    sessionID: sessionID,
                    preApprovedTools: self.preApprovedTools,
                    summary: self.currentSummary,
                    trace: recorder
                )

                for await event in runner.events(for: request) {
                    if Task.isCancelled { break }
                    self.handle(event)
                }
            }
            await self.saveTrace(recorder, sessionID: sessionID)
            self.phase = .idle
            self.note = nil
            self.runTask = nil
            await self.reloadSessions()
        }
    }


    // MARK: Trace

    private func saveTrace(_ recorder: TraceRecorder, sessionID: String) async {
        let payload = recorder.finish()
        do {
            try await store.saveTrace(payload, sessionID: sessionID)
        } catch {
            lastError = "保存轨迹失败：\(error.localizedDescription)"
        }
    }

    func loadTraces() async -> [TraceSummary] {
        guard let sessionID = session?.id else { return [] }
        return (try? await store.traceSummaries(in: sessionID, limit: 30)) ?? []
    }

    func loadTrace(id: String) async -> TracePayload? {
        try? await store.tracePayload(id: id)
    }

    // MARK: Second channel

    /// One question in, one answer out: no tools, no history replay. The main model may first
    /// condense the message and the session summary into notes for it to read.
    private func answerViaSecondChannel(
        _ text: String, settings: AppSettings.Snapshot, agent: AgentProfile, trace: TraceRecorder
    ) async {
        var context = currentSummary?.text ?? ""
        trace.step(TraceStep(
            name: "载入历史",
            detail: context.isEmpty ? "无摘要" : "摘要 \(context.count) 字",
            meta: ["路由": "second", "模型": settings.secondModel]
        ))

        if settings.preprocessWithMain {
            note = "主模型整理中…"
            if let organized = try? await tracedOrganize(text, summary: context, settings: settings, agent: agent, trace: trace),
               !organized.isEmpty {
                context = organized
            }
        }
        guard !Task.isCancelled else { return }

        note = "第二通道回答中…"
        let channel = AnswerChannel()
        let prompt = channel.prompt(question: text, context: context)
        trace.setPrompt(
            sections: [TraceSection(title: "回答指令", source: "AnswerChannel.instruction", text: channel.instruction)],
            messages: [
                TraceMessage(role: "system", text: channel.instruction),
                TraceMessage(role: "user", text: prompt),
            ],
            budget: ["输入字符": "\(prompt.count)"],
            toolNames: []
        )

        let client = OpenAICompatibleClient(baseURL: settings.secondBaseURL, apiKey: settings.secondKey)
        let request = channel.request(
            model: settings.secondModel,
            prompt: prompt,
            temperature: settings.temperature
        )

        var answer = ""
        let clock = ContinuousClock()
        let streamStart = clock.now
        do {
            for try await event in client.stream(request) {
                if Task.isCancelled { return }
                guard case .textDelta(let fragment) = event else { continue }
                answer += fragment
                appendAssistantDelta(fragment)
                phase = .streaming
            }
        } catch is CancellationError {
            return
        } catch {
            lastError = "第二通道请求失败：\(error.localizedDescription)"
        }
        let elapsed = clock.now - streamStart
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        trace.step(TraceStep(
            name: "模型请求",
            detail: settings.secondModel,
            durationMs: (ms * 10).rounded() / 10,
            meta: ["回答字符": "\(answer.count)"]
        ))

        note = nil
        if let last = items.last, last.isStreaming {
            items[items.count - 1].isStreaming = false
        }
        guard !answer.isEmpty else { return }
        persist(ChatMessage(
            id: UUID().uuidString,
            seq: 0,
            role: .assistant,
            author: .agent(agent.id),
            content: answer
        ))
    }

    /// The main model reads the message and the running summary, and returns notes for the
    /// second channel — it does not answer the question itself.
    /// Manual timing: the closure captures the main-actor `self`, so `trace.span` (which is
    /// nonisolated) would trip Swift 6 sending checks.
    private func tracedOrganize(
        _ text: String, summary: String, settings: AppSettings.Snapshot, agent: AgentProfile, trace: TraceRecorder
    ) async throws -> String {
        let clock = ContinuousClock()
        let start = clock.now
        let notes = try await organize(text, summary: summary, settings: settings, agent: agent)
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        trace.step(TraceStep(
            name: "主模型整理",
            detail: "把最后一句话整理成任务描述",
            durationMs: (ms * 10).rounded() / 10,
            meta: ["整理后": "\(notes.count) 字"]
        ))
        return notes
    }

    private func organize(
        _ text: String, summary: String, settings: AppSettings.Snapshot, agent: AgentProfile
    ) async throws -> String {
        let channel = AnswerChannel(instruction: """
        你在为另一个模型准备材料：把用户这一句话整理成清晰完整的问题，必要时补上背景，不要自己回答。
        只输出整理后的内容。
        """)
        let prompt = channel.prompt(question: text, context: summary)
        let client = OpenAICompatibleClient(baseURL: settings.baseURL, apiKey: settings.modelKey)
        let request = channel.request(
            model: agent.model ?? settings.model,
            prompt: prompt,
            temperature: 0.2
        )
        var notes = ""
        for try await event in client.stream(request) {
            if case .textDelta(let fragment) = event { notes += fragment }
        }
        return notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendAssistantDelta(_ fragment: String) {
        if let last = items.last, last.isStreaming, case .assistant = last.kind {
            items[items.count - 1].content = .text(last.text + fragment)
        } else {
            items.append(DisplayItem(
                id: UUID().uuidString,
                kind: .assistant,
                content: .text(fragment),
                isStreaming: true
            ))
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
        let seq = nextSeq
        nextSeq += 1
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
