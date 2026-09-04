import AppKit

/** Accessory (`LSUIElement`) apps can show windows, but they cannot become the
    focused app: the system menu bar stays with whoever was regular. Detail
    windows (dashboard, settings, setup, About) therefore promote to `.regular`
    for their lifetime and demote when the last one is gone, so the Dock icon
    and the directa menu exist only while there is something to own them.

    The menu bar extra's own panel is not a detail window: clicking the tally
    must not steal the menu bar or spawn a Dock icon. */
enum AppFocus {
    private static let detailIdentifiers: Set<String> = ["dashboard", "settings", "setup"]

    static func demoteIfIdle(ignoring closing: NSWindow? = nil) {
        let stillUp = NSApp.windows.contains { window in
            if let closing, window === closing { return false }
            return isDetail(window) && (window.isVisible || window.isMiniaturized)
        }
        if !stillUp, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func installObservers() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
            note in
            let window = note.object as? NSWindow
            Task { @MainActor in
                guard let window, isDetail(window) else { return }
                promote()
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            note in
            let window = note.object as? NSWindow
            Task { @MainActor in
                guard let window, isDetail(window) else { return }
                demoteIfIdle(ignoring: window)
            }
        }
    }

    static func isDetail(_ window: NSWindow) -> Bool {
        if window.level == .statusBar { return false }
        if window.styleMask.contains(.nonactivatingPanel) { return false }
        if let id = window.identifier?.rawValue, detailIdentifiers.contains(id) { return true }
        return window.title.hasPrefix("About ")
    }

    static func promote() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
