import PACore
import SwiftUI

/// Session list and full-text history search, docked to the left of the chat.
struct SessionSidebar: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var directory: AgentDirectory

    @State private var query = ""
    @State private var hits: [HistoryHit] = []
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        sessionRows
                    } else {
                        resultRows
                    }
                }
                .padding(6)
            }
            Divider()
            newChatButton
        }
        .frame(width: 216)
        .background(.bar)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("搜索对话", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !query.isEmpty {
                Button {
                    query = ""
                    hits = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
        .onChange(of: query) { _, newValue in
            Task { await search(newValue) }
        }
    }

    @ViewBuilder
    private var sessionRows: some View {
        if store.sessionList.isEmpty {
            Text("还没有对话")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 20)
        }
        ForEach(store.sessionList) { session in
            Button {
                Task { await store.open(session) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text(Self.relative(session.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    session.id == store.session?.id ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("删除", role: .destructive) {
                    store.delete(session, agent: directory.current)
                }
            }
        }
    }

    @ViewBuilder
    private var resultRows: some View {
        if hits.isEmpty {
            Text(searching ? "搜索中…" : "没有匹配的记录")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 20)
        }
        ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
            Button {
                Task { await open(hit) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.sessionTitle.isEmpty ? "未命名会话" : hit.sessionTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(hit.snippet)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var newChatButton: some View {
        Button {
            store.newSession(agent: directory.current)
        } label: {
            Label("新对话", systemImage: "plus")
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            hits = []
            return
        }
        searching = true
        hits = (try? await store.store.searchHistory(trimmed, limit: 30)) ?? []
        searching = false
    }

    private func open(_ hit: HistoryHit) async {
        if let session = store.sessionList.first(where: { $0.id == hit.sessionID }) {
            await store.open(session)
        } else {
            await store.reloadSessions()
            if let session = store.sessionList.first(where: { $0.id == hit.sessionID }) {
                await store.open(session)
            }
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
