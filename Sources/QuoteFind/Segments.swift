import Markdown
import TextAnchor

/// Markdown source parsed once, to split many ranges into highlight segments.
///
/// One inline element cannot cross a block boundary: an HTML parser closes it
/// at the first block end. To highlight a range that spans blocks, wrap each
/// segment in its own element.
public final class SegmentedDocument: Sendable {
    /// The Markdown source.
    public let source: String
    let bytes: [UInt8]
    let blocks: [TextBlock]

    public init(_ source: String) {
        self.source = source
        let src = Source(source)
        bytes = src.bytes
        var blocks: [TextBlock] = []
        collectBlocks(parse(source), src, &blocks)
        self.blocks = blocks
    }

    /// Splits `utf8Range` of the source into one range per block of text it
    /// touches.
    ///
    /// Each segment is cut to one block's inline content, so block markup
    /// such as "## ", "- " and "[ ] " stays outside it. A start inside
    /// emphasis or a link that the segment runs past moves to the opening
    /// delimiter. A code span the range touches is included whole, backticks
    /// and all; code blocks and HTML blocks give no segment. No segment edge
    /// sits next to an escaping backslash. Returns an empty array when the
    /// range covers no text.
    public func segments(utf8Range: Range<Int>) -> [Range<Int>] {
        let start = max(utf8Range.lowerBound, 0)
        let end = min(utf8Range.upperBound, bytes.count)
        if start >= end { return [] }

        var out: [Range<Int>] = []
        for b in blocks {
            if b.content.upperBound <= start { continue }
            if b.content.lowerBound >= end { break }
            var r = max(start, b.content.lowerBound)..<min(end, b.content.upperBound)
            r = b.widenToCode(r)
            r = b.liftStart(r)..<r.upperBound
            r = clean(r)
            if !r.isEmpty { out.append(r) }
        }
        return out
    }

    /// `segments(utf8Range:)` for a range of string indices.
    public func segments(_ range: Range<String.Index>) -> [Range<String.Index>] {
        guard let u = TextOffsets.utf8Range(range, in: source) else { return [] }
        return segments(utf8Range: u).compactMap { TextOffsets.range(utf8: $0, in: source) }
    }

    /// `segments(utf8Range:)` for a range of UTF-16 offsets.
    public func segments(utf16Range: Range<Int>) -> [Range<Int>] {
        guard let u = TextOffsets.utf8Range(utf16: utf16Range, in: source) else { return [] }
        return segments(utf8Range: u).compactMap { TextOffsets.utf16Range(utf8: $0, in: source) }
    }

    /// Trims a segment's whitespace and keeps its edges off a backslash that
    /// escapes the next character.
    func clean(_ r: Range<Int>) -> Range<Int> {
        var r = trimRange(bytes, r)
        if !r.isEmpty && escapes(bytes, r.upperBound - 1) {
            r = trimRange(bytes, r.lowerBound..<(r.upperBound - 1))
        }
        if !r.isEmpty && r.lowerBound > 0 && escapes(bytes, r.lowerBound - 1) {
            r = (r.lowerBound - 1)..<r.upperBound
        }
        return r
    }
}

/// A leaf block that holds inline text.
struct TextBlock: Sendable {
    /// The block's inline content.
    var content: Range<Int>
    /// Each code span, backticks included, in source order.
    var code: [Range<Int>] = []
    /// Each emphasis, link, image and strikethrough, from its opening
    /// delimiter to the end of its last text.
    var inline: [Range<Int>] = []

    /// Moves an edge of `r` that falls inside a code span to the span's edge.
    func widenToCode(_ r: Range<Int>) -> Range<Int> {
        var s = r.lowerBound, e = r.upperBound
        for c in code {
            if c.lowerBound < s && s < c.upperBound { s = c.lowerBound }
            if c.lowerBound < e && e < c.upperBound { e = c.upperBound }
        }
        return s..<e
    }

    /// Moves the start out of every inline container that `r` leaves before
    /// the container ends, to its opening delimiter.
    func liftStart(_ r: Range<Int>) -> Int {
        var start = r.lowerBound
        var moved = true
        while moved {
            moved = false
            for c in inline where c.lowerBound < start && start < c.upperBound && r.upperBound > c.upperBound {
                start = c.lowerBound
                moved = true
            }
        }
        return start
    }
}

/// Collects the paragraphs, headings and table cells of `node`, in order.
private func collectBlocks(_ node: Markup, _ src: Source, _ out: inout [TextBlock]) {
    switch node {
    case is Paragraph, is Heading, is Table.Cell:
        if let b = textBlock(node, src) { out.append(b) }
        return
    case is CodeBlock, is HTMLBlock:
        return
    default:
        for child in node.children { collectBlocks(child, src, &out) }
    }
}

private func textBlock(_ node: Markup, _ src: Source) -> TextBlock? {
    guard let children = childrenRange(node, src) else { return nil }
    let content = trimRange(src.bytes, children)
    if content.isEmpty { return nil }
    var block = TextBlock(content: content)
    collectInline(node, src, &block)
    return block
}

private func collectInline(_ node: Markup, _ src: Source, _ block: inout TextBlock) {
    for child in node.children {
        switch child {
        case let code as InlineCode:
            if let r = src.range(code) { block.code.append(r) }
            continue
        case let link as Link where isAngleAutolink(link, src):
            continue
        case is Emphasis, is Strong, is Link, is Image, is Strikethrough:
            if let r = src.range(child), let last = lastTextEnd(child, src) {
                block.inline.append(r.lowerBound..<last)
            }
        default:
            break
        }
        collectInline(child, src, &block)
    }
}

/// The source end of the last text inside `node`.
private func lastTextEnd(_ node: Markup, _ src: Source) -> Int? {
    var found: Int?
    func walk(_ n: Markup) {
        if n is Text, let r = src.range(n) { found = r.upperBound }
        if let code = n as? InlineCode, let r = src.range(code) { found = codeSpanContent(r, src).upperBound }
        for c in n.children { walk(c) }
    }
    walk(node)
    return found
}

/// Shrinks `r` past whitespace at both ends.
func trimRange(_ b: [UInt8], _ r: Range<Int>) -> Range<Int> {
    var s = r.lowerBound, e = r.upperBound
    func blank(_ x: UInt8) -> Bool { x == 0x20 || x == 0x09 || x == 0x0D || x == 0x0A }
    while s < e && blank(b[s]) { s += 1 }
    while e > s && blank(b[e - 1]) { e -= 1 }
    return s..<e
}

/// Whether `b[i]` is a backslash that escapes the next character: one with an
/// even number of backslashes before it.
func escapes(_ b: [UInt8], _ i: Int) -> Bool {
    guard b[i] == UInt8(ascii: "\\") else { return false }
    var n = 0
    var j = i - 1
    while j >= 0 && b[j] == UInt8(ascii: "\\") { n += 1; j -= 1 }
    return n % 2 == 0
}
