import Testing

@testable import DirectaKit

@Suite struct DeepLinkNotificationActionTests {
    @Test func openActionMapsToOpenLinkWithHead() {
        let link = DeepLinkNotificationAction.link(
            actionId: DeepLinkNotificationAction.open.rawValue,
            projectSlug: "myproj", server: "cms", head: "wren-hollow")
        #expect(link == DeepLink(verb: .open, projectSlug: "myproj", server: "cms", head: "wren-hollow"))
    }

    @Test func openActionWithoutHead() {
        let link = DeepLinkNotificationAction.link(
            actionId: DeepLinkNotificationAction.open.rawValue, projectSlug: "myproj", server: "cms")
        #expect(link == DeepLink(verb: .open, projectSlug: "myproj", server: "cms"))
    }

    @Test func whyActionMapsToWhyAndDropsHead() {
        let link = DeepLinkNotificationAction.link(
            actionId: DeepLinkNotificationAction.why.rawValue,
            projectSlug: "myproj", server: "cms", head: "ignored")
        #expect(link == DeepLink(verb: .why, projectSlug: "myproj", server: "cms"))
    }

    @Test func defaultBodyTapMapsToOpen() {
        let link = DeepLinkNotificationAction.link(
            actionId: DeepLinkNotificationAction.defaultActionId,
            projectSlug: "myproj", server: "cms", head: "wren-hollow")
        #expect(link == DeepLink(verb: .open, projectSlug: "myproj", server: "cms", head: "wren-hollow"))
    }

    @Test func unknownActionIsNil() {
        #expect(
            DeepLinkNotificationAction.link(
                actionId: "com.apple.UNNotificationDismissActionIdentifier",
                projectSlug: "myproj", server: "cms") == nil)
    }
}
