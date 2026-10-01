import Foundation
import Testing
@testable import Rushes

// The update check only ever says. What it must not do is offer an older
// version as new, or call a beta newer than the release it leads to.

@Suite("Update check")
struct UpdateTests {
    @Test("versions compare number by number, a pre-release before its release")
    func ordering() throws {
        let v = { (s: String) in try #require(ReleaseVersion(s)) }
        #expect(try v("0.2") < v("0.3.0-beta.1"))
        #expect(try v("0.3.0-beta.1") < v("0.3.0-beta.2"))
        #expect(try v("0.3.0-beta.2") < v("0.3.0-beta.10"))
        #expect(try v("0.3.0-beta.10") < v("0.3"))
        #expect(try v("0.9") < v("0.10"))
        #expect(try v("v1.0") == v("1.0.0"))
        #expect(ReleaseVersion("nightly") == nil)
        #expect(ReleaseVersion("1..2") == nil)
    }

    @Test("the newest release wins, drafts and odd tags left out")
    func newest() throws {
        let json = Data("""
        [
          {"tag_name": "v0.4.0", "html_url": "https://github.com/stevenrsl/Rushes/releases/tag/v0.4.0", "draft": true},
          {"tag_name": "v0.3.0-beta.1", "html_url": "https://github.com/stevenrsl/Rushes/releases/tag/v0.3.0-beta.1", "draft": false, "prerelease": true},
          {"tag_name": "nightly", "html_url": "https://github.com/stevenrsl/Rushes/releases/tag/nightly", "draft": false},
          {"tag_name": "v0.2", "html_url": "https://github.com/stevenrsl/Rushes/releases/tag/v0.2", "draft": false}
        ]
        """.utf8)
        let found = try #require(UpdateCheck.newest(in: json))
        #expect(found.version.text == "0.3.0-beta.1")
        #expect(found.page.absoluteString.hasSuffix("v0.3.0-beta.1"))

        let current = try #require(ReleaseVersion("0.2"))
        #expect(UpdateCheck.outcome(current: current, answer: json) == .newer(found))
        let later = try #require(ReleaseVersion("0.3"))
        #expect(UpdateCheck.outcome(current: later, answer: json) == .upToDate)
    }

    @Test("no answer, an error, or nothing published are each said as such")
    func otherOutcomes() throws {
        let current = try #require(ReleaseVersion("0.2"))
        #expect(UpdateCheck.outcome(current: current, answer: nil) == .unreachable)
        #expect(UpdateCheck.outcome(current: current, answer: Data(#"{"message": "API rate limit exceeded"}"#.utf8)) == .unreachable)
        #expect(UpdateCheck.outcome(current: current, answer: Data("[]".utf8)) == .nothingPublished)
    }

    @Test("a page outside github.com is never offered")
    func onlyGitHub() {
        let json = Data(#"[{"tag_name": "v9.0", "html_url": "https://example.com/rushes.dmg", "draft": false}]"#.utf8)
        #expect(UpdateCheck.newest(in: json) == nil)
    }
}
