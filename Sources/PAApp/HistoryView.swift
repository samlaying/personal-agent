import PACore
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var directory: AgentDirectory

    @State private var sessions: [ChatSession] = []
    @State private var query = ""
    @State private var hits: [HistoryHit] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            List {
                if !query.isEmpty {
                    Section("搜索结果") {
                        if hits.isEmpty && !searching {
                            Text("没有匹配的记录")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(hit.sessionTitle.isEmpty ? "未命名会话" : hit.sessionTitle)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text(hit.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(hit.snippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                open(hit)
                            }
                        }
                    }
                } else {
                    Section("会话") {
                        ForEach(sessions) { session in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.displayTitle)
                                        .lineLimit(1)
                                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if session.id == store.session?.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task {
                                    await store.open(session)
                                    ChatPanelController.shared.show()
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.delete(session, agent: directory.current)
                                    Task { await reload() }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史记录")
            .searchable(text: $query, prompt: "搜索对话内容")
            .onChange(of: query) { _, newValue in
                Task { await search(newValue) }
            }
            .task { await reload() }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        ChatStore.shared.newSession(agent: directory.current)
                        HistoryWindowController.shared.close()
                        ChatPanelController.shared.show()
                    } label: {
                        Label("新对话", systemImage: "plus")
                    }
                    Spacer()
                    Button("完成") { HistoryWindowController.shared.close() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
                .background(.bar)
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private func reload() async {
        sessions = (try? await store.store.listSessions()) ?? []
    }

    private func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            hits = []
            return
        }
        searching = true
        hits = (try? await store.store.searchHistory(trimmed, limit: 20)) ?? []
        searching = false
    }

    private func open(_ hit: HistoryHit) {
        guard let session = sessions.first(where: { $0.id == hit.sessionID }) else { return }
        Task {
            await store.open(session)
            ChatPanelController.shared.show()
        }
    }
}
