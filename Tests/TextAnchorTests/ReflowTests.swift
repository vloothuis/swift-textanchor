import Testing
@testable import TextAnchor

/// One paragraph, stored twice: as an author types it, and after a formatter
/// hard-wrapped it at 80 columns. An anchor made in one must resolve in the
/// other.
let reflowRaw = "Renaming an entity leaves the old id in the search index until a restart, "
    + "which is confusing because the store itself is already correct at that point.\n"

let reflowWrapped = "Renaming an entity leaves the old id in the search index until a restart, which\n"
    + "is confusing because the store itself is already correct at that point.\n"

@Suite struct ReflowTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var source: String
        var target: String
        var quote: String
        var wantOrphaned = false
        var wantConfidence = 0.0
        var wantSpan = ""
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "quote spanning a line break", source: reflowRaw, target: reflowWrapped,
             quote: "until a restart, which is confusing", wantConfidence: 0.9,
             wantSpan: "until a restart, which\nis confusing"),
        Case(name: "quote within a single line is unaffected", source: reflowRaw, target: reflowWrapped,
             quote: "the old id in the search index", wantConfidence: 0.9,
             wantSpan: "the old id in the search index"),
        Case(name: "quote ending exactly at the wrap point", source: reflowRaw, target: reflowWrapped,
             quote: "until a restart, which", wantConfidence: 0.9, wantSpan: "until a restart, which"),
        Case(name: "quote starting immediately after the wrap point", source: reflowRaw, target: reflowWrapped,
             quote: "is confusing because the store", wantConfidence: 0.9,
             wantSpan: "is confusing because the store"),
        Case(name: "unwrapping resolves as well as wrapping", source: reflowWrapped, target: reflowRaw,
             quote: "until a restart, which\nis confusing", wantConfidence: 0.9,
             wantSpan: "until a restart, which is confusing"),
        Case(name: "deleted text still orphans", source: reflowRaw,
             target: "Renaming an entity is handled by the store.\nNothing here resembles the sentence that was removed.\n",
             quote: "until a restart, which is confusing", wantOrphaned: true),
    ]

    @Test(arguments: cases)
    func resolveAcrossReflow(_ tc: Case) throws {
        let start = index(tc.source, tc.quote)
        try #require(start >= 0)
        let anchor = try Anchor(document: tc.source, utf8Range: start..<(start + len(tc.quote)))
        let res = anchor.resolve(in: tc.target)
        if tc.wantOrphaned {
            #expect(res.isOrphaned, "resolved at \(res.confidence) to \(resolved(tc.target, res))")
            return
        }
        try #require(!res.isOrphaned, "orphaned at \(res.confidence)")
        #expect(res.confidence >= tc.wantConfidence)
        #expect(resolved(tc.target, res) == tc.wantSpan)
    }

    static let multiByteCases: [Case] = [
        Case(name: "accented text spanning a line break",
             source: "Le café est déjà préparé par la première équipe, mais la deuxième équipe préfère le thé.\n",
             target: "Le café est déjà préparé par la première équipe, mais la\ndeuxième équipe préfère le thé.\n",
             quote: "première équipe, mais la deuxième", wantSpan: "première équipe, mais la\ndeuxième"),
        Case(name: "CJK text spanning a line break",
             source: "この文書は日本語で書かれています。改行が入っても解決できるはずです。それが期待される動作です。\n",
             target: "この文書は日本語で書かれています。改行が入っても\n解決できるはずです。それが期待される動作です。\n",
             quote: "改行が入っても解決できる", wantSpan: "改行が入っても\n解決できる"),
        Case(name: "emoji adjacent to the wrap point",
             source: "The deploy finished 🎉 and the dashboard turned green again after the long incident review.\n",
             target: "The deploy finished 🎉 and the dashboard turned green\nagain after the long incident review.\n",
             quote: "🎉 and the dashboard turned green again", wantSpan: "🎉 and the dashboard turned green\nagain"),
    ]

    @Test(arguments: multiByteCases)
    func resolveAcrossReflowMultiByte(_ tc: Case) throws {
        let start = index(tc.source, tc.quote)
        try #require(start >= 0)
        let anchor = try Anchor(document: tc.source, utf8Range: start..<(start + len(tc.quote)))
        let res = anchor.resolve(in: tc.target)
        try #require(!res.isOrphaned, "orphaned at \(res.confidence)")
        #expect(resolved(tc.target, res) == tc.wantSpan)
        // Every offset form must be present: they exist only on scalar boundaries.
        #expect(res.range != nil)
        #expect(res.utf16Range != nil)
        if let r = res.range { #expect(String(tc.target.unicodeScalars[r]) == tc.wantSpan) }
    }

    @Test func findFuzzyMatchesReachesSubstringMatch() throws {
        let matches = findFuzzyMatchesByParagraph(reflowWrapped, "until a restart, which is confusing")
        try #require(!matches.isEmpty)
        let best = matches.max { $0.similarity < $1.similarity }!
        #expect(best.similarity >= 0.9)
        #expect(slice(reflowWrapped, best.start, best.end) == "until a restart, which\nis confusing")
    }

    @Test func findFuzzyMatchesRejectsAbsentText() {
        let doc = "The store writes markdown files to disk and reloads them on change.\n"
        #expect(findFuzzyMatchesByParagraph(doc, "completely unrelated wording about billing invoices").isEmpty)
    }

    /// Confidence must not depend on how much unrelated text surrounds the
    /// quote: the comparison budget is per paragraph.
    @Test(arguments: [1, 50, 400, 2000])
    func resolveScalesWithDocumentSize(_ paragraphs: Int) {
        let quote = "the audit log records every successful write to the tree today"
        let target = "the audit log records every successful write to the graph today"
        var doc = ""
        for i in 0..<paragraphs {
            doc += "Paragraph \(i): the store writes markdown files to disk and reloads them on change when the watcher fires.\n\n"
        }
        doc += target + "\n"
        let res = Anchor(quote: quote).resolve(in: doc)
        #expect(!res.isOrphaned, "orphaned in a \(len(doc))-byte document")
        #expect(resolved(doc, res) == target)
    }

    /// The exact phase matches across a blank line on purpose.
    @Test func resolveSpansBlockBoundary() {
        let doc = "# Configuration\n\nConfigure the package by creating a config file.\n"
        let res = Anchor(quote: "Configuration Configure the package").resolve(in: doc)
        #expect(!res.isOrphaned)
        #expect(resolved(doc, res) == "Configuration\n\nConfigure the package")
    }
}
