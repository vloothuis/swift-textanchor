import Foundation
import Testing
import QuoteFind
import TextAnchor

/// The examples in README.md.
@Suite struct ReadmeTests {
    @Test func anchorExample() throws {
        let document = "# Setup\n\nInstall the tools. Then run the tests.\n"
        let range = document.range(of: "run the tests")!
        let anchor = try Anchor(document: document, range: range)
        let json = try JSONEncoder().encode(anchor)
        #expect(try JSONDecoder().decode(Anchor.self, from: json) == anchor)

        let edited = "# Setup\n\nFirst install the tools.\nThen run the tests.\n"
        let result = anchor.resolve(in: edited)
        let found = try #require(result.range)
        #expect(edited[found] == "run the tests")
        #expect(AnchorDocument(edited).resolve([anchor]).first?.utf8Range == result.utf8Range)
    }

    @Test func quoteFinderExample() throws {
        let markdown = "Some **bold** text and a [link](https://example.com)."
        let match = try #require(QuoteFinder.find("bold text and a link", in: markdown))
        #expect(markdown[match.range] == "bold** text and a [link")
    }

    @Test func segmentsExample() {
        let markdown = "## Title\n\n- [ ] first **item**\n- second\n"
        let range = markdown.range(of: "Title")!.lowerBound..<markdown.range(of: "second")!.upperBound
        let segments = SegmentedDocument(markdown).segments(range).map { String(markdown[$0]) }
        #expect(segments == ["Title", "first **item**", "second"])
    }
}
