import DevCtlKit
import SwiftUI

/** Phase 6 fills this in; the stub keeps the target building from day one. */
@main
struct DevCtlApp: App {
    var body: some Scene {
        MenuBarExtra("devctl", systemImage: "server.rack") {
            Text("devctl \(DevCtlVersion.version)")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
