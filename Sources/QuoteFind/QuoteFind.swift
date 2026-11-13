import Markdown
import TextAnchor

/// Finds text that was selected in rendered Markdown, such as a browser
/// selection or a quote from a language model, in the Markdown source.
///
/// Such text has no Markdown syntax and its whitespace is collapsed, so its
/// offsets do not match the source. `QuoteFinder` matches it against the
/// rendered text and maps the match back to the source, ready for
/// `Anchor(document:utf8Range:)`.
public enum QuoteFinder {
    /// The span of `quote` in `markdown`, or nil when it is not there.
    public static func find(_ quote: String, in markdown: String) -> QuoteMatch? {
        find(quote, in: markdown, prefix: "", suffix: "")
    }

    /// The span of `quote` in `markdown`, using the text before and after the
    /// selection to choose between occurrences.
    public static func find(_ quote: String, in markdown: String, prefix: String, suffix: String) -> QuoteMatch? {
        guard let (start, end) = findBytes(markdown, Array(quote.utf8), Array(prefix.utf8), Array(suffix.utf8)) else {
            return nil
        }
        return QuoteMatch(markdown, start, end)
    }

    /// The Go library's `FindWithContext`, in byte offsets.
    static func findBytes(_ markdown: String, _ quote: [UInt8], _ prefix: [UInt8], _ suffix: [UInt8]) -> (Int, Int)? {
        let content = Array(markdown.utf8)
        // Fast path: one exact occurrence in the source.
        if !quote.isEmpty, let idx = firstIndex(of: quote, in: content) {
            if firstIndex(of: quote, in: content, from: idx + 1) == nil {
                return (idx, idx + quote.count)
            }
        }

        let rendered = RenderedText(markdown: markdown)
        let text = rendered.bytes
        let posMap = rendered.sourceOffsets
        let nq = collapseAllWhitespace(quote)
        let np = collapseAllWhitespace(prefix)
        let ns = collapseAllWhitespace(suffix)
        if nq.isEmpty { return nil }

        var matches: [(idx: Int, score: Double)] = []
        var offset = 0
        while let idx = firstIndex(of: nq, in: text, from: offset) {
            matches.append((idx, scoreMatchByContext(text, idx, nq.count, np, ns)))
            offset = idx + 1
        }

        if matches.isEmpty {
            // Try again with all whitespace collapsed.
            let aggressiveRendered = collapseAllWhitespace(text)
            guard let idx = firstIndex(of: nq, in: aggressiveRendered) else { return nil }
            let aggressiveMap = buildAggressiveMap(text, posMap)
            return (mapToSource(aggressiveMap, idx), mapEnd(aggressiveMap, idx + nq.count))
        }

        var best = matches[0]
        for m in matches.dropFirst() where m.score > best.score { best = m }
        return (mapToSource(posMap, best.idx), mapEnd(posMap, best.idx + nq.count))
    }

    /// The exclusive source end of a match that ends at `endIdx`.
    static func mapEnd(_ map: [Int], _ endIdx: Int) -> Int {
        endIdx > 0 && endIdx <= map.count ? mapToSource(map, endIdx - 1) + 1 : mapToSource(map, endIdx)
    }
}

/// A span of Markdown source that a quote was found in.
public struct QuoteMatch: Sendable, Equatable {
    /// The span in UTF-8 byte offsets.
    public let utf8Range: Range<Int>
    /// The span in UTF-16 offsets.
    public let utf16Range: Range<Int>
    /// The span in the source.
    public let range: Range<String.Index>

    init?(_ markdown: String, _ start: Int, _ end: Int) {
        guard let s = snapRange(markdown, start, end),
              let range = TextOffsets.range(utf8: s, in: markdown),
              let utf16 = TextOffsets.utf16Range(range, in: markdown) else { return nil }
        self.utf8Range = s
        self.utf16Range = utf16
        self.range = range
    }
}

/// Clamps a byte range to the text and moves it outward to whole Unicode
/// scalars.
func snapRange(_ text: String, _ start: Int, _ end: Int) -> Range<Int>? {
    let bytes = Array(text.utf8)
    var s = min(max(start, 0), bytes.count)
    var e = min(max(end, s), bytes.count)
    while s > 0 && s < bytes.count && bytes[s] & 0xC0 == 0x80 { s -= 1 }
    while e < bytes.count && bytes[e] & 0xC0 == 0x80 { e += 1 }
    return s..<e
}

/// Scores how well the text around a match fits the expected prefix and
/// suffix, from 0 to 2.
func scoreMatchByContext(_ content: [UInt8], _ start: Int, _ length: Int, _ prefix: [UInt8], _ suffix: [UInt8]) -> Double {
    var score = 0.0
    if !prefix.isEmpty {
        let ps = max(start - prefix.count, 0)
        score += contextSimilarity(Array(content[ps..<start]), prefix)
    } else {
        score += 0.5
    }
    if !suffix.isEmpty {
        let se = min(start + length + suffix.count, content.count)
        score += contextSimilarity(Array(content[(start + length)..<se]), suffix)
    } else {
        score += 0.5
    }
    return score
}

/// The longest common substring of the two contexts, over the expected
/// context's length.
func contextSimilarity(_ actual: [UInt8], _ expected: [UInt8]) -> Double {
    if expected.isEmpty { return 0.5 }
    if actual.isEmpty { return 0 }
    let a = collapseAllWhitespace(actual)
    let e = collapseAllWhitespace(expected)
    if e.isEmpty { return 0.5 }
    return Double(longestCommonSubstring(a, e)) / Double(e.count)
}

func longestCommonSubstring(_ s1: [UInt8], _ s2: [UInt8]) -> Int {
    if s1.isEmpty || s2.isEmpty { return 0 }
    var best = 0
    var prev = [Int](repeating: 0, count: s2.count + 1)
    var cur = prev
    for i in 1...s1.count {
        for j in 1...s2.count {
            if s1[i - 1] == s2[j - 1] {
                cur[j] = prev[j - 1] + 1
                best = max(best, cur[j])
            } else {
                cur[j] = 0
            }
        }
        swap(&prev, &cur)
    }
    return best
}

/// Go's `strings.Join(strings.Fields(s), " ")`: runs of whitespace become
/// one space, and both ends are trimmed.
func collapseAllWhitespace(_ s: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(s.count)
    var pending = false
    var i = 0
    while i < s.count {
        let (r, size) = decode(s, i)
        if isSpace(r) {
            if !out.isEmpty { pending = true }
        } else {
            if pending { out.append(0x20); pending = false }
            out.append(contentsOf: s[i..<(i + size)])
        }
        i += size
    }
    return out
}

/// A map for the collapsed rendered text. As in the Go library it has one
/// entry per rune rather than per byte, so it is exact only for ASCII text.
func buildAggressiveMap(_ rendered: [UInt8], _ originalMap: [Int]) -> [Int] {
    var result: [Int] = []
    var inWhitespace = false
    var i = 0
    while i < rendered.count {
        let (r, size) = decode(rendered, i)
        if isSpace(r) {
            if !inWhitespace && i < originalMap.count { result.append(originalMap[i]) }
            inWhitespace = true
        } else {
            if i < originalMap.count { result.append(originalMap[i]) }
            inWhitespace = false
        }
        i += size
    }
    if let last = originalMap.last { result.append(last) }
    return result
}

func mapToSource(_ posMap: [Int], _ pos: Int) -> Int {
    if pos < 0 { return 0 }
    if pos >= posMap.count { return posMap.last ?? 0 }
    return posMap[pos]
}

/// Go's `strings.Index` over bytes.
func firstIndex(of needle: [UInt8], in hay: [UInt8], from: Int = 0) -> Int? {
    let n = needle.count
    if n == 0 { return from <= hay.count ? from : nil }
    if from < 0 || n > hay.count - from { return nil }
    var i = from
    let last = hay.count - n
    while i <= last {
        if hay[i] == needle[0] {
            var k = 1
            while k < n && hay[i + k] == needle[k] { k += 1 }
            if k == n { return i }
        }
        i += 1
    }
    return nil
}

/// Decodes one rune as Go does: an invalid byte is U+FFFD of size 1.
func decode(_ s: [UInt8], _ i: Int) -> (UInt32, Int) {
    let b0 = s[i]
    if b0 < 0x80 { return (UInt32(b0), 1) }
    var it = s[i...].makeIterator()
    var decoder = UTF8()
    if case .scalarValue(let scalar) = decoder.decode(&it) {
        return (scalar.value, UTF8.width(scalar))
    }
    return (0xFFFD, 1)
}

/// Go's `unicode.IsSpace`.
func isSpace(_ r: UInt32) -> Bool {
    switch r {
    case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
        return true
    default:
        return false
    }
}
