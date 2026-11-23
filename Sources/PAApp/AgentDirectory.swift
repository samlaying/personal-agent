import Foundation
import Observation
import PACore

/// The set of agents the user can talk to, loaded from the store. The single-agent UI
/// picks `current`; a future team mode composes several profiles behind one session,
/// which is why profiles already carry per-agent identity and instructions.
@MainActor
@Observable
final class AgentDirectory {
    static let shared = AgentDirectory()

    private(set) var agents: [AgentProfile] = []
    var currentID: String = AgentProfile.defaultID

    private let store: MemoryStore

    init(store: MemoryStore = ChatStore.shared.store) {
        self.store = store
    }

    var current: AgentProfile {
        agents.first { $0.id == currentID } ?? .makeDefault()
    }

    func load() async {
        do {
            let loaded = try await store.agents()
            agents = loaded.isEmpty ? [.makeDefault()] : loaded
            if !agents.contains(where: { $0.id == currentID }) {
                currentID = agents[0].id
            }
        } catch {
            agents = [.makeDefault()]
        }
    }

    func select(_ id: String) {
        currentID = id
    }

    func save(_ profile: AgentProfile) async {
        do {
            try await store.upsertAgent(profile)
            await load()
            currentID = profile.id
        } catch {
            ChatStore.shared.report("保存 Agent 失败：\(error.localizedDescription)")
        }
    }

    func delete(_ profile: AgentProfile) async {
        guard profile.id != AgentProfile.defaultID else { return }
        do {
            try await store.deleteAgent(id: profile.id)
            await load()
            if currentID == profile.id {
                currentID = agents.first?.id ?? AgentProfile.defaultID
            }
        } catch {
            ChatStore.shared.report("删除 Agent 失败：\(error.localizedDescription)")
        }
    }
}
