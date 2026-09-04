import Foundation

/** The user-notification action buttons directa attaches to a server alert, and
    the mapping from a tapped action back into a `DeepLink`. Kept beside `DeepLink`
    (and free of AppKit/UserNotifications) so the mapping is unit-testable without
    a running app. The raw value is the `UNNotificationAction` identifier. */
public enum DeepLinkNotificationAction: String, Sendable, Equatable, CaseIterable {
    case open = "dev.quantizor.directa.notification.open"
    case why = "dev.quantizor.directa.notification.why"

    /** System default tap (`UNNotificationDefaultActionIdentifier`). Kept as a
        string so this module stays free of UserNotifications. */
    public static let defaultActionId = "com.apple.UNNotificationDefaultActionIdentifier"

    /** The link a tapped action fires, or nil when the identifier is not one of
        ours and not the body tap. `head` rides along only for `open`, matching
        `DeepLink`'s own head rule. Body tap maps to open so a click on the
        banner itself is not a dead end. */
    public static func link(
        actionId: String, projectSlug: String, server: String, head: String? = nil
    ) -> DeepLink? {
        if actionId == defaultActionId {
            return DeepLink(verb: .open, projectSlug: projectSlug, server: server, head: head)
        }
        guard let action = DeepLinkNotificationAction(rawValue: actionId) else { return nil }
        switch action {
        case .open:
            return DeepLink(verb: .open, projectSlug: projectSlug, server: server, head: head)
        case .why:
            return DeepLink(verb: .why, projectSlug: projectSlug, server: server)
        }
    }
}
