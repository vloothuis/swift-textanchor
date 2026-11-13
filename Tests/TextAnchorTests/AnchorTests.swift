import Testing
@testable import TextAnchor

private let gettingStarted = """
# Getting Started

This is a test document. It has multiple paragraphs.

You can install the package using npm or yarn.

## Configuration

Configure the package by creating a config file.

"""

@Suite struct AnchorTests {
    struct NewCase: CustomTestStringConvertible, Sendable {
        var name: String
        var start: Int
        var end: Int
        var wantQuote: String = ""
        var wantError: AnchorError? = nil
        var testDescription: String { name }
    }

    static var newCases: [NewCase] {
        let doc = gettingStarted
        let thisStart = index(doc, "This is a test")
        let installStart = index(doc, "install the package")
        return [
            NewCase(name: "simple word", start: thisStart, end: thisStart + 4, wantQuote: "This"),
            NewCase(name: "phrase", start: installStart, end: installStart + len("install the package"), wantQuote: "install the package"),
            NewCase(name: "invalid range - start >= end", start: 10, end: 10, wantError: .invalidRange),
            NewCase(name: "invalid range - start > end", start: 20, end: 10, wantError: .invalidRange),
            NewCase(name: "out of bounds - negative start", start: -1, end: 10, wantError: .outOfBounds),
            NewCase(name: "out of bounds - end too large", start: 0, end: 10000, wantError: .outOfBounds),
        ]
    }

    @Test(arguments: newCases)
    func new(_ tc: NewCase) throws {
        let doc = Array(gettingStarted.utf8)
        if let want = tc.wantError {
            #expect(throws: want) { try Anchor(bytes: doc, start: tc.start, end: tc.end) }
            return
        }
        let anchor = try Anchor(bytes: doc, start: tc.start, end: tc.end)
        #expect(anchor.quote == tc.wantQuote)
    }

    @Test func newWithOptions() throws {
        let doc = """
        # Hello World

        This is a sentence with some important text in it.

        Another paragraph here.

        """
        let start = index(doc, "important text")
        let options = CreateOptions(prefixLength: 20, suffixLength: 20)
        let anchor = try Anchor(document: doc, utf8Range: start..<(start + len("important text")), options: options)
        #expect(anchor.quote == "important text")
        #expect(len(anchor.prefix) <= 20)
        #expect(len(anchor.suffix) <= 20)
        #expect(anchor.headingContext == "Hello World")
    }

    @Test func newExtractsContainingSentence() throws {
        let doc = "First sentence here. This is the target word in context. Final sentence."
        let start = index(doc, "target")
        let anchor = try Anchor(document: doc, utf8Range: start..<(start + len("target")))
        #expect(anchor.quote == "target")
        #expect(anchor.containingSentence == "This is the target word in context.")
    }

    @Test func resolveSameDocument() throws {
        let doc = gettingStarted
        let start = index(doc, "install the package")
        let end = start + len("install the package")
        let anchor = try Anchor(document: doc, utf8Range: start..<end)

        let result = anchor.resolve(in: doc)
        #expect(!result.isOrphaned, "reason: \(String(describing: result.orphanReason))")
        #expect(result.utf8Range == start..<end)
        #expect(result.confidence >= 0.9)
    }

    @Test func resolveAfterEdit() throws {
        let start = index(gettingStarted, "install the package")
        let anchor = try Anchor(document: gettingStarted, utf8Range: start..<(start + len("install the package")))

        let modified = """
        # Getting Started

        Welcome to the guide!

        This is a test document. It has multiple paragraphs.

        You can install the package using npm or yarn.

        ## Configuration

        Configure the package by creating a config file.

        """
        let result = anchor.resolve(in: modified)
        #expect(!result.isOrphaned)
        #expect(resolved(modified, result) == "install the package")
    }

    @Test func resolveWithMultipleOccurrences() throws {
        let doc = """
        # First Section

        The word test appears here.

        # Second Section

        The word test appears here too.

        # Third Section

        Something else entirely.

        """
        let first = index(doc, "test")
        let start = index(doc, "test", from: first + 1)
        let anchor = try Anchor(document: doc, utf8Range: start..<(start + 4))
        #expect(anchor.headingContext == "Second Section")

        let result = anchor.resolve(in: doc)
        #expect(!result.isOrphaned)
        #expect(result.utf8Range == start..<(start + 4))
        #expect(resolved(doc, result) == "test")
    }

    @Test func resolveOrphaned() {
        let doc = "# Hello\n\nThis document has some content.\n"
        let anchor = Anchor(
            quote: "nonexistent text that does not appear",
            prefix: "some prefix",
            suffix: "some suffix",
            headingContext: "Hello",
            paragraphIndex: 0
        )
        let result = anchor.resolve(in: doc)
        #expect(result.isOrphaned)
        #expect(result.orphanReason != nil)
    }

    @Test func resolveAll() throws {
        let doc = """
        # Document

        First paragraph with word one.

        Second paragraph with word two.

        Third paragraph with word three.

        """
        let anchors = try [("one", 3), ("two", 3), ("three", 5)].map { word, n in
            let s = index(doc, word)
            return try Anchor(document: doc, utf8Range: s..<(s + n))
        }
        let results = AnchorDocument(doc).resolve(anchors)
        #expect(results.count == 3)
        for r in results {
            #expect(!r.isOrphaned)
            #expect(r.utf8Range != nil)
        }
    }

    @Test(arguments: [
        ("simple heading", "# Hello\n\nSome text", 15, "Hello"),
        ("nested heading", "# Main\n\n## Sub\n\nContent", 20, "Sub"),
        ("no heading", "Just some text without heading", 10, ""),
        ("multiple hashes", "### Third Level\n\nContent", 20, "Third Level"),
    ])
    func extractHeading(_ name: String, _ doc: String, _ offset: Int, _ expected: String) {
        #expect(extractHeadingContext(doc, offset) == expected, "\(name)")
    }

    @Test func splitParagraphsCount() {
        let text = "First paragraph.\n\nSecond paragraph.\nStill second.\n\nThird paragraph."
        let b = Array(text.utf8)
        #expect(splitParagraphs(b, 0, b.count) == 3)
    }

    @Test(arguments: [
        ("hello", "hello", 1.0),
        ("hello", "hallo", 0.7),
        ("", "", 1.0),
        ("abc", "", 0.0),
    ])
    func similarityFloor(_ a: String, _ b: String, _ minScore: Double) {
        #expect(similarity(a, b) >= minScore)
    }
}
