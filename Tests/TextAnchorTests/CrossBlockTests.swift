import Testing
@testable import TextAnchor

let crossDoc = """
# Guide

Some introduction that nobody comments on.

## Configuration

Configure the package by creating a config file in the project root. The file
is read once at startup, so restart after changing it.

## Deployment

Deploy with the provided script. It builds, tests and uploads the release.

"""

/// An anchor for the span from the first occurrence of `from` to the end of
/// the first occurrence of `to` after it.
func crossAnchor(_ doc: String, _ from: String, _ to: String) throws -> Anchor {
    let start = index(doc, from)
    try #require(start >= 0, "\(from) not in document")
    let end = index(doc, to, from: start)
    try #require(end >= 0, "\(to) not after \(from)")
    return try Anchor(document: doc, utf8Range: start..<(end + len(to)))
}

/// Moves the Configuration section below the Deployment section.
private func moveSection(_ s: String) -> String {
    let i = index(s, "## Configuration"), j = index(s, "## Deployment")
    return slice(s, 0, i) + slice(s, j, len(s)) + "\n" + slice(s, i, j)
}

@Suite struct CrossBlockTests {
    static func edit(_ name: String, _ s: String) -> String {
        switch name {
        case "typo in the heading": return replaceFirst(s, "## Configuration", "## Configuraton")
        case "word changed in the body": return replaceFirst(s, "by creating", "by writing")
        case "paragraph inserted between heading and body":
            return replaceFirst(s, "## Configuration\n\n", "## Configuration\n\nA short note.\n\n")
        case "section moved below another": return moveSection(s)
        case "section deleted":
            let i = index(s, "## Configuration"), j = index(s, "## Deployment")
            return slice(s, 0, i) + slice(s, j, len(s))
        case "quoted body rewritten, context intact":
            return replaceFirst(s, "Configure the package by creating a config file", "Nothing written here applies to Windows machine")
        default: return s
        }
    }

    @Test(arguments: [
        ("unchanged", "Configuration\n\nConfigure the package by creating a config file"),
        ("typo in the heading", "Configuraton\n\nConfigure the package by creating a config file"),
        ("word changed in the body", "Configuration\n\nConfigure the package by writing a config file"),
        ("paragraph inserted between heading and body",
         "Configuration\n\nA short note.\n\nConfigure the package by creating a config file"),
        ("section moved below another", "Configuration\n\nConfigure the package by creating a config file"),
    ])
    func survivesEdits(_ name: String, _ want: String) throws {
        let anchor = try crossAnchor(crossDoc, "Configuration\n", "config file")
        let doc = Self.edit(name, crossDoc)
        let res = anchor.resolve(in: doc)
        try #require(!res.isOrphaned, "\(name): orphaned at \(res.confidence)")
        #expect(resolved(doc, res) == want, "\(name)")
    }

    @Test func threeParagraphs() throws {
        let doc = "First paragraph talks about apples and pears.\n\n"
            + "Second paragraph is about the orchard and its keeper.\n\n"
            + "Third paragraph closes with the harvest festival.\n"
        let anchor = try crossAnchor(doc, "apples", "the harvest")
        let edited = replaceFirst(replaceFirst(doc, "the orchard", "the old orchard"), "closes with", "ends with")
        let res = anchor.resolve(in: edited)
        try #require(!res.isOrphaned, "orphaned at \(res.confidence)")
        let got = resolved(edited, res)
        #expect(got.hasPrefix("apples") && got.hasSuffix("the harvest"), "\(got)")
    }

    @Test func looseList() throws {
        let doc = "Steps:\n\n- Install the toolchain\n\n- Configure the build\n\n- Run the tests\n"
        let anchor = try crossAnchor(doc, "the toolchain", "Run the")
        let edited = replaceFirst(replaceFirst(doc, "Configure the build", "Configure the whole build"), "Install the", "Install all of the")
        let res = anchor.resolve(in: edited)
        try #require(!res.isOrphaned, "orphaned at \(res.confidence)")
        #expect(resolved(edited, res) == "the toolchain\n\n- Configure the whole build\n\n- Run the")
    }

    /// A match covering only the body must not win over the full span.
    @Test func beatsBodyOnlyMatch() throws {
        let body = rep("The service reads its settings from the environment. ", 6)
        let doc = "Intro text before the section.\n\n## Setup\n\n" + body + "\n\nAfter.\n"
        let trimmed = String(body.dropLast())
        let anchor = try crossAnchor(doc, "Setup", trimmed)
        let edited = replaceFirst(doc, "reads its settings", "loads its settings")
        let res = anchor.resolve(in: edited)
        try #require(!res.isOrphaned, "orphaned at \(res.confidence)")
        #expect(resolved(edited, res).hasPrefix("Setup\n\n"))
    }

    @Test(arguments: ["section deleted", "quoted body rewritten, context intact"])
    func orphans(_ name: String) throws {
        let anchor = try crossAnchor(crossDoc, "Configuration\n", "config file")
        let doc = Self.edit(name, crossDoc)
        let res = anchor.resolve(in: doc)
        #expect(res.isOrphaned, "\(name): resolved to \(resolved(doc, res)) at \(res.confidence)")
    }

    /// A long endpoint is checked again at its far edge; a small edit there
    /// must not orphan it.
    @Test func longEndpointEdited() throws {
        let long = rep("The ingest service batches writes and flushes them every second. ", 30)
        let doc = "Lead paragraph.\n\n" + long + "\n\n## Next\n\nThe end of it.\n"
        let anchor = try crossAnchor(doc, "The ingest", "Next")
        let edited = replaceFirst(doc, "The ingest service batches", "The ingest daemon batches")
        let res = anchor.resolve(in: edited)
        try #require(!res.isOrphaned, "orphaned at \(res.confidence)")
        let got = resolved(edited, res)
        #expect(got.hasPrefix("The ingest daemon") && got.hasSuffix("Next"))
    }

    /// Edits that keep the endpoints while the text the comment was about is
    /// gone must orphan.
    @Test(arguments: ["short middle rewritten", "middle deleted", "short heading renamed", "most of a long endpoint rewritten"])
    func neverMisplaces(_ name: String) throws {
        let intro = "The maintenance window opens at six and the operator on call owns it."
        let outro = "Afterwards the operator files a short report in the shared drive."
        let middleDoc = intro + "\n\nDo not reboot.\n\n" + outro + "\n"
        let long = rep("The ingest service batches writes and flushes them every second. ", 30)
        let longDoc = "Lead paragraph.\n\n" + long + "\n\n## Next\n\nThe end of it.\n"
        let keep = len(long) - 530

        let doc: String, from: String, to: String, edit: (String) -> String
        switch name {
        case "short middle rewritten":
            (doc, from, to) = (middleDoc, "The maintenance", "Afterwards the operator")
            edit = { replaceFirst($0, "Do not reboot.", "Always reboot first.") }
        case "middle deleted":
            (doc, from, to) = (middleDoc, "The maintenance", "Afterwards the operator")
            edit = { replaceFirst($0, "Do not reboot.\n\n", "") }
        case "short heading renamed":
            (doc, from, to) = ("# Plan\n\nWe still have open tasks\n\n## Risks\n\nThe vendor may slip the delivery by a month.\n",
                               "Risks", "slip the delivery")
            edit = { replaceFirst($0, "## Risks", "## Hazards") }
        default:
            (doc, from, to) = (longDoc, "The ingest", "Next")
            edit = { replaceFirst($0, slice(long, 0, keep), rep("Unrelated prose about the cafeteria menu. ", 40)) }
        }

        let anchor = try crossAnchor(doc, from, to)
        let before = anchor.resolve(in: doc)
        try #require(!before.isOrphaned, "fixture does not resolve before the edit (\(before.confidence))")
        let edited = edit(doc)
        let res = anchor.resolve(in: edited)
        #expect(res.isOrphaned, "\(name): resolved to \(resolved(edited, res)) at \(res.confidence)")
    }

    /// Two identical sections: the stored prefix decides.
    @Test func repeatedSections() throws {
        let section = "## Notes\n\nCheck the logs before you restart anything.\n\n"
        let doc = "Alpha section intro.\n\n" + section + "Beta section intro.\n\n" + section
        let second = lastIndex(doc, "Notes")
        let end = lastIndex(doc, "the logs") + len("the logs")
        let anchor = try Anchor(document: doc, utf8Range: second..<end)
        let edited = doc.replacingAll("Check the logs", "Check all the logs")
        let res = anchor.resolve(in: edited)
        try #require(!res.isOrphaned, "orphaned at \(res.confidence)")
        #expect(res.utf8Range!.lowerBound >= index(edited, "Beta"), "resolved to the first section")
    }

    @Test func singleChunkQuote() {
        var al = Aligner()
        #expect(AnchorDocument(crossDoc).findCrossBlock(Array("Configuration Configure the package".utf8), aligner: &al).isEmpty)
    }

    @Test func tooManyChunks() {
        let quote = rep("para\n\n", CrossBlock.maxChunks + 1)
        var al = Aligner()
        #expect(AnchorDocument(quote).findCrossBlock(Array(quote.utf8), aligner: &al).isEmpty)
    }

    @Test(arguments: [
        ("Configure", "Configure the package", 9, 1.0),
        ("Configure the", "Configur the package", 12, 0.9),
        ("abc", "", 0, 0.0),
        ("", "abc", 0, 0.0),
    ])
    func alignerAtStart(_ q: String, _ text: String, _ wantN: Int, _ minSim: Double) {
        var al = Aligner()
        let (n, sim) = al.atStart(runes(Array(q.utf8))[...], runes(Array(text.utf8))[...])
        #expect(n == wantN && sim >= minSim, "atStart(\(q), \(text)) = \(n), \(sim)")
    }

    /// Phase 3 screens every paragraph, so its work must stay linear in the
    /// paragraph count and independent of the quote length.
    @Test(arguments: ["short endpoints", "long endpoints"])
    func isBounded(_ name: String) {
        var b = ""
        while len(b) < 100_000 {
            b += "## Section heading\n\nA paragraph of filler text about nothing in particular, "
            b += "long enough to look like real prose in a real document.\n\n"
        }
        let d = AnchorDocument(b)
        let long = rep("a long endpoint sentence that keeps going ", 50)
        let quote = name == "short endpoints"
            ? "Configuration\n\nConfigure the package by creating a config file"
            : long + "\n\nmiddle\n\n" + long
        var al = Aligner()
        _ = d.findCrossBlock(Array(quote.utf8), aligner: &al)

        let screening = d.chunks.count * 2 * CrossBlock.probeRunes * alignWindow(CrossBlock.probeRunes)
        let evaluation = CrossBlock.shortlist * 4 * CrossBlock.endpointRunes * alignWindow(CrossBlock.endpointRunes)
        #expect(al.cells <= screening + evaluation, "\(al.cells) cells over \(d.chunks.count) paragraphs")
    }
}
