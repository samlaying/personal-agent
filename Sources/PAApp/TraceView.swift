import AppKit
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
    @State private var loading = false
    @State private var showRaw = false
    /// Index into `payload.steps` whose details are shown in the side panel.
    @State private var selectedStep: Int?
    @State private var selectedSectionID: String?
    @State private var selectedMessageID: String?
    /// 链路列宽度，分隔条可拖拽调整。
    @State private var chainWidth: CGFloat = 430
    @State private var chainDragStart: CGFloat?
    /// 「本轮次」列表宽度，同样可拖拽。
    @State private var listWidth: CGFloat = 280
    @State private var listDragStart: CGFloat?

    var body: some View {
        GeometryReader { outerGeo in
        HStack(spacing: 0) {
            turnList
                .frame(width: min(max(200, listWidth), max(200, outerGeo.size.width - 560)))
            // 这根分隔线同样可拖拽
            Rectangle()
                .fill(Color.clear)
                .frame(width: 7)
                .overlay(Divider())
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if listDragStart == nil { listDragStart = listWidth }
                        listWidth = min(max(200, (listDragStart ?? 280) + value.translation.width),
                                        max(200, outerGeo.size.width - 560))
                    }
                    .onEnded { _ in listDragStart = nil })
            detail
        }
        }
        .background(.background)
        .frame(minWidth: 960, minHeight: 600)
        .task { await reload() }
        // 新轨迹落库、切换会话时自动刷新（窗口可能在会话加载完成前就打开了）。
        .onChange(of: store.traceVersion) { _, _ in
            Task { await reload(selectLatest: true) }
        }
        .onChange(of: store.session?.id) { _, _ in
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
                Text(summary.sessionTitle.isEmpty ? "未命名会话" : summary.sessionTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(Int(summary.durationMs)) ms · 提示词 \(summary.promptChars) 字")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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
                Text("运行轨迹").font(.system(size: 14, weight: .semibold))
                if let payload {
                    Text("· \(Int(payload.durationMs)) ms")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showRaw.toggle()
                } label: {
                    Image(systemName: showRaw ? "doc.text" : "curlybraces")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(showRaw ? Color.accentColor : Color.secondary)
                .help(showRaw ? "回到链路视图" : "查看原始 JSON")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if let payload {
                GeometryReader { geo in
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            chain(payload, selectedStep: selectedStep) { selectedStep = $0 }
                        }
                        .padding(12)
                    }
                    .frame(width: min(max(320, chainWidth), max(320, geo.size.width - 300)))
                    // 分隔条：拖拽调整左右宽度
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 6)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.pop() }
                        }
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                if chainDragStart == nil { chainDragStart = chainWidth }
                                chainWidth = min(max(320, (chainDragStart ?? 430) + value.translation.width),
                                                 max(320, geo.size.width - 300))
                            }
                            .onEnded { _ in chainDragStart = nil })
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if showRaw {
                                rawJSON(payload)
                            } else if let index = selectedStep, index < payload.steps.count {
                                stepDetails(payload, step: payload.steps[index])
                            } else {
                                Text("点击左侧任意步骤，这里展开它的细节：\n· 组装提示词 → 完整 system + 每段来源\n· 模型请求 → 模型与产出\n· 工具 → 参数与结果")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 80)
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity)
                }
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

    private func chain(_ payload: TracePayload, selectedStep: Int?, onTap: @escaping (Int?) -> Void) -> some View {
        let steps = payload.steps
        return VStack(alignment: .leading, spacing: 0) {
            Text("系统做了什么").font(.system(size: 12, weight: .semibold)).padding(.bottom, 8)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                node(step, selected: index == selectedStep) {
                    onTap(selectedStep == index ? nil : index)
                }
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 1.5, height: 12)
                        .padding(.leading, 14)
                }
            }
            if steps.isEmpty {
                Text("这一轮没有记录到步骤").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 步骤类型与颜色

    private enum StepKind {
        case context, prompt, summary, model, tool
    }

    private func kind(_ step: TraceStep) -> StepKind {
        if step.name.hasPrefix("模型请求") { return .model }
        if step.name.hasPrefix("工具") { return .tool }
        if step.name == "压缩摘要" { return .summary }
        if step.name == "组装提示词" { return .prompt }
        return .context
    }

    private func kindColor(_ kind: StepKind) -> Color {
        switch kind {
        case .context: Color.blue
        case .prompt: Color.indigo
        case .summary: Color.purple
        case .model: Color.green
        case .tool: Color.orange
        }
    }

    private func kindName(_ kind: StepKind) -> String {
        switch kind {
        case .context: "上下文"
        case .prompt: "提示词"
        case .summary: "摘要"
        case .model: "模型"
        case .tool: "工具"
        }
    }

    private func node(_ step: TraceStep, selected: Bool, onTap: @escaping () -> Void) -> some View {
        let kind = kind(step)
        let color = kindColor(kind)
        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(step.status == "成功" ? color : statusColor(step.status))
                .frame(width: 8, height: 8)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(step.name).font(.system(size: 12, weight: .medium))
                    Text(kindName(kind))
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(color.opacity(0.14), in: Capsule())
                        .foregroundStyle(color)
                    if step.durationMs > 0 {
                        Text("\(Int(step.durationMs)) ms")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if step.status != "成功" {
                        Text(step.status).font(.system(size: 9)).foregroundStyle(statusColor(step.status))
                    }
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
                        .lineLimit(2)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(selected ? 0.07 : 0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(color.opacity(selected ? 1 : 0.45))
                    .frame(width: 3)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                    selected ? color.opacity(0.55) : Color.clear, lineWidth: 1
                )
            )
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "成功": .green
        case "出错", "失败": .red
        case "已拒绝": .orange
        default: .secondary
        }
    }

    // MARK: 侧栏详情

    @ViewBuilder
    private func stepDetails(_ payload: TracePayload, step: TraceStep) -> some View {
        switch kind(step) {
        case .prompt:
            VStack(alignment: .leading, spacing: 14) {
                sideHeader("组装提示词", color: kindColor(.prompt))
                promptDocument(payload)
                if !payload.messages.isEmpty {
                    messageDocument(payload)
                }
            }
        case .model:
            VStack(alignment: .leading, spacing: 14) {
                sideHeader("模型请求", color: kindColor(.model))
                infoCard(rows: [
                    ("模型", step.detail),
                    ("耗时", "\(Int(step.durationMs)) ms"),
                    ("回答字符", step.meta["回答字符"] ?? "-"),
                    ("本次触发的工具", step.meta["工具调用"] ?? "0"),
                ])
                Text("请求里真正发送的提示词，点左侧「组装提示词」查看；这里只汇总产出。")
                    .font(.caption).foregroundStyle(.tertiary)
                if !payload.budget.isEmpty {
                    Text(payload.budget.map { "\($0.key) \($0.value)" }.sorted().joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        case .tool:
            VStack(alignment: .leading, spacing: 14) {
                sideHeader("工具调用", color: kindColor(.tool))
                let name = step.name.replacingOccurrences(of: "工具 · ", with: "")
                let call = payload.toolCalls.last { $0.name == name }
                if let call {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(call.name).font(.system(size: 11, weight: .medium, design: .monospaced))
                        if !call.arguments.isEmpty {
                            Text("参数 \(call.arguments)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                        }
                        if !call.resultPreview.isEmpty {
                            Text("结果 \(call.resultPreview)")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("没有对应的调用记录").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .summary:
            VStack(alignment: .leading, spacing: 14) {
                sideHeader("压缩摘要", color: kindColor(.summary))
                infoCard(rows: [
                    ("触发", step.meta["丢弃"] != nil ? "\(step.meta["丢弃"]!) 条消息超出预算" : "-"),
                    ("耗时", "\(Int(step.durationMs)) ms"),
                ])
                Text("被压缩的消息不再进窗口；压缩结果写进 sessions.summary，下一轮作为「更早的对话（摘要）」注入。")
                    .font(.caption).foregroundStyle(.tertiary)
                if let payloadSummary = payload.systemSections.first(where: { $0.source == "sessions.summary" }) {
                    sectionText(payloadSummary.text).padding(10)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        case .context:
            VStack(alignment: .leading, spacing: 14) {
                sideHeader("载入历史", color: kindColor(.context))
                infoCard(rows: [
                    ("加载条数", step.detail),
                    ("已压缩到", step.meta["已压缩到"] ?? "0"),
                    ("模型", step.meta["模型"] ?? "-"),
                ])
                Text("只加载最近 200 条（recentMessages 分页）；更早的靠「加载更早的消息」按钮或摘要进入提示词。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func sideHeader(_ title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 14)
            Text(title).font(.system(size: 13, weight: .semibold))
        }
    }

    private func infoCard(rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                self.row(pair.0, pair.1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Prompt document

    /// The final system prompt as one document. Every block is clickable and expands into
    /// a provenance card: where it came from and which rule produced it.
    private func promptDocument(_ payload: TracePayload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最终发给模型的提示词（system 完整原文，按注入顺序）")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("共 \(payload.systemSections.count) 段 · \(payload.systemSections.reduce(0) { $0 + $1.text.count }) 字")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(payload.systemSections.enumerated()), id: \.offset) { offset, section in
                let sid = section.id.isEmpty ? "S\(offset + 1)" : section.id
                let block = TraceSection(
                    id: sid, title: section.title, source: section.source,
                    origin: section.origin, rule: section.rule, text: section.text
                )
                sectionBlock(block)
                if block.id == selectedSectionID {
                    provenanceCard(
                        source: section.source,
                        origin: section.origin.isEmpty ? "（旧轨迹未记录）" : section.origin,
                        rule: section.rule.isEmpty ? "（旧轨迹未记录）" : section.rule,
                        extra: "字数 \(section.text.count)"
                    )
                }
            }
            if !payload.budget.isEmpty {
                Text(payload.budget.map { "\($0.key) \($0.value)" }.sorted().joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func sectionBlock(_ section: TraceSection) -> some View {
        let selected = section.id == selectedSectionID
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(section.id)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                Text(section.title).font(.system(size: 11, weight: .medium))
                sourceBadge(section.source)
                Text("\(section.text.count) 字").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: selected ? "chevron.up.circle.fill" : "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            sectionText(section.text)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(
                selected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1
            )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedSectionID = selected ? nil : section.id
            selectedMessageID = nil
        }
    }

    /// The provenance card: origin + rule for one block.
    private func provenanceCard(source: String, origin: String, rule: String, extra: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("这块从哪里来", systemImage: "arrow.turn.up.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            row("类型", source)
            row("来源", origin)
            row("规则", rule)
            row("规模", extra)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private func sourceBadge(_ source: String) -> some View {
        Text(source)
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
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
        case "user": Color.blue
        case "assistant": Color.green
        case "tool": Color.orange
        default: Color.secondary
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 32, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Message document

    /// The message sequence kept by the trimmer. Clicking one shows where it lives and why
    /// it survived the budget cut.
    private func normalized(_ message: TraceMessage, index: Int) -> TraceMessage {
        var message = message
        if message.id.isEmpty { message.id = "M\(index + 1)" }
        return message
    }

    private func messageDocument(_ payload: TracePayload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("发送的消息序列（裁剪后，按发送顺序）")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("共 \(payload.messages.count) 条")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(payload.messages.enumerated()), id: \.offset) { offset, messageIn in
                let message = normalized(messageIn, index: offset)
                messageBlock(message)
                if message.id == selectedMessageID {
                    provenanceCard(
                        source: message.role,
                        origin: message.origin.isEmpty ? "messages 表" : message.origin,
                        rule: message.rule.isEmpty ? "TranscriptBuilder.trim：预算裁剪 + 头部修复" : message.rule,
                        extra: "\(message.chars) 字\(message.truncated ? " · 展示已截断" : "")"
                    )
                }
            }
        }
    }

    private func messageBlock(_ message: TraceMessage) -> some View {
        let selected = message.id == selectedMessageID
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(message.id)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
                roleBadge(message.role)
                if let name = message.name, !name.isEmpty {
                    Text(name).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let seq = message.seq {
                    Text("seq \(seq)").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text("\(message.chars) 字").font(.system(size: 10)).foregroundStyle(.secondary)
                if message.truncated {
                    Text("已截断").font(.system(size: 9)).foregroundStyle(.orange)
                }
                Spacer()
            }
            sectionText(message.text).lineLimit(6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(
                selected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1
            )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedMessageID = selected ? nil : message.id
            selectedSectionID = nil
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

    private func reload(selectLatest: Bool = false) async {
        loading = true
        traces = await store.loadTraces()
        loading = false
        let currentExists = traces.contains { $0.id == selectedID }
        if selectLatest || selectedID == nil || !currentExists {
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
