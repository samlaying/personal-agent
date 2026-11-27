import AppKit
import PACore
import SwiftUI

/// Settings and history live in their own AppKit windows so any view (including the
/// AppKit-hosted chat panel) can open them, which SwiftUI's `openWindow` cannot do
/// from outside a scene.

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let root = SettingsView()
                .environment(AppSettings.shared)
                .environment(AgentDirectory.shared)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "设置"
            window.contentView = NSHostingView(rootView: root)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}

/// Viewer for the persisted per-turn traces (call chain + prompt composition).
@MainActor
final class TraceWindowController {
    static let shared = TraceWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "运行轨迹"
            window.contentView = NSHostingView(rootView: TraceView().environment(ChatStore.shared))
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
