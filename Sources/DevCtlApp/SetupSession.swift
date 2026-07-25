import AppKit
import DevCtlKit
import Observation
import SwiftUI

/** Shared first-run / upgrade gate evaluated once at launch. */
@Observable
final class SetupSession {
    var installAppToApplications = false
    var migration = false
    var offers: [HarnessOffer] = []
    var pathWarning = false
    var replacingApplicationsApp = false
    var shouldPresent = false

    func evaluate() {
        let eval = SetupPerformer.evaluatePresentation()
        installAppToApplications = eval.installAppToApplications
        migration = eval.migration
        offers = eval.offers
        pathWarning = eval.pathWarning
        replacingApplicationsApp = eval.replacingApplicationsApp
        shouldPresent = eval.shouldPresent
    }
}

/** Opens the setup window from a view that has `openWindow` (the menu bar label). */
struct SetupWindowOpener: View {
    @Environment(\.openWindow) private var openWindow
    var session: SetupSession
    @State private var didOpen = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                session.evaluate()
                guard session.shouldPresent, !didOpen else { return }
                didOpen = true
                openWindow(id: "setup")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

/** Close the setup SwiftUI window by id (macOS 14-safe; dismissWindow is 15+). */
enum SetupWindowCloser {
    static func close() {
        for window in NSApp.windows where window.identifier?.rawValue == "setup" {
            window.close()
        }
    }
}
