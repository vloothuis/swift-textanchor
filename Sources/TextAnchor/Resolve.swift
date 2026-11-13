/// Options for resolving an anchor.
public struct ResolveOptions: Sendable {
    /// The lowest score that still counts as found. Below it, the anchor is
    /// orphaned.
    public var minConfidence: Double
    /// Whether a match in the same section and paragraph position scores
    /// higher.
    public var preferStructuralMatch: Bool

    public init(minConfidence: Double = 0.5, preferStructuralMatch: Bool = true) {
        self.minConfidence = minConfidence
        self.preferStructuralMatch = preferStructuralMatch
    }
}

/// Why an anchor could not be resolved.
public enum OrphanReason: String, Sendable {
    /// No candidate for the quote was found.
    case quoteNotFound = "quote not found in document"
    /// The best candidate scored below the minimum confidence.
    case confidenceTooLow = "confidence too low"
}

/// The result of resolving an anchor in a document.
///
/// Matching ignores differences in whitespace, so the span can differ in
/// length from the anchor's quote: a quote that the document has since
/// rewrapped resolves to a span that holds the newline.
public struct Resolution: Sendable {
    /// The span in UTF-8 byte offsets, or nil when the anchor is orphaned.
    public var utf8Range: Range<Int>?
    /// The span in the document, or nil when the anchor is orphaned. Its
    /// bounds are on Unicode scalar boundaries, which need not be character
    /// boundaries.
    public var range: Range<String.Index>?
    /// The span in UTF-16 offsets, or nil when the anchor is orphaned.
    public var utf16Range: Range<Int>?
    /// How sure the match is, from 0 to 1. For an orphan, the best score that
    /// was reached.
    public var confidence: Double
    /// Why the anchor could not be resolved, or nil when it was.
    public var orphanReason: OrphanReason?

    /// Whether the anchor could not be resolved.
    public var isOrphaned: Bool { orphanReason != nil }
}

/// A candidate span during resolution.
struct Candidate {
    var range: ByteRange
    var score: Double
}

/// A document prepared for resolving anchors in it.
///
/// Resolving needs the whitespace-collapsed form, the paragraphs and the
/// heading positions. Building them is linear in the document and does not
/// depend on the anchor, so prepare a document once to resolve many anchors.
/// An `AnchorDocument` is immutable and safe to share between threads.
public final class AnchorDocument: Sendable {
    /// The document's text.
    public let text: String
    let bytes: [UInt8]
    let collapsed: Collapsed
    let chunks: [Chunk]
    let headings: [HeadingPosition]
    let paragraphStarts: [Int]

    public init(_ text: String) {
        self.text = text
        let bytes = Array(text.utf8)
        self.bytes = bytes
        self.collapsed = collapseWhitespace(bytes)
        self.chunks = splitParagraphsWithOffsets(bytes).compactMap { Chunk(bytes, $0) }
        self.headings = extractHeadingPositions(bytes)
        self.paragraphStarts = extractParagraphBoundaries(bytes)
    }

    /// Finds `anchor` in the document.
    ///
    /// The steps:
    /// 1. Find every exact match of the quote, ignoring differences in
    ///    whitespace.
    /// 2. Without one, find close matches: within one paragraph, or for a
    ///    quote that spans paragraphs, across them.
    /// 3. Score each candidate on the text before and after it, the section
    ///    and paragraph position, and how often the quote occurs.
    /// 4. Return the best candidate when it reaches `minConfidence`; otherwise
    ///    the anchor is orphaned.
    public func resolve(_ anchor: Anchor, options: ResolveOptions = ResolveOptions()) -> Resolution {
        var candidates = findCandidates(anchor)
        if candidates.isEmpty {
            return Resolution(confidence: 0, orphanReason: .quoteNotFound)
        }
        let quote = collapseWhitespace(anchor.quote).text
        let occurrences = countOccurrences(of: quote, in: collapsed.text)
        for i in candidates.indices {
            candidates[i].score = score(anchor, candidates[i], options, occurrences: occurrences)
        }
        var best = candidates[0]
        for c in candidates.dropFirst() where c.score > best.score {
            best = c
        }
        if best.score < options.minConfidence {
            return Resolution(confidence: best.score, orphanReason: .confidenceTooLow)
        }
        let utf8 = best.range.start..<best.range.end
        return Resolution(
            utf8Range: utf8,
            range: TextOffsets.range(utf8: utf8, in: text),
            utf16Range: TextOffsets.utf16Range(utf8: utf8, in: text),
            confidence: best.score,
            orphanReason: nil
        )
    }

    /// Resolves each anchor in turn.
    public func resolve(_ anchors: [Anchor], options: ResolveOptions = ResolveOptions()) -> [Resolution] {
        anchors.map { resolve($0, options: options) }
    }

    /// Every candidate span for the anchor's quote.
    func findCandidates(_ anchor: Anchor) -> [Candidate] {
        // Phase 1: exact matches, ignoring whitespace, over the whole
        // collapsed document. A match may cross a blank line: a selection
        // dragged from a heading into its body is a supported case.
        let quote = collapseWhitespace(anchor.quote).text
        if quote.isEmpty { return [] }
        var candidates: [Candidate] = []
        for start in allIndices(of: quote, in: collapsed.text) {
            candidates.append(Candidate(range: collapsed.sourceRange(start, start + quote.count), score: 1))
        }
        if !candidates.isEmpty { return candidates }

        // Phase 3: a quote that spans paragraphs is matched end by end, and
        // only that way. Phase 2 never crosses a blank line, so the best it
        // could offer is one paragraph that resembles part of the quote.
        if quoteChunks(anchor.quote).count >= 2 {
            var aligner = Aligner()
            return findCrossBlock(Array(anchor.quote.utf8), aligner: &aligner)
        }

        // Phase 2: close matches within one paragraph of the raw document,
        // each paragraph collapsed on its own.
        return findFuzzyMatches(in: chunks, document: bytes, query: FuzzyQuery(quote)).map {
            Candidate(range: ByteRange(start: $0.start, end: $0.end), score: $0.similarity * Fuzzy.penalty)
        }
    }

    /// The final score of a candidate: 40% quote, 20% prefix, 20% suffix,
    /// 10% structure and 10% uniqueness.
    func score(_ anchor: Anchor, _ c: Candidate, _ options: ResolveOptions, occurrences: Int) -> Double {
        let base = c.score

        // Both sides are collapsed: the context is rewrapped as the quote is.
        let prefixBytes = Array(anchor.prefix.utf8)
        var prefixScore = 1.0
        if !prefixBytes.isEmpty {
            let prefixStart = max(c.range.start - prefixBytes.count, 0)
            let actual = collapseWhitespace(Array(bytes[prefixStart..<c.range.start])).text
            prefixScore = similarity(actual, collapseWhitespace(prefixBytes).text)
        }

        let suffixBytes = Array(anchor.suffix.utf8)
        var suffixScore = 1.0
        if !suffixBytes.isEmpty {
            let suffixEnd = min(c.range.end + suffixBytes.count, bytes.count)
            let actual = collapseWhitespace(Array(bytes[c.range.end..<suffixEnd])).text
            suffixScore = similarity(actual, collapseWhitespace(suffixBytes).text)
        }

        let structural: Double
        if options.preferStructuralMatch && !anchor.headingContext.isEmpty {
            structural = structuralSimilarity(c.range, anchor)
        } else {
            structural = 0.5
        }

        // Counted over the collapsed forms, as the candidates were found.
        let uniqueness: Double
        if occurrences == 1 {
            uniqueness = 1
        } else if occurrences > 0 {
            uniqueness = 1 / Double(occurrences)
        } else {
            uniqueness = 0
        }

        return 0.40 * base + 0.20 * prefixScore + 0.20 * suffixScore + 0.10 * structural + 0.10 * uniqueness
    }

    /// How well a candidate's section and paragraph position match the
    /// anchor's: 70% heading, 30% paragraph.
    func structuralSimilarity(_ range: ByteRange, _ anchor: Anchor) -> Double {
        var currentHeading = ""
        var sectionStart = 0
        for h in headings.reversed() where h.start < range.start {
            currentHeading = h.text
            sectionStart = h.end + 1
            break
        }

        var headingMatch = 0.0
        if anchor.headingContext == currentHeading {
            headingMatch = 1
        } else if !anchor.headingContext.isEmpty && !currentHeading.isEmpty {
            headingMatch = similarity(anchor.headingContext, currentHeading)
        }

        var paragraphMatch = 0.5
        if anchor.paragraphIndex >= 0 {
            var index = 0
            for boundary in paragraphStarts where boundary >= sectionStart && boundary < range.start {
                index += 1
            }
            if index > 0 { index -= 1 }
            let diff = abs(index - anchor.paragraphIndex)
            paragraphMatch = diff == 0 ? 1 : diff <= 2 ? 0.5 : 0.1
        }
        return 0.7 * headingMatch + 0.3 * paragraphMatch
    }
}

extension Anchor {
    /// Finds this anchor in `document`. To resolve many anchors in one
    /// document, prepare it once with `AnchorDocument`.
    public func resolve(in document: String, options: ResolveOptions = ResolveOptions()) -> Resolution {
        AnchorDocument(document).resolve(self, options: options)
    }
}

/// One blank-line-delimited paragraph, prepared for both fuzzy phases.
struct Chunk: Sendable {
    var paragraph: Paragraph
    /// The paragraph collapsed on its own, so offsets map back into it.
    var c: Collapsed
    /// The runes of `c.text`.
    var runes: [UInt32]
    /// The byte offset in `c.text` of each rune, plus the length of `c.text`.
    var runeByte: [Int]
    /// The rune index of each byte offset of `c.text` that starts a rune, and
    /// of its end.
    var byteRune: [Int]

    init?(_ document: [UInt8], _ paragraph: Paragraph) {
        let c = collapseWhitespace(Array(document[paragraph.start..<paragraph.end]))
        if c.text.isEmpty { return nil }
        self.paragraph = paragraph
        self.c = c
        var runes: [UInt32] = []
        var runeByte: [Int] = []
        var byteRune = [Int](repeating: 0, count: c.text.count + 1)
        var i = 0
        while i < c.text.count {
            let (r, size) = decodeRune(c.text, at: i)
            byteRune[i] = runes.count
            runes.append(r)
            runeByte.append(i)
            i += size
        }
        runeByte.append(c.text.count)
        byteRune[c.text.count] = runes.count
        self.runes = runes
        self.runeByte = runeByte
        self.byteRune = byteRune
    }
}

/// The position and text of a heading line.
struct HeadingPosition: Sendable {
    var text: String
    var start: Int
    var end: Int
}

func extractHeadingPositions(_ doc: [UInt8]) -> [HeadingPosition] {
    splitLines(doc).compactMap { a, b in
        headingText(doc, a, b).map { HeadingPosition(text: $0, start: a, end: b) }
    }
}

/// The start offset of each paragraph.
func extractParagraphBoundaries(_ doc: [UInt8]) -> [Int] {
    var out: [Int] = []
    var inParagraph = false
    for (a, b) in splitLines(doc) {
        let blank = isBlank(doc, a, b)
        if !blank && !inParagraph {
            out.append(a)
            inParagraph = true
        } else if blank {
            inParagraph = false
        }
    }
    return out
}
