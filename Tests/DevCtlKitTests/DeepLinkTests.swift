import Foundation
import Testing

@testable import DevCtlKit

@Suite struct DeepLinkParseTests {
    @Test func pathFormNoHead() throws {
        let link = try DeepLink.parse("devctl://open/my-proj/web").get()
        #expect(link == DeepLink(verb: .open, projectSlug: "my-proj", server: "web"))
    }

    @Test func pathFormWithHead() throws {
        let link = try DeepLink.parse("devctl://open/my-proj/web/wren-hollow").get()
        #expect(link == DeepLink(verb: .open, projectSlug: "my-proj", server: "web", head: "wren-hollow"))
    }

    @Test func verbsWithoutHead() throws {
        for verb in [DeepLinkVerb.ensure, .stop, .why] {
            let link = try DeepLink.parse("devctl://\(verb.rawValue)/proj/api").get()
            #expect(link == DeepLink(verb: verb, projectSlug: "proj", server: "api"))
        }
    }

    @Test func queryFormAlias() throws {
        let link = try DeepLink.parse("devctl://open?project=my-proj&server=web&head=wren-hollow").get()
        #expect(link == DeepLink(verb: .open, projectSlug: "my-proj", server: "web", head: "wren-hollow"))
    }

    @Test func queryFormEmptyHeadIsNil() throws {
        let link = try DeepLink.parse("devctl://open?project=my-proj&server=web&head=").get()
        #expect(link.head == nil)
    }

    @Test func schemeIsCaseInsensitive() throws {
        let link = try DeepLink.parse("DEVCTL://ENSURE/proj/api").get()
        #expect(link == DeepLink(verb: .ensure, projectSlug: "proj", server: "api"))
    }

    @Test func percentEncodedSegmentsDecode() throws {
        let link = try DeepLink.parse("devctl://open/my%20proj/web").get()
        #expect(link.projectSlug == "my proj")
    }

    @Test func parseFromURL() throws {
        let url = URL(string: "devctl://why/proj/api")!
        let link = try DeepLink.parse(url: url).get()
        #expect(link == DeepLink(verb: .why, projectSlug: "proj", server: "api"))
    }
}

@Suite struct DeepLinkRejectTests {
    private func expectUsage(_ string: String) {
        switch DeepLink.parse(string) {
        case .success(let link): Issue.record("expected rejection, got \(link)")
        case .failure(let error): #expect(error.code == .usage)
        }
    }

    @Test func unknownVerb() { expectUsage("devctl://frobnicate/proj/web") }
    @Test func wrongScheme() { expectUsage("http://open/proj/web") }
    @Test func missingServerSegment() { expectUsage("devctl://open/only-project") }
    @Test func tooManySegments() { expectUsage("devctl://open/proj/web/head/extra") }
    @Test func emptyServer() { expectUsage("devctl://open?project=proj&server=") }
    @Test func headOnNonOpenVerb() { expectUsage("devctl://ensure/proj/web/head") }
    @Test func slugTraversal() { expectUsage("devctl://open/../etc/web") }
    @Test func queryFormSlugWithSlash() { expectUsage("devctl://open?project=a%2Fb&server=web") }
    @Test func missingVerb() { expectUsage("devctl:///proj/web") }
}

@Suite struct DeepLinkRoundTripTests {
    @Test func pathFormRoundTrips() throws {
        for link in [
            DeepLink(verb: .open, projectSlug: "my-proj", server: "web"),
            DeepLink(verb: .open, projectSlug: "my-proj", server: "web", head: "wren-hollow"),
            DeepLink(verb: .ensure, projectSlug: "myproj", server: "cms"),
            DeepLink(verb: .stop, projectSlug: "myproj", server: "cms"),
            DeepLink(verb: .why, projectSlug: "myproj", server: "cms"),
        ] {
            let reparsed = try DeepLink.parse(link.urlString()).get()
            #expect(reparsed == link)
        }
    }

    @Test func headDroppedForNonOpenOnSerialize() throws {
        // A head can only exist on `open`, but guard the serializer directly too.
        let link = DeepLink(verb: .stop, projectSlug: "p", server: "s", head: "ignored")
        #expect(link.urlString() == "devctl://stop/p/s")
    }

    @Test func encodedSegmentRoundTrips() throws {
        let link = DeepLink(verb: .open, projectSlug: "my proj", server: "web ui")
        let reparsed = try DeepLink.parse(link.urlString()).get()
        #expect(reparsed == link)
    }
}

@Suite struct DeepLinkResolveTests {
    private let paths = [
        "/Users/x/code/myproj",
        "/Users/x/code/other",
        "/Users/x/work/other",
    ]

    @Test func uniqueMatch() throws {
        let path = try DeepLink.resolveProject(slug: "myproj", against: paths).get()
        #expect(path == "/Users/x/code/myproj")
    }

    @Test func matchIsCaseInsensitive() throws {
        let path = try DeepLink.resolveProject(slug: "MYPROJ", against: paths).get()
        #expect(path == "/Users/x/code/myproj")
    }

    @Test func ambiguousNamesCandidates() {
        switch DeepLink.resolveProject(slug: "other", against: paths) {
        case .success(let path): Issue.record("expected ambiguity, got \(path)")
        case .failure(let error):
            #expect(error.code == .usage)
            #expect(error.message.contains("/Users/x/code/other"))
            #expect(error.message.contains("/Users/x/work/other"))
        }
    }

    @Test func unknownIsNotFound() {
        switch DeepLink.resolveProject(slug: "ghost", against: paths) {
        case .success(let path): Issue.record("expected not-found, got \(path)")
        case .failure(let error): #expect(error.code == .notFound)
        }
    }

    @Test func trailingSlashPathResolves() throws {
        let path = try DeepLink.resolveProject(slug: "myproj", against: ["/Users/x/code/myproj/"]).get()
        #expect(path == "/Users/x/code/myproj/")
    }

    @Test func traversalSlugRejected() {
        switch DeepLink.resolveProject(slug: "..", against: paths) {
        case .success: Issue.record("expected rejection of '..'")
        case .failure(let error): #expect(error.code == .usage)
        }
    }

    @Test func slashSlugRejected() {
        switch DeepLink.resolveProject(slug: "a/b", against: paths) {
        case .success: Issue.record("expected rejection of 'a/b'")
        case .failure(let error): #expect(error.code == .usage)
        }
    }
}
