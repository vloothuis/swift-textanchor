import Markdown

/// Markdown source as bytes, with the line starts that turn swift-markdown's
/// line and column positions into byte offsets.
struct Source {
    let bytes: [UInt8]
    /// The byte offset of the start of each line. Lines end at "\n", "\r\n"
    /// or "\r", as in CommonMark.
    let lineStarts: [Int]

    init(_ text: String) {
        bytes = Array(text.utf8)
        var starts = [0]
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                starts.append(i + 1)
            } else if bytes[i] == 0x0D {
                if i + 1 < bytes.count && bytes[i + 1] == 0x0A { i += 1 }
                starts.append(i + 1)
            }
            i += 1
        }
        lineStarts = starts
    }

    /// The byte offset of a 1-based line and byte column.
    func offset(_ location: SourceLocation) -> Int {
        let line = min(max(location.line - 1, 0), lineStarts.count - 1)
        return min(max(lineStarts[line] + location.column - 1, 0), bytes.count)
    }

    /// The byte range of a node, or nil when the parser gave it none.
    func range(_ node: Markup) -> Range<Int>? {
        guard let r = node.range else { return nil }
        let a = offset(r.lowerBound), b = offset(r.upperBound)
        return a <= b ? a..<b : nil
    }

    /// The bounds of 0-based line `n`, without its line ending.
    func line(_ n: Int) -> Range<Int> {
        let start = lineStarts[n]
        var end = n + 1 < lineStarts.count ? lineStarts[n + 1] : bytes.count
        if end > start && bytes[end - 1] == 0x0A { end -= 1 }
        if end > start && bytes[end - 1] == 0x0D { end -= 1 }
        return start..<end
    }
}

/// Parses Markdown with the GitHub extensions: tables, strikethrough and task
/// lists.
func parse(_ text: String) -> Document {
    Document(parsing: text, options: [])
}

/// The first and last child that has a source range, as one range.
func childrenRange(_ node: Markup, _ src: Source) -> Range<Int>? {
    var first: Range<Int>?
    var last: Range<Int>?
    for child in node.children {
        guard let r = src.range(child) else { continue }
        if first == nil { first = r }
        last = r
    }
    guard let a = first, let b = last, a.lowerBound <= b.upperBound else { return nil }
    return a.lowerBound..<b.upperBound
}

/// Whether a link is an autolink in angle brackets, such as `<https://x>`.
func isAngleAutolink(_ node: Markup, _ src: Source) -> Bool {
    guard node is Link, let r = src.range(node), r.lowerBound < src.bytes.count else { return false }
    return src.bytes[r.lowerBound] == UInt8(ascii: "<")
}

/// The content of an inline code span: the source between its backtick runs,
/// with one space stripped from each side when both sides have one and the
/// content is not only spaces.
func codeSpanContent(_ r: Range<Int>, _ src: Source) -> Range<Int> {
    let b = src.bytes
    var s = r.lowerBound, e = r.upperBound
    while s < e && b[s] == UInt8(ascii: "`") { s += 1 }
    while e > s && b[e - 1] == UInt8(ascii: "`") { e -= 1 }
    if e - s >= 2 && isLineSpace(b[s]) && isLineSpace(b[e - 1])
        && !b[s..<e].allSatisfy({ $0 == 0x20 }) {
        s += 1
        e -= 1
    }
    return s..<e
}

@inline(__always)
func isLineSpace(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x0A || b == 0x0D
}
