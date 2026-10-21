import AppKit
import SwiftUI

/// Single About / Help panel — replaces the system About box and the separate Help window.
@MainActor
enum AboutPanel {
    private static var window: NSWindow?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)

        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: AboutView(onClose: { close() }))
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "About Laradeck"
        newWindow.styleMask = [.titled, .closable]
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
    }

    private static func close() {
        window?.close()
        window = nil
    }
}
