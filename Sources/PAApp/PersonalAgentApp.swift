import AppKit
import PACore
import SwiftUI

@main
struct PersonalAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(systemName: "sparkles")
        }
    }
}

struct MenuBarView: View {
    var body: some View {
        VStack {
            Button("打开对话面板\t⌥Space") {
                ChatPanelController.shared.show()
            }
            Button("新对话") {
                ChatStore.shared.newSession(agent: AgentDirectory.shared.current)
                ChatPanelController.shared.show()
            }
            Divider()
            Button("显示/隐藏对话列表") {
                ChatStore.shared.showSidebar.toggle()
                ChatPanelController.shared.show()
            }
            Button("设置…") {
                SettingsWindowController.shared.show()
            }
            Divider()
            Button("退出") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            await AgentDirectory.shared.load()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: resident in the menu bar, never in the Dock.
        NSApp.setActivationPolicy(.accessory)
        ChatPanelController.shared.setUp()
        Task {
            await AgentDirectory.shared.load()
            await ChatStore.shared.bootstrap(agent: AgentDirectory.shared.current)
        }
        // Show the panel right away: a menu bar item alone is easy to miss, especially
        // when the menu bar is full.
        ChatPanelController.shared.show()
    }
}
