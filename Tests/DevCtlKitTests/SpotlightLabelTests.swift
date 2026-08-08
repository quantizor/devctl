import Foundation
import Testing

@testable import DevCtlKit

@Suite struct SpotlightLabelTests {
    @Test func titleOmitsRedundantServerName() {
        #expect(SpotlightLabel.title(project: "myproj", server: "myproj", head: nil) == "myproj")
        #expect(
            SpotlightLabel.title(project: "myproj", server: "myproj", head: "operator")
                == "myproj · operator")
        #expect(
            SpotlightLabel.title(project: "styled-components", server: "native", head: nil)
                == "styled-components · native")
    }

    @Test func subtitleLeadsWithBrand() {
        #expect(
            SpotlightLabel.subtitle(url: "http://myproj.localhost:3000/")
                == "devctl · http://myproj.localhost:3000/")
    }

    @Test func keywordsIncludeProjectHostAndAnchors() {
        #expect(
            SpotlightLabel.keywords(
                project: "myproj", server: "myproj", head: "operator",
                url: "http://myproj.localhost:3000/")
                == ["dev server", "devctl", "myproj", "operator"])
        #expect(
            SpotlightLabel.keywords(
                project: "myproj", server: "myproj", head: "qa",
                url: "http://demo1.localhost:3000/qa")
                == ["demo1", "dev server", "devctl", "myproj", "qa"])
    }

    @Test func alternateNamesDropPrimaryTitle() {
        #expect(
            SpotlightLabel.alternateNames(
                project: "myproj", server: "myproj", head: "operator",
                url: "http://myproj.localhost:3000/")
                == ["myproj", "operator"])
        #expect(
            SpotlightLabel.alternateNames(
                project: "styled-components", server: "native", head: nil,
                url: "http://native.localhost:3000/")
                == ["native", "styled-components"])
    }

    @Test func rankingHintTiersLiveAndPinned() {
        #expect(SpotlightLabel.rankingHint(phase: .running, pinned: false) == 100)
        #expect(SpotlightLabel.rankingHint(phase: .stopped, pinned: true) == 100)
        #expect(SpotlightLabel.rankingHint(phase: .starting, pinned: false) == 95)
        #expect(SpotlightLabel.rankingHint(phase: .stopped, pinned: false) == 90)
    }
}
