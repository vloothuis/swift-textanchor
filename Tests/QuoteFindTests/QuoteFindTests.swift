import Testing
@testable import QuoteFind
import TextAnchor

func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
func sub(_ s: String, _ r: Range<Int>) -> String { String(decoding: bytes(s)[r], as: UTF8.self) }
func byteIndex(_ s: String, _ needle: String, from: Int = 0) -> Int {
    firstIndex(of: bytes(needle), in: bytes(s), from: from) ?? -1
}

/// Whitespace collapsed to single spaces, trimmed, as a browser shows text.
func normalized(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

@Suite struct QuoteFindTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var content: String
        var quote: String
        var want: Range<Int>?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "exact match", content: "Hello world", quote: "Hello world", want: 0..<11),
        Case(name: "exact match in middle", content: "Some prefix Hello world some suffix", quote: "Hello world", want: 12..<23),
        Case(name: "heading without hash", content: "# Features\n\nSome content", quote: "Features", want: 2..<10),
        Case(name: "cross heading and paragraph", content: "# Features\n\nFirst paragraph here.",
             quote: "Features\n\nFirst paragraph", want: 2..<27), // The Go test says 28 but allows any end; Go returns 27.
        Case(name: "list items without markers", content: "- Item one\n- Item two\n- Item three",
             quote: "Item one\nItem two", want: 2..<21),
        Case(name: "bold text without asterisks", content: "Some **bold** text", quote: "bold", want: 7..<11),
        Case(name: "whitespace normalization", content: "Word one   word two", quote: "Word one word two", want: 0..<19),
        Case(name: "newline as space", content: "First line\nSecond line", quote: "First line Second line", want: 0..<22),
        Case(name: "no match", content: "Hello world", quote: "Goodbye world", want: nil),
        Case(name: "link text without url", content: "Click [here](https://example.com) now", quote: "here", want: 7..<11),
        Case(name: "numbered list", content: "1. First\n2. Second\n3. Third", quote: "First\nSecond", want: 3..<18),
        Case(name: "code block content", content: "```go\nfunc main() {\n}\n```", quote: "func main() {\n}", want: 6..<21),
        Case(name: "cross paragraph and code block", content: "Some text here:\n\n```toml\n[keys]\nvalue = 1\n```",
             quote: "Some text here:\n\n[keys]\nvalue = 1", want: 0..<41),
        Case(name: "entire fenced code block", content: "Before\n\n```python\nprint('hello')\n```\n\nAfter",
             quote: "[keys]\nprint('hello')", want: nil),
        Case(name: "code fence markers stripped", content: "Text before:\n\n```\ncode here\n```\n\nText after",
             quote: "Text before:\n\ncode here\n\nText after", want: 0..<43),
        Case(name: "tilde code fence", content: "~~~bash\necho hello\n~~~", quote: "echo hello", want: 8..<18),
    ]

    @Test(arguments: cases)
    func find(_ tc: Case) throws {
        let got = QuoteFinder.find(tc.quote, in: tc.content)
        guard let want = tc.want else {
            #expect(got == nil, "found \(String(describing: got?.utf8Range))")
            return
        }
        let r = try #require(got?.utf8Range, "not found")
        #expect(r == want, "matched \(sub(tc.content, r))")
        // The match holds every word of the quote.
        let matched = sub(tc.content, r).lowercased()
        for word in normalized(tc.quote).split(separator: " ") {
            #expect(matched.contains(word.lowercased()), "missing \(word) in \(matched)")
        }
    }

    @Test func contextDisambiguates() throws {
        let content = """
        # margin

        A CLI tool for annotating Markdown documents without modifying the source files.

        ## Web Interface

        The web interface provides:
        - Document browser with annotation counts
        - Markdown rendering with syntax highlighting

        """
        let m = try #require(QuoteFinder.find("Markdown", in: content,
            prefix: "rovides:\n\nDocument browser with annotation counts\n",
            suffix: " rendering with syntax highlighting\nAnnotation sid"))
        #expect(sub(content, m.utf8Range) == "Markdown")
        #expect(m.utf8Range.lowerBound >= 100, "found the first occurrence")
        #expect(String(content[m.range]) == "Markdown")
    }

    @Test(arguments: [
        ("# Heading", "Heading"),
        ("## Subheading", "Subheading"),
        ("- List item", "List item"),
        ("1. First item", "First item"),
        ("Some **bold** text", "Some bold text"),
        ("Some *italic* text", "Some italic text"),
        ("[click here](http://example.com)", "click here"),
        ("Multiple   spaces   here", "Multiple spaces here"),
        ("Line one\n\nLine two", "Line one Line two"),
        ("# Features\n\n- **Bold** item\n- *Italic* item", "Features Bold item Italic item"),
    ])
    func renderedText(_ input: String, _ want: String) {
        #expect(normalized(RenderedText(markdown: input).text) == want)
    }

    @Test func renderedTextMapsEveryByte() {
        let md = "# Title\n\nSome **bold** and `code` text\nwith a [link](x).\n"
        let r = RenderedText(markdown: md)
        #expect(r.sourceOffsets.count == r.bytes.count + 1)
        for (i, b) in r.bytes.enumerated() where b != 0x20 {
            #expect(bytes(md)[r.sourceOffsets[i]] == b, "byte \(i)")
        }
    }

    @Test func acrossTableCells() throws {
        let doc = "| name | value |\n|------|-------|\n| alpha | beta |\n"
        let m = try #require(QuoteFinder.find("alpha beta", in: doc))
        #expect(sub(doc, m.utf8Range) == "alpha | beta")
    }

    @Test func multiByteOffsets() throws {
        let doc = "# Überschrift\n\nÄpfel und **Birnen** 🍐.\n"
        let m = try #require(QuoteFinder.find("und Birnen 🍐", in: doc))
        #expect(String(doc[m.range]) == "und **Birnen** 🍐")
        let u16 = m.utf16Range
        #expect(String(doc.utf16[doc.utf16.index(doc.utf16.startIndex, offsetBy: u16.lowerBound)..<doc.utf16.index(doc.utf16.startIndex, offsetBy: u16.upperBound)]) == "und **Birnen** 🍐")
    }
}

@Suite struct SegmentTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var doc: String
        var from: String
        var to: String
        var want: [String]
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "heading into its body", doc: "## Configuration\n\nConfigure the package by creating a file.\n",
             from: "Configuration", to: "the package", want: ["Configuration", "Configure the package"]),
        Case(name: "single block is one segment", doc: "One paragraph with a phrase\nwrapped over two lines.\n",
             from: "phrase", to: "two lines", want: ["phrase\nwrapped over two lines"]),
        Case(name: "tight list items drop their markers", doc: "- first item\n- second item\n- third item\n",
             from: "item", to: "third", want: ["item", "second item", "third"]),
        Case(name: "task items drop their checkboxes", doc: "- [ ] write tests\n- [x] ship it\n",
             from: "tests", to: "ship", want: ["tests", "ship"]),
        Case(name: "covered task item starting with emphasis keeps it balanced",
             doc: "Intro text.\n\n- [ ] **bold** rest\n- [x] [link](https://example.com) more\n",
             from: "text.", to: "more", want: ["text.", "**bold** rest", "[link](https://example.com) more"]),
        Case(name: "covered block ending in a backslash leaves it out", doc: "Path is C:\\dir\\\n\nNext paragraph.\n",
             from: "Path", to: "Next", want: ["Path is C:\\dir", "Next"]),
        Case(name: "escaped backslash at the end stays in", doc: "Ends with \\\\\n\nNext paragraph.\n",
             from: "Ends", to: "Next", want: ["Ends with \\\\", "Next"]),
        Case(name: "start inside emphasis moves to its opening delimiter",
             doc: "Read the **important** text.\n\nNext paragraph.\n",
             from: "portant", to: "Next", want: ["**important** text.", "Next"]),
        Case(name: "start inside link text moves to its opening bracket",
             doc: "See [the docs](https://example.com) here.\n\nNext paragraph.\n",
             from: "docs", to: "Next", want: ["[the docs](https://example.com) here.", "Next"]),
        Case(name: "start inside nested emphasis moves to the outer delimiter",
             doc: "A ***very*** **bold *claim*** here.\n\nNext paragraph.\n",
             from: "claim", to: "Next", want: ["**bold *claim*** here.", "Next"]),
        Case(name: "range inside one emphasis is left alone", doc: "Read the **important** text.\n",
             from: "port", to: "ant", want: ["portant"]),
        Case(name: "covered block keeps edge emphasis balanced",
             doc: "Intro text.\n\n**Bold** start and *end*\n\nOutro text.\n",
             from: "text.", to: "Outro", want: ["text.", "**Bold** start and *end*", "Outro"]),
        Case(name: "covered heading keeps edge emphasis balanced", doc: "Before.\n\n## **Bold** title ##\n\nAfter.\n",
             from: "Before", to: "After", want: ["Before.", "**Bold** title", "After"]),
        Case(name: "fenced code block is skipped", doc: "Before the code.\n\n```go\nx := 1\n```\n\nAfter the code.\n",
             from: "the code.", to: "After", want: ["the code.", "After"]),
        Case(name: "inline code is included whole", doc: "Heading\n=======\n\nRun `make test` before pushing.\n",
             from: "Heading", to: "pushing", want: ["Heading", "Run `make test` before pushing"]),
        Case(name: "double-backtick code span is included whole", doc: "Use `` a`b `` here.\n",
             from: "Use", to: "here", want: ["Use `` a`b `` here"]),
        Case(name: "start inside code widens to its backtick", doc: "Run `make test` now.\n\nNext.\n",
             from: "test", to: "Next", want: ["`make test` now.", "Next"]),
        Case(name: "end inside code widens to its backtick", doc: "Intro.\n\nRun `make test` now.\n",
             from: "Intro", to: "make", want: ["Intro.", "Run `make test`"]),
        Case(name: "range inside one code span marks the span", doc: "Run `make test` now.\n",
             from: "make", to: "make", want: ["`make test`"]),
        Case(name: "table cells are separate", doc: "| a | b |\n|---|---|\n| one | two |\n",
             from: "one", to: "two", want: ["one", "two"]),
        Case(name: "blockquote paragraph is one segment", doc: "Intro.\n\n> quote line\n> second line\n",
             from: "Intro", to: "second", want: ["Intro.", "quote line\n> second"]),
        Case(name: "html block is skipped", doc: "Before.\n\n<div>\nraw\n</div>\n\nAfter.\n",
             from: "Before", to: "After", want: ["Before.", "After"]),
        Case(name: "multibyte text", doc: "# Überschrift\n\nÄpfel und Birnen.\n",
             from: "Überschrift", to: "und", want: ["Überschrift", "Äpfel und"]),
    ]

    @Test(arguments: cases)
    func segments(_ tc: Case) throws {
        let s = byteIndex(tc.doc, tc.from)
        let e = byteIndex(tc.doc, tc.to, from: s)
        try #require(s >= 0 && e >= 0)
        let got = SegmentedDocument(tc.doc).segments(utf8Range: s..<(e + bytes(tc.to).count)).map { sub(tc.doc, $0) }
        #expect(got == tc.want)
    }

    @Test(arguments: [("empty range", 3, 3), ("only markup", 0, 2), ("only blank line", 7, 9)])
    func degenerate(_ name: String, _ start: Int, _ end: Int) {
        #expect(SegmentedDocument("# Title\n\nBody.\n").segments(utf8Range: start..<end).isEmpty, "\(name)")
    }

    @Test func clampsOutOfRange() {
        let doc = "# Title\n\nBody.\n"
        #expect(SegmentedDocument(doc).segments(utf8Range: -5..<(bytes(doc).count + 10)).count == 2)
        #expect(SegmentedDocument("").segments(utf8Range: 0..<0).isEmpty)
    }

    @Test func stringIndexForm() {
        let doc = "# Überschrift\n\nÄpfel und Birnen.\n"
        let r = doc.range(of: "Überschrift")!.lowerBound..<doc.range(of: "und")!.upperBound
        #expect(SegmentedDocument(doc).segments(r).map { String(doc[$0]) } == ["Überschrift", "Äpfel und"])
    }
}

@Suite struct QuoteFindLimitTests {
    /// Many matches with a long context must not take quadratic time each.
    @Test func longContextManyMatches() {
        let doc = String(repeating: "word ", count: 5_000)
        let context = String(repeating: "x", count: 100_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(QuoteFinder.find("word", in: doc, prefix: context, suffix: context) != nil)
        }
        #expect(elapsed < .seconds(isReleaseBuild ? 2 : 60))
    }
}

#if DEBUG
let isReleaseBuild = false
#else
let isReleaseBuild = true
#endif
