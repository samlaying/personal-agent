import AppKit

// SwiftUI's `MenuBarExtra` leaves a blank slot in the menu bar for this app on macOS 26
// (the status item exists with the right size but draws nothing), so the menu bar item is
// built directly with `NSStatusItem` in `AppDelegate`.
//
// A plain `main.swift` instead of `@main struct ...: App`: there is no SwiftUI scene left,
// and an `App` with zero scenes is not allowed.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
