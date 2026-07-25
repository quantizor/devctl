import AppKit
import DevCtlKit
import Foundation
import UserNotifications

/** AppKit / UserNotifications side effects for `DeepLinkRunner`. */
struct AppDeepLinkEffects: DeepLinkEffects {
    func copyToPasteboard(_ text: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "devctl-deeplink-\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func openBrowser(_ url: URL) async {
        /** Best effort: a browser that refuses to open is not worth failing the
            deep link over, and the caller has no recovery for it either. */
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}

/** Shared deep-link dispatch used by URL opens and notification actions. */
enum AppDeepLinkDispatch {
    static let serverAlertCategory = "dev.quantizor.devctl.server-alert"
    static let userInfoProject = "project"
    static let userInfoServer = "server"
    static let userInfoHead = "head"

    static func run(_ url: URL) {
        if isDaemonControl(url) {
            Task { await executeDaemonControl(url) }
            return
        }
        switch DeepLink.parse(url: url) {
        case .failure(let error):
            DevCtlLog.deeplink.error("reject \(error.message)")
            Task {
                await AppDeepLinkEffects().notify(title: "devctl link failed", body: error.message)
            }
        case .success(let link):
            Task { await execute(link) }
        }
    }

    /** `devctl://daemon/ensure` and `devctl://daemon/unregister`: CLI asks the
        app to own SMAppService registration (correct Bundle.main). */
    private static func isDaemonControl(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "devctl",
            url.host?.lowercased() == "daemon"
        else { return false }
        let action = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return action == "ensure" || action == "unregister"
    }

    private static func executeDaemonControl(_ url: URL) async {
        let action = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        do {
            switch action {
            case "ensure":
                try await AgentService.ensureRunning()
                DevCtlLog.app.info("deeplink daemon/ensure ok")
            case "unregister":
                try await AgentService.unregister()
                DevCtlLog.app.info("deeplink daemon/unregister ok")
            default:
                break
            }
        } catch {
            DevCtlLog.app.error("deeplink daemon/\(action): \(error.localizedDescription)")
            await AppDeepLinkEffects().notify(
                title: "devctl daemon control failed", body: error.localizedDescription)
        }
    }

    static func run(_ link: DeepLink) {
        Task { await execute(link) }
    }

    private static func execute(_ link: DeepLink) async {
        let client = DaemonClient(socketPath: DevCtlPaths().socketPath)
        do {
            try await client.connect()
            let result = try await DeepLinkRunner(client: client, effects: AppDeepLinkEffects()).run(link)
            DevCtlLog.app.info(
                "deeplink \(result.verb.rawValue) \(result.projectPath) \(result.detail ?? "")")
        } catch let error as WireError {
            DevCtlLog.deeplink.error("\(error.message)")
            await AppDeepLinkEffects().notify(title: "devctl link failed", body: error.message)
        } catch {
            DevCtlLog.deeplink.error("\(error)")
            await AppDeepLinkEffects().notify(title: "devctl link failed", body: String(describing: error))
        }
    }

    /** Register Open / Why actions once at launch. */
    static func registerNotificationCategories() {
        let open = UNNotificationAction(
            identifier: DeepLinkNotificationAction.open.rawValue, title: "Open")
        let why = UNNotificationAction(
            identifier: DeepLinkNotificationAction.why.rawValue, title: "Why")
        let category = UNNotificationCategory(
            identifier: serverAlertCategory, actions: [open, why], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
