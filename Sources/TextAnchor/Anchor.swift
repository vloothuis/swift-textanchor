/// A durable reference to a span of text in a Markdown document.
///
/// An anchor describes the span by its content and surroundings rather than by
/// an offset, so it can be found again after the document was edited. It holds
/// the quoted text, about 50 bytes of text on each side, the sentence around a
/// short quote, the nearest heading before it, and its paragraph's position in
/// that heading's section.
///
/// The JSON form uses the same keys as the Go library's `Anchor`, so an anchor
/// made by either library can be resolved by the other.
public struct Anchor: Hashable, Sendable {
    /// The exact text that was selected.
    public var quote: String
    /// About 50 bytes of text immediately before the quote.
    public var prefix: String
    /// About 50 bytes of text immediately after the quote.
    public var suffix: String
    /// The sentence that holds the quote, for quotes shorter than 50 bytes.
    public var containingSentence: String
    /// The text of the nearest heading before the quote.
    public var headingContext: String
    /// The 0-based index of the quote's paragraph in its heading's section, or
    /// -1 when the anchor has no structural context.
    public var paragraphIndex: Int

    public init(
        quote: String,
        prefix: String = "",
        suffix: String = "",
        containingSentence: String = "",
        headingContext: String = "",
        paragraphIndex: Int = -1
    ) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.containingSentence = containingSentence
        self.headingContext = headingContext
        self.paragraphIndex = paragraphIndex
    }
}

extension Anchor: Codable {
    enum CodingKeys: String, CodingKey {
        case quote
        case prefix
        case suffix
        case containingSentence = "containing_sentence"
        case headingContext = "heading_context"
        case paragraphIndex = "paragraph_index"
    }

    // The Go struct marks the last three fields `omitempty`: an empty string
    // and a paragraph index of 0 are left out, and a missing key reads as the
    // zero value.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        containingSentence = try c.decodeIfPresent(String.self, forKey: .containingSentence) ?? ""
        headingContext = try c.decodeIfPresent(String.self, forKey: .headingContext) ?? ""
        paragraphIndex = try c.decodeIfPresent(Int.self, forKey: .paragraphIndex) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(quote, forKey: .quote)
        try c.encode(prefix, forKey: .prefix)
        try c.encode(suffix, forKey: .suffix)
        if !containingSentence.isEmpty { try c.encode(containingSentence, forKey: .containingSentence) }
        if !headingContext.isEmpty { try c.encode(headingContext, forKey: .headingContext) }
        if paragraphIndex != 0 { try c.encode(paragraphIndex, forKey: .paragraphIndex) }
    }
}

/// Why an anchor could not be made.
public enum AnchorError: Error, Equatable, Sendable {
    /// The start of the range is not before its end.
    case invalidRange
    /// The range reaches outside the document.
    case outOfBounds
    /// The range splits a Unicode scalar.
    case notOnScalarBoundary
    /// The quote is empty or only whitespace.
    case emptyQuote
}

/// Options for making an anchor.
public struct CreateOptions: Sendable {
    /// The number of bytes of text to keep before the quote.
    public var prefixLength: Int
    /// The number of bytes of text to keep after the quote.
    public var suffixLength: Int
    /// Whether to keep the sentence around a quote shorter than 50 bytes.
    public var includeContainingSentence: Bool
    /// Whether to keep the heading and the paragraph position.
    public var includeStructuralContext: Bool

    public init(
        prefixLength: Int = 50,
        suffixLength: Int = 50,
        includeContainingSentence: Bool = true,
        includeStructuralContext: Bool = true
    ) {
        self.prefixLength = prefixLength
        self.suffixLength = suffixLength
        self.includeContainingSentence = includeContainingSentence
        self.includeStructuralContext = includeStructuralContext
    }
}

extension Anchor {
    /// Makes an anchor for `range` in `document`.
    public init(document: String, range: Range<String.Index>, options: CreateOptions = CreateOptions()) throws {
        let utf8 = document.utf8
        guard range.lowerBound >= document.startIndex, range.upperBound <= document.endIndex else {
            throw AnchorError.outOfBounds
        }
        let start = utf8.distance(from: utf8.startIndex, to: range.lowerBound)
        let end = utf8.distance(from: utf8.startIndex, to: range.upperBound)
        try self.init(document: document, utf8Range: start..<end, options: options)
    }

    /// Makes an anchor for a range of UTF-16 offsets in `document`, the unit
    /// of `NSString`, `NSRange` and JavaScript strings.
    public init(document: String, utf16Range: Range<Int>, options: CreateOptions = CreateOptions()) throws {
        guard let range = TextOffsets.range(utf16: utf16Range, in: document) else {
            throw utf16Range.lowerBound < 0 || utf16Range.upperBound > document.utf16.count
                ? AnchorError.outOfBounds : AnchorError.notOnScalarBoundary
        }
        try self.init(document: document, range: range, options: options)
    }

    /// Makes an anchor for a range of UTF-8 byte offsets in `document`, the
    /// unit of the Go library.
    public init(document: String, utf8Range: Range<Int>, options: CreateOptions = CreateOptions()) throws {
        try self.init(bytes: Array(document.utf8), start: utf8Range.lowerBound, end: utf8Range.upperBound, options: options)
    }

    /// Makes an anchor from byte offsets. `start >= end` is rejected even
    /// though `Range` cannot express it, to match the Go library.
    init(bytes doc: [UInt8], start: Int, end: Int, options: CreateOptions = CreateOptions()) throws {
        if start >= end { throw AnchorError.invalidRange }
        if start < 0 || end > doc.count { throw AnchorError.outOfBounds }
        if (start < doc.count && isContinuationByte(doc[start])) || (end < doc.count && isContinuationByte(doc[end])) {
            throw AnchorError.notOnScalarBoundary
        }
        let quote = doc[start..<end]
        let (qa, qb) = trimSpace(doc, start, end)
        if qa >= qb { throw AnchorError.emptyQuote }

        self.init(quote: string(quote))

        // The context is cut on rune boundaries: the Go library cuts at the
        // byte, which can split a rune.
        var prefixStart = max(start - options.prefixLength, 0)
        while prefixStart < start && isContinuationByte(doc[prefixStart]) { prefixStart += 1 }
        prefix = string(doc[prefixStart..<start])

        var suffixEnd = min(end + options.suffixLength, doc.count)
        while suffixEnd > end && suffixEnd < doc.count && isContinuationByte(doc[suffixEnd]) { suffixEnd -= 1 }
        suffix = string(doc[end..<suffixEnd])

        if options.includeContainingSentence && quote.count < 50 {
            containingSentence = extractContainingSentence(doc, start, end)
        }
        if options.includeStructuralContext {
            headingContext = extractHeadingContext(doc, start)
            paragraphIndex = extractParagraphIndex(doc, start, headingContext)
        }
    }
}

/// The text of the nearest ATX heading before `offset`.
func extractHeadingContext(_ doc: [UInt8], _ offset: Int) -> String {
    for (a, b) in splitLines(doc, 0, offset).reversed() {
        if let heading = headingText(doc, a, b) { return heading }
    }
    return ""
}

func extractHeadingContext(_ doc: String, _ offset: Int) -> String {
    extractHeadingContext(Array(doc.utf8), offset)
}

/// The heading text of the line `doc[a..<b]` when it starts with "#".
func headingText(_ doc: [UInt8], _ a: Int, _ b: Int) -> String? {
    let (ta, tb) = trimSpace(doc, a, b)
    guard ta < tb, doc[ta] == 0x23 else { return nil }
    var h = ta
    while h < tb && doc[h] == 0x23 { h += 1 }
    let (ha, hb) = trimSpace(doc, h, tb)
    return string(doc[ha..<hb])
}

/// The 0-based index of the paragraph at `offset` within its section.
func extractParagraphIndex(_ doc: [UInt8], _ offset: Int, _ headingContext: String) -> Int {
    var sectionStart = 0
    if !headingContext.isEmpty {
        let lines = splitLines(doc, 0, offset)
        var lineOffset = 0
        for (i, (a, b)) in lines.enumerated() {
            if let heading = headingText(doc, a, b), heading == headingContext {
                sectionStart = lineOffset + (b - a) + 1
                if sectionStart > offset { sectionStart = 0 }
            }
            lineOffset += (b - a) + 1
            if i < lines.count - 1 && lineOffset > offset { break }
        }
    }
    let count = splitParagraphs(doc, sectionStart, offset)
    return count == 0 ? 0 : count - 1
}

/// The number of blank-line separated paragraphs in `doc[start..<end]`.
func splitParagraphs(_ doc: [UInt8], _ start: Int, _ end: Int) -> Int {
    var count = 0
    var inParagraph = false
    for (a, b) in splitLines(doc, start, end) {
        if isBlank(doc, a, b) {
            if inParagraph { count += 1; inParagraph = false }
        } else if b > a || inParagraph {
            inParagraph = true
        }
    }
    return inParagraph ? count + 1 : count
}

/// The sentence around `doc[start..<end]`.
func extractContainingSentence(_ doc: [UInt8], _ start: Int, _ end: Int) -> String {
    var sentenceStart = 0
    var i = start - 1
    while i >= 0 {
        if isSentenceEnd(doc, i) {
            sentenceStart = i + 1
            while sentenceStart < start && isLatin1Space(doc[sentenceStart]) { sentenceStart += 1 }
            break
        }
        i -= 1
    }
    var sentenceEnd = doc.count
    i = end
    while i < doc.count {
        if isSentenceEnd(doc, i) { sentenceEnd = i + 1; break }
        i += 1
    }
    if sentenceStart > sentenceEnd { return "" }
    let (a, b) = trimSpace(doc, sentenceStart, sentenceEnd)
    return string(doc[a..<b])
}

/// Go's `unicode.IsSpace(rune(b))` on a single byte.
@inline(__always)
func isLatin1Space(_ b: UInt8) -> Bool {
    isSpaceRune(UInt32(b))
}

func isSentenceEnd(_ doc: [UInt8], _ pos: Int) -> Bool {
    guard pos >= 0 && pos < doc.count else { return false }
    let c = doc[pos]
    guard c == 0x2E || c == 0x3F || c == 0x21 else { return false }
    if pos + 1 >= doc.count { return true }
    let next = doc[pos + 1]
    return next == 0x20 || next == 0x0A || next == 0x09
}
