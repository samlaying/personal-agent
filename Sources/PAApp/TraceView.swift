import Observation
import PACore
import SwiftUI

/// The per-turn trace viewer: call chain on top, prompt composition and message sequence
/// below — where every piece came from and how long it took.
struct TraceView: View {
    @Environment(ChatStore.self) private var store

    @State private var traces: [TraceSummary] = []
    @State private var selectedID: String?
    @State private var payload: TracePayload?
    @State private var showRaw = false
    @State private var loading = false

    var body: some View {
        HStack(spacing: 0) {
            turnList
            Divider()
            detail
        }
        .background(.background)
        .frame(minWidth: 960, minHeight: 600)
        .task { await reload() }
        // The window can be opened before the session finishes loading; catch up when it does.
        .onChange(of: store.session?.id) { _, _ in
            selectedID = nil
            payload = nil
            Task { await reload() }
        }
    }

    // MARK: Left column

    private var turnList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本轮次").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("刷新")
            }
            .padding(10)

            Divider()

            if traces.isEmpty {
                Text(loading ? "加载中…" : "发一条消息后，这里会出现每轮的轨迹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(traces, id: \.id) { summary in
                            row(summary)
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    private func row(_ summary: TraceSummary) -> some View {
        Button {
            selectedID = summary.id
            Task { await load(id: summary.id) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    routeBadge(summary.route)
                    Text(summary.model).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(Self.time(summary.createdAt)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("\(Int(summary.durationMs)) ms · 提示词 \(summary.promptChars) 字")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                summary.id == selectedID ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func routeBadge(_ route: String) -> some View {
        Text(route == "second" ? "二通道" : "agent")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(route == "second" ? Color.orange.opacity(0.18) : Color.accentColor.opacity(0.16), in: Capsule())
            .foregroundStyle(route == "second" ? .orange : .accentColor)
    }

    // MARK: Right column

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("调用链路").font(.system(size: 14, weight: .semibold))
                if let payload {
                    Text("· \(Int(payload.durationMs)) ms")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("原始 JSON", isOn: $showRaw)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if let payload {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if showRaw {
                            rawJSON(payload)
                        } else {
                            chain(payload.steps)
                            if !payload.systemSections.isEmpty {
                                promptComposition(payload)
                            }
                            if !payload.messages.isEmpty {
                                messageSequence(payload)
                            }
                            if !payload.toolCalls.isEmpty {
                                toolCalls(payload)
                            }
                        }
                    }
                    .padding(14)
                }
            } else {
                Text(loading ? "加载中…" : "选择左边的一轮，看它每一步做了什么")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Timeline

    private func chain(_ steps: [TraceStep]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("系统做了什么").font(.system(size: 12, weight: .semibold)).padding(.bottom, 8)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                node(step)
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 1.5, height: 14)
                        .padding(.leading, 14)
                }
            }
            if steps.isEmpty {
                Text("这一轮没有记录到步骤").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func node(_ step: TraceStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(statusColor(step.status))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(step.name).font(.system(size: 12, weight: .medium))
                    if step.durationMs > 0 {
                        Text("\(Int(step.durationMs)) ms")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text(step.status)
                        .font(.system(size: 9))
                        .foregroundStyle(statusColor(step.status))
                        .opacity(step.status == "成功" ? 0.55 : 1)
                }
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !step.meta.isEmpty {
                    Text(step.meta.map { "\($0.key) \($0.value)" }.sorted().joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "成功": .green
        case "出错", "失败": .red
        case "已拒绝": .orange
        default: .secondary
        }
    }

    // MARK: Prompt composition

    private func promptComposition(_ payload: TracePayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("提示词构成（system，每段怎么来的）")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("共 \(payload.systemSections.count) 段 · \(payload.systemSections.reduce(0) { $0 + $1.text.count }) 字")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(payload.systemSections.enumerated()), id: \.offset) { _, section in
                DisclosureGroup {
                    sectionText(section.text)
                        .padding(8)
                } label: {
                    HStack(spacing: 8) {
                        sourceBadge(section.source)
                        Text(section.title).font(.system(size: 11, weight: .medium))
                        Text("\(section.text.count) 字").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            if !payload.budget.isEmpty {
                Text(payload.budget.map { "\($0.key) \($0.value)" }.sorted().joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sourceBadge(_ source: String) -> some View {
        Text(source)
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    // MARK: Message sequence

    private func messageSequence(_ payload: TracePayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("发送的消息序列（裁剪后）").font(.system(size: 12, weight: .semibold))
            ForEach(Array(payload.messages.enumerated()), id: \.offset) { index, message in
                DisclosureGroup {
                    sectionText(message.text)
                        .padding(8)
                } label: {
                    HStack(spacing: 8) {
                        roleBadge(message.role)
                        if let name = message.name, !name.isEmpty {
                            Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if let seq = message.seq {
                            Text("seq \(seq)").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        Text("#\(index)").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Text("\(message.chars) 字").font(.system(size: 10)).foregroundStyle(.secondary)
                        if message.truncated {
                            Text("已截断").font(.system(size: 9)).foregroundStyle(.orange)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func roleBadge(_ role: String) -> some View {
        Text(role)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(roleColor(role).opacity(0.16), in: Capsule())
            .foregroundStyle(roleColor(role))
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "user": .blue
        case "assistant": .green
        case "tool": .orange
        default: .secondary
        }
    }

    // MARK: Tool calls

    private func toolCalls(_ payload: TracePayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("工具调用").font(.system(size: 12, weight: .semibold))
            ForEach(Array(payload.toolCalls.enumerated()), id: \.offset) { _, call in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(call.name).font(.system(size: 11, weight: .medium, design: .monospaced))
                        Text("\(Int(call.durationMs)) ms").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(call.outcome).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    if !call.arguments.isEmpty {
                        Text("参数 \(call.arguments)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !call.resultPreview.isEmpty {
                        Text("结果 \(call.resultPreview)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: Raw

    private func rawJSON(_ payload: TracePayload) -> some View {
        Group {
            if let data = try? JSONEncoder().encode(payload),
               let pretty = try? JSONSerialization.jsonObject(with: data),
               let data = try? JSONSerialization.data(withJSONObject: pretty, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                sectionText(text)
            } else {
                Text("无法序列化").font(.caption)
            }
        }
    }

    private func sectionText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Data

    private func reload() async {
        loading = true
        traces = await store.loadTraces()
        loading = false
        if selectedID == nil {
            selectedID = traces.first?.id
            if let id = selectedID { await load(id: id) }
        }
    }

    private func load(id: String) async {
        loading = true
        payload = await store.loadTrace(id: id)
        loading = false
    }

    private static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .standard))
    }
}
