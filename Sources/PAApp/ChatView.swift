import PACore
import SwiftUI

struct ChatView: View {
    @Environment(ChatStore.self) private var store
    @Environment(AgentDirectory.self) private var directory
    @State private var draft = ""
    @State private var expandedTools: Set<String> = []
    @FocusState private var inputFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if store.showSidebar {
                SessionSidebar()
                Divider()
            }
            chatColumn
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            inputFocused = true
            Task {
                await directory.load()
                await store.bootstrap(agent: directory.current)
            }
        }
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            bottomArea
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            iconButton(store.showSidebar ? "sidebar.left" : "sidebar.leading", help: "对话列表") {
                withAnimation(.easeInOut(duration: 0.15)) {
                    store.showSidebar.toggle()
                }
            }

            Menu {
                ForEach(directory.agents) { agent in
                    Button {
                        directory.select(agent.id)
                    } label: {
                        if agent.id == directory.currentID {
                            Label(agent.name, systemImage: "checkmark")
                        } else {
                            Text(agent.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                    Text(directory.current.name)
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if store.isBusy {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(store.note ?? busyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .transition(.opacity)
            }

            Spacer(minLength: 4)

            iconButton("square.and.pencil", help: "新对话") {
                store.newSession(agent: directory.current)
                inputFocused = true
            }
            iconButton("gearshape", help: "设置") {
                SettingsWindowController.shared.show()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var busyText: String {
        switch store.phase {
        case .idle: ""
        case .thinking: "思考中…"
        case .streaming: "回复中…"
        case .runningTool(let name): "执行 \(name)…"
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: a long session must only build the rows that are on screen.
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.hasEarlierMessages {
                        Button("加载更早的消息") {
                            Task { await store.loadEarlier() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                    }
                    if store.items.isEmpty {
                        emptyState
                    }
                    ForEach(store.items) { item in
                        MessageRow(item: item, isExpanded: expandedTools.contains(item.id)) {
                            if expandedTools.contains(item.id) {
                                expandedTools.remove(item.id)
                            } else {
                                expandedTools.insert(item.id)
                            }
                        }
                        .id(item.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .onChange(of: store.items.count) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: store.items.last?.text.count ?? 0) { _, _ in
                if store.items.last?.isStreaming == true {
                    scrollToBottom(proxy, animated: false)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("有什么可以帮你？")
                    .font(.system(size: 17, weight: .semibold))
                Text("⌥Space 随时唤出 · Enter 发送 · Shift+Enter 换行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 8) {
                suggestion("现在几点？")
                suggestion("列出我的下载目录里最大的 10 个文件")
                suggestion("[[write]] 帮我在桌面写一个 hello.txt")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            store.send(text, agent: directory.current)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                Text(text)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Bottom

    @ViewBuilder
    private var bottomArea: some View {
        VStack(spacing: 0) {
            if let error = store.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        store.dismissError()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.1))
            }

            if let approval = store.pendingApproval {
                ApprovalCard(approval: approval) { decision in
                    store.resolve(approval: decision)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            composer
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(store.isBusy ? "正在回复…" : "问点什么…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(sendDraft)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

            if store.isBusy {
                Button {
                    store.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("停止")
                .padding(.trailing, 8)
                .padding(.bottom, 7)
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.trailing, 8)
                .padding(.bottom, 7)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isBusy
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = draft
        draft = ""
        store.send(text, agent: directory.current)
    }
}

// MARK: - Rows

struct MessageRow: View {
    let item: DisplayItem
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }

        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                agentAvatar
                Text(richText(item.text))
                    .textSelection(.enabled)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 40)
            }

        case .reasoning:
            HStack(alignment: .top, spacing: 8) {
                agentAvatar.opacity(0.5)
                Text(item.text)
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 40)
            }

        case .toolResult(let name, let outcome):
            ToolCard(name: name, text: item.text, outcome: outcome, isExpanded: isExpanded, onToggle: onToggle)
                .padding(.leading, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var agentAvatar: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: 22, height: 22)
            .background(.quaternary.opacity(0.6), in: Circle())
            .padding(.top, 2)
    }

    private func richText(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

struct ToolCard: View {
    let name: String
    let text: String
    let outcome: ToolOutcome
    let isExpanded: Bool
    let onToggle: () -> Void

    private var tint: Color {
        switch outcome {
        case .ok: .secondary
        case .error: .red
        case .denied: .orange
        }
    }

    private var statusText: String {
        switch outcome {
        case .ok: "已执行"
        case .error: "出错"
        case .denied: "已拒绝"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: outcome == .ok ? "wrench.and.screwdriver" : "exclamationmark.triangle")
                        .font(.system(size: 10))
                    Text(name.isEmpty ? "工具" : name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(tint)
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(isExpanded ? text : String(text.prefix(140)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 3)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(.quaternary.opacity(0.8), lineWidth: 1)
        )
        .frame(maxWidth: 520, alignment: .leading)
    }
}

struct ApprovalCard: View {
    let approval: ApprovalRequest
    let onDecision: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: approval.risk == .dangerous ? "exclamationmark.shield.fill" : "hand.raised.fill")
                    .foregroundStyle(approval.risk == .dangerous ? .red : .orange)
                Text("请求执行 \(approval.call.name)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(approval.risk.label)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (approval.risk == .dangerous ? Color.red : Color.orange).opacity(0.15),
                        in: Capsule()
                    )
            }

            Text(approval.summary)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(8)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Spacer()
                Button("拒绝") { onDecision(.deny) }
                    .controlSize(.small)
                Button("总是允许") { onDecision(.allowAlways) }
                    .controlSize(.small)
                Button("允许一次") { onDecision(.allowOnce) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill((approval.risk == .dangerous ? Color.red : Color.orange).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke((approval.risk == .dangerous ? Color.red : Color.orange).opacity(0.35), lineWidth: 1)
        )
    }
}
