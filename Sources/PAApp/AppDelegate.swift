import AppKit
import PACore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private static let statusItemName = "PersonalAgent-status"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: resident in the menu bar, never in the Dock.
        NSApp.setActivationPolicy(.accessory)
        makeStatusItem()

        ChatPanelController.shared.setUp()
        Task {
            await AgentDirectory.shared.load()
            await ChatStore.shared.bootstrap(agent: AgentDirectory.shared.current)
        }
        // Show the panel right away: a menu bar item alone is easy to miss.
        ChatPanelController.shared.show()

        // Dev aid: defaults write com.sam.personal-agent dev.openTraceOnLaunch -bool YES
        if UserDefaults.standard.bool(forKey: "dev.openTraceOnLaunch") {
            TraceWindowController.shared.show()
        }
    }

    // MARK: Menu bar item

    private func makeStatusItem() {
        // On notched Macs macOS parks a brand-new item right at the notch edge, where it is
        // never composited (the window reports visible, but nothing is drawn). Seeding the
        // saved position — the same preference ⌘-dragging writes — puts it in the visible
        // stretch right of the notch. A user drag overwrites this value afterwards.
        let positionKey = "NSStatusItem Preferred Position \(Self.statusItemName)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(300, forKey: positionKey)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Self.statusItemName
        if let button = item.button {
            let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "个人助理")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "个人助理 · ⌥Space"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu.delegate = self
        buildMenu()
        statusItem = item

    }

    /// Left click opens the chat, right (or control) click drops down the menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        guard isSecondary else {
            ChatPanelController.shared.toggle()
            return
        }

        // Attaching the menu for one click is the documented way to have both behaviours.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func buildMenu() {
        menu.removeAllItems()

        let open = NSMenuItem(title: "打开对话面板", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        open.toolTip = "⌥Space"
        open.attributedTitle = Self.titled("打开对话面板", suffix: "⌥Space")
        menu.addItem(open)

        let newChat = NSMenuItem(title: "新对话", action: #selector(newChat), keyEquivalent: "")
        newChat.target = self
        menu.addItem(newChat)

        menu.addItem(.separator())

        let sidebar = NSMenuItem(title: "显示/隐藏对话列表", action: #selector(toggleSidebar), keyEquivalent: "")
        sidebar.target = self
        sidebar.state = ChatStore.shared.showSidebar ? .on : .off
        menu.addItem(sidebar)

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Grey shortcut hint on the right, like the system menus.
    private static func titled(_ title: String, suffix: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title)
        result.append(NSAttributedString(
            string: "\t" + suffix,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return result
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        buildMenu()
    }

    // MARK: Actions

    @objc private func openPanel() {
        ChatPanelController.shared.show()
    }

    @objc private func newChat() {
        ChatStore.shared.newSession(agent: AgentDirectory.shared.current)
        ChatPanelController.shared.show()
    }

    @objc private func toggleSidebar() {
        ChatStore.shared.showSidebar.toggle()
        ChatPanelController.shared.show()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
