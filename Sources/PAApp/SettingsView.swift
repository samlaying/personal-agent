import PACore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var directory: AgentDirectory

    @AppStorage("settings.modelKeyDraft") private var modelKeyDraft = ""
    @AppStorage("settings.tavilyKeyDraft") private var tavilyKeyDraft = ""

    var body: some View {
        Form {
            Section("模型 API（OpenAI 兼容）") {
                TextField("Base URL", text: $settings.baseURL)
                TextField("模型", text: $settings.model)
                SecureField(settings.hasModelKey ? "API Key（已保存，留空保持不变）" : "API Key（sk-…）", text: $modelKeyDraft)
                HStack {
                    Toggle("温度", isOn: Binding(
                        get: { settings.temperature != nil },
                        set: { settings.temperature = $0 ? 0.7 : nil }
                    ))
                    if settings.temperature != nil {
                        Slider(value: Binding(
                            get: { settings.temperature ?? 0.7 },
                            set: { settings.temperature = $0 }
                        ), in: 0...2, step: 0.1)
                    }
                }
            }

            Section("联网搜索（Tavily）") {
                SecureField(settings.tavilyKey.isEmpty ? "Tavily API Key（不填则禁用联网搜索）" : "Tavily API Key（已保存，留空保持不变）", text: $tavilyKeyDraft)
                Text("开发计划每月约 1000 credits；每次 basic 搜索消耗 1 credit。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("快捷键") {
                Toggle("⌥Space 打开/隐藏对话面板", isOn: $settings.hotkeyEnabled)
            }

            Section("记忆") {
                LabeledContent("数据库", value: ChatStore.shared.dataDirectory.appendingPathComponent("memory.sqlite").path)
                LabeledContent("用户画像", value: MemoryFiles.url(for: MemoryFiles.userProfile, in: ChatStore.shared.dataDirectory).path)
                LabeledContent("Agent 笔记", value: MemoryFiles.url(for: MemoryFiles.notes, in: ChatStore.shared.dataDirectory).path)
            }

            Section("Agent") {
                ForEach(directory.agents) { agent in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(agent.name).fontWeight(.medium)
                            Text(agent.instructions.isEmpty ? "无指令" : agent.instructions)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("编辑") {
                            editingAgent = agent
                        }
                        if agent.id != AgentProfile.defaultID {
                            Button("删除", role: .destructive) {
                                Task { await directory.delete(agent) }
                            }
                        }
                    }
                }
                Button("新增 Agent…") {
                    editingAgent = AgentProfile(name: "", instructions: "")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        .sheet(item: $editingAgent) { agent in
            AgentEditView(agent: agent) { saved in
                Task { await directory.save(saved) }
            }
        }
        .onDisappear {
            persistKeys()
        }
        .onChange(of: settings.hotkeyEnabled) { _, enabled in
            if enabled {
                ChatPanelController.shared.enableHotkey()
            } else {
                ChatPanelController.shared.disableHotkey()
            }
            persistKeys()
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("密钥保存在系统钥匙串")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") {
                    persistKeys()
                    SettingsWindowController.shared.close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(.bar)
        }
    }

    @State private var editingAgent: AgentProfile?

    /// Keys are written back on dismiss rather than on every keystroke.
    private func persistKeys() {
        if !modelKeyDraft.isEmpty {
            settings.applyModelKey(modelKeyDraft)
            modelKeyDraft = ""
        }
        if !tavilyKeyDraft.isEmpty {
            settings.tavilyKey = tavilyKeyDraft
            tavilyKeyDraft = ""
        }
    }
}

struct AgentEditView: View {
    @State var agent: AgentProfile
    let onSave: (AgentProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("名称", text: $agent.name, prompt: Text("比如：写作助手"))
            TextField("指定模型（可选）", text: Binding(
                get: { agent.model ?? "" },
                set: { agent.model = $0.isEmpty ? nil : $0 }
            ))
            Text("指令（System Prompt 里这个 Agent 的职责）")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $agent.instructions)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 140)
                .border(.quaternary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    var saved = agent
                    if saved.id.isEmpty {
                        saved.id = UUID().uuidString
                    }
                    onSave(saved)
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(savedNameInvalid)
            }
        }
        .padding(16)
        .frame(width: 440, height: 320)
    }

    private var savedNameInvalid: Bool {
        agent.name.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
