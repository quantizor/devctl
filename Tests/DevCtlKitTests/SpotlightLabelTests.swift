import Foundation
import Testing

@testable import DevCtlKit

@Suite struct SpotlightLabelTests {
    @Test func titleOmitsRedundantServerName() {
        #expect(SpotlightLabel.title(project: "candor", server: "candor", head: nil) == "candor")
        #expect(
            SpotlightLabel.title(project: "candor", server: "candor", head: "operator")
                == "candor · operator")
        #expect(
            SpotlightLabel.title(project: "styled-components", server: "native", head: nil)
                == "styled-components · native")
    }

    @Test func subtitleLeadsWithBrand() {
        #expect(
            SpotlightLabel.subtitle(url: "http://candor.localhost:3000/")
                == "devctl · http://candor.localhost:3000/")
    }

    @Test func keywordsIncludeProjectHostAndAnchors() {
        #expect(
            SpotlightLabel.keywords(
                project: "candor", server: "candor", head: "operator",
                url: "http://candor.localhost:3000/")
                == ["candor", "dev server", "devctl", "operator"])
        #expect(
            SpotlightLabel.keywords(
                project: "candor", server: "candor", head: "qa",
                url: "http://demo1.localhost:3000/qa")
                == ["candor", "demo1", "dev server", "devctl", "qa"])
    }
}
