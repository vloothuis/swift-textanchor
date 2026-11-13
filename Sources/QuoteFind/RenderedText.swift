import Markdown

/// The text of rendered Markdown, as a reader sees it in a browser, with a map
/// from each of its bytes back to the source.
///
/// It follows the Go library's rules: text keeps its source bytes, so escapes
/// and entities stay as written; a soft line break becomes a space; a hard
/// line break adds nothing; code keeps its content; HTML and autolinks in
/// angle brackets are left out; and each paragraph, heading, list item, code
/// block, block quote and table cell ends with a space.
public struct RenderedText: Sendable {
    /// The rendered text.
    public let text: String
    /// For each UTF-8 byte of `text`, the UTF-8 offset in the source it came
    /// from, plus one final entry for the end.
    public let sourceOffsets: [Int]

    /// Renders `markdown`.
    public init(markdown: String) {
        var builder = Builder(Source(markdown))
        builder.walk(parse(markdown))
        let map = builder.map
        text = String(decoding: builder.out, as: UTF8.self)
        sourceOffsets = map + [map.last.map { $0 + 1 } ?? 0]
        bytes = builder.out
    }

    /// The bytes of `text`.
    let bytes: [UInt8]
}

private struct Builder {
    let src: Source
    var out: [UInt8] = []
    var map: [Int] = []

    init(_ src: Source) { self.src = src }

    mutating func emit(_ r: Range<Int>) {
        for i in r {
            out.append(src.bytes[i])
            map.append(i)
        }
    }

    /// Adds the space that separates blocks, unless the text already ends in
    /// a space or a newline.
    mutating func endBlock() {
        guard let last = out.last, last != 0x20, last != 0x0A else { return }
        out.append(0x20)
        map.append(map.last ?? 0)
    }

    mutating func walk(_ node: Markup) {
        switch node {
        case let text as Text:
            emitText(text)
            return
        case is SoftBreak:
            // The space maps to where the line's text ends.
            out.append(0x20)
            map.append(endOfPrevious(node) ?? map.last ?? 0)
            return
        case is LineBreak, is InlineHTML, is HTMLBlock:
            return
        case let code as InlineCode:
            if let r = src.range(code) { emit(codeSpanContent(r, src)) }
            return
        case let block as CodeBlock:
            emitCodeBlock(block)
            endBlock()
            return
        case let link as Link where isAngleAutolink(link, src):
            return
        default:
            break
        }
        for child in node.children { walk(child) }
        switch node {
        case is Paragraph, is Heading, is ListItem, is BlockQuote, is Table.Cell:
            endBlock()
        default:
            break
        }
    }

    /// Emits a text node's source bytes. Before a line break the trailing
    /// blanks are left out, and before a hard break also its backslash.
    mutating func emitText(_ text: Text) {
        guard let r = src.range(text) else { return }
        emit(r.lowerBound..<trimmedEnd(text, r))
    }

    func trimmedEnd(_ text: Text, _ r: Range<Int>) -> Int {
        let next = nextSibling(text)
        guard next is SoftBreak || next is LineBreak else { return r.upperBound }
        let b = src.bytes
        var e = r.upperBound
        while e > r.lowerBound && (b[e - 1] == 0x20 || b[e - 1] == 0x09 || b[e - 1] == 0x0D) { e -= 1 }
        if next is LineBreak && e > r.lowerBound && b[e - 1] == UInt8(ascii: "\\") { e -= 1 }
        return e
    }

    /// The source end of the sibling before `node`, trimmed as its text was.
    func endOfPrevious(_ node: Markup) -> Int? {
        guard let parent = node.parent, node.indexInParent > 0 else { return nil }
        let prev = parent.child(at: node.indexInParent - 1)!
        guard let r = src.range(prev) else { return nil }
        if let text = prev as? Text { return trimmedEnd(text, r) }
        return r.upperBound
    }

    func nextSibling(_ node: Markup) -> Markup? {
        guard let parent = node.parent, node.indexInParent + 1 < parent.childCount else { return nil }
        return parent.child(at: node.indexInParent + 1)
    }

    /// Emits a code block line by line, each with its newline, leaving out
    /// the fences, the indentation and the markers of the containers.
    mutating func emitCodeBlock(_ block: CodeBlock) {
        guard let r = block.range else { return }
        var lines = block.code.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.utf8) }
        if lines.last?.isEmpty == true { lines.removeLast() }
        var first = r.lowerBound.line - 1
        let start = src.offset(r.lowerBound)
        let opening = src.bytes[start..<src.line(first).upperBound].drop { $0 == 0x20 }
        if opening.starts(with: Array("```".utf8)) || opening.starts(with: Array("~~~".utf8)) { first += 1 }

        for (k, content) in lines.enumerated() {
            let n = first + k
            guard n < src.lineStarts.count else { break }
            let line = src.line(n)
            let lineBytes = src.bytes[line]
            let from = lineBytes.count >= content.count && lineBytes.suffix(content.count).elementsEqual(content)
                ? line.upperBound - content.count : line.lowerBound
            for j in 0..<content.count {
                out.append(content[j])
                map.append(min(from + j, max(line.upperBound - 1, line.lowerBound)))
            }
            out.append(0x0A)
            map.append(line.upperBound)
        }
    }
}
