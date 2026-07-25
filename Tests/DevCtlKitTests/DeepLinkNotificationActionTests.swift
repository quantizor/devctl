import Testing

@testable import DevCtlKit

@Suite struct DeepLinkNotificationActionTests {
    @Test func openActionMapsToOpenLinkWithHead() {
        let link = DeepLinkNotificationAction.link(
            actionId: DeepLinkNotificationAction.open.rawValue,
            projectSlug: "candor", server: "cms", head: "wren-hollow")
        #expect(link == DeepLink(verb: .open, projectSlug: "candor", server: "cms", head: "wren-hollow"))
    }

    @Test func openActionWithoutHead() {
        let link = DeepLinkNotificationAction.link(
            actionId: DeepLinkNotificationAction.open.rawValue, projectSlug: "candor", server: "cms")
        #expect(link == DeepLink(verb: .open, projectSlug: "candor", server: "cms"))
    }

    @Test func whyActionMapsToWhyAndDropsHead() {
        let link = DeepLinkNotificationAction.link(
            actionId: DeepLinkNotificationAction.why.rawValue,
            projectSlug: "candor", server: "cms", head: "ignored")
        #expect(link == DeepLink(verb: .why, projectSlug: "candor", server: "cms"))
    }

    @Test func defaultBodyTapMapsToOpen() {
        let link = DeepLinkNotificationAction.link(
            actionId: DeepLinkNotificationAction.defaultActionId,
            projectSlug: "candor", server: "cms", head: "wren-hollow")
        #expect(link == DeepLink(verb: .open, projectSlug: "candor", server: "cms", head: "wren-hollow"))
    }

    @Test func unknownActionIsNil() {
        #expect(
            DeepLinkNotificationAction.link(
                actionId: "com.apple.UNNotificationDismissActionIdentifier",
                projectSlug: "candor", server: "cms") == nil)
    }
}
