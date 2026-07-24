import Foundation

/** The user-notification action buttons devctl attaches to a server alert, and
    the mapping from a tapped action back into a `DeepLink`. Kept beside `DeepLink`
    (and free of AppKit/UserNotifications) so the mapping is unit-testable without
    a running app. The raw value is the `UNNotificationAction` identifier. */
public enum DeepLinkNotificationAction: String, Sendable, Equatable, CaseIterable {
    case open = "dev.quantizor.devctl.notification.open"
    case why = "dev.quantizor.devctl.notification.why"

    /** The link a tapped action fires, or nil when the identifier is not one of
        ours (a system action like the default tap or dismiss). `head` rides along
        only for `open`, matching `DeepLink`'s own head rule. */
    public static func link(
        actionId: String, projectSlug: String, server: String, head: String? = nil
    ) -> DeepLink? {
        guard let action = DeepLinkNotificationAction(rawValue: actionId) else { return nil }
        switch action {
        case .open:
            return DeepLink(verb: .open, projectSlug: projectSlug, server: server, head: head)
        case .why:
            return DeepLink(verb: .why, projectSlug: projectSlug, server: server)
        }
    }
}
