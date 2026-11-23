import AppKit
import Carbon
import PACore
import SwiftUI

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
            .environmentObject(ChatStore.shared)
            .environmentObject(AgentDirectory.shared)

        let content = NSHostingView(rootView: chat)
        // Wide enough for the session sidebar plus the conversation column.
        let frame = NSRect(x: 0, y: 0, width: 800, height: 680)

        // A standard titled panel: the traffic lights (close / minimize / zoom) sit in the
        // native title bar, so content starts below them.
        let panel = NSPanel(
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
        log("toggle visible=\(panel.isVisible) key=\(NSApp.keyWindow === panel)")
        if panel.isVisible, NSApp.keyWindow === panel {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        guard let panel else {
            log("show: no panel")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        log("show: visible=\(panel.isVisible) frame=\(panel.frame) screen=\(String(describing: panel.screen?.visibleFrame))")
    }

    /// Temporary diagnostics: append panel state to /tmp/pa-panel.log.
    private func log(_ text: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(text)\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/pa-panel.log") {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: "/tmp/pa-panel.log"))
        }
    }
}
