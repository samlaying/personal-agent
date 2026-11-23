import AppKit
import Carbon
import PACore
import SwiftUI

/// A panel whose yellow button hides it instead of minimizing it. The app has no Dock
/// icon, so a minimized window would be stranded in the Dock's corner with no way back.
final class FloatingPanel: NSPanel {
    override func miniaturize(_ sender: Any?) {
        orderOut(nil)
    }
}

/// The always-available chat window: a floating panel toggled by the global hotkey
/// (and by the menu bar item). Escape hides it.
@MainActor
final class ChatPanelController {
    static let shared = ChatPanelController()

    private var panel: NSPanel?
    private let hotkey = HotkeyCenter()

    func setUp() {
        makePanelIfNeeded()
        registerHotkey()
    }

    private func makePanelIfNeeded() {
        guard panel == nil else { return }

        let chat = ChatView()
            .environment(ChatStore.shared)
            .environment(AgentDirectory.shared)

        let content = NSHostingView(rootView: chat)
        // Wide enough for the session sidebar plus the conversation column.
        let frame = NSRect(x: 0, y: 0, width: 800, height: 680)

        // A standard titled panel: the traffic lights (close / minimize / zoom) sit in the
        // native title bar, so content starts below them.
        let panel = FloatingPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "个人助理"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 620, height: 480)
        panel.contentView = content
        panel.setFrameAutosaveName("pa-chat-panel-v3")
        panel.center()
        self.panel = panel

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, let keyWindow = NSApp.keyWindow, keyWindow === panel {
                ChatPanelController.shared.toggle()
                return nil
            }
            return event
        }
    }

    private func registerHotkey() {
        guard AppSettings.shared.hotkeyEnabled else { return }
        hotkey.register(keyCode: 49, carbonModifiers: UInt32(optionKey)) { [weak self] in
            self?.toggle()
        }
    }

    func enableHotkey() {
        registerHotkey()
    }

    func disableHotkey() {
        hotkey.unregister()
    }

    func toggle() {
        guard let panel else { return }
        // Visibility alone decides: key-window state is racy right after a status item
        // click, which made the click after showing a no-op.
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        // A panel left minimized has to come back out too, or it stays orphaned.
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        panel.makeKeyAndOrderFront(nil)
    }
}
