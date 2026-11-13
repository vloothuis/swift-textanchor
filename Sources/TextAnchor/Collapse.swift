/// A text with every run of whitespace reduced to one space, with a map from
/// each byte of that form back to the byte it came from in the original.
///
/// Matching runs against `text`; ranges are reported in original coordinates
/// through `sourceRange`. This lets an anchor survive a formatter that rewraps
/// the document: a line break inside a quote becomes the same single space on
/// both sides of the comparison, while the range handed back still selects the
/// original bytes, newline and all.
struct Collapsed: Sendable {
    /// The collapsed form.
    var text: [UInt8]
    /// The bytes `text` was built from.
    var original: [UInt8]
    /// One entry per byte of `text`, holding its offset in `original`, plus a
    /// final entry holding the original length.
    var posMap: [Int]
}

/// Builds the collapsed form of `s`.
///
/// Every maximal run of whitespace becomes one space mapped to the run's first
/// byte, and leading and trailing whitespace is dropped. A multi-byte rune
/// contributes one entry per byte.
func collapseWhitespace(_ s: [UInt8]) -> Collapsed {
    var text: [UInt8] = []
    text.reserveCapacity(s.count)
    var posMap: [Int] = []
    posMap.reserveCapacity(s.count + 1)

    var pendingSpace = false
    var i = 0
    while i < s.count {
        let (r, size) = decodeRune(s, at: i)
        if isSpaceRune(r) {
            if !text.isEmpty { pendingSpace = true }
            i += size
            continue
        }
        if pendingSpace {
            text.append(0x20)
            posMap.append(i)
            pendingSpace = false
        }
        for j in 0..<size {
            text.append(s[i + j])
            posMap.append(i + j)
        }
        i += size
    }
    posMap.append(s.count)
    return Collapsed(text: text, original: s, posMap: posMap)
}

@inline(__always)
func collapseWhitespace(_ s: String) -> Collapsed {
    collapseWhitespace(Array(s.utf8))
}

extension Collapsed {
    /// Converts `start..<end` over `text` into the matching range over the
    /// original, on rune boundaries. An out-of-range or empty span returns
    /// `0..<0`.
    ///
    /// The end comes from the last included byte rather than from
    /// `posMap[end]`: the byte after a match may be the space standing in for
    /// a run of whitespace, whose entry points at the start of that run.
    func sourceRange(_ start: Int, _ end: Int) -> ByteRange {
        var start = max(start, 0)
        start = min(start, text.count)
        let end = min(end, text.count)
        if start >= end || end <= 0 { return ByteRange(start: 0, end: 0) }

        var srcStart = posMap[start]
        let lastByte = posMap[end - 1]

        // Retreat to the start of the rune the offset falls in.
        while srcStart > 0 && isContinuationByte(original[srcStart]) {
            srcStart -= 1
        }
        // Advance past the final rune's continuation bytes.
        var srcEnd = lastByte + 1
        while srcEnd < original.count && isContinuationByte(original[srcEnd]) {
            srcEnd += 1
        }
        return ByteRange(start: srcStart, end: srcEnd)
    }
}

/// A half-open range of UTF-8 byte offsets.
struct ByteRange: Equatable, Sendable {
    var start: Int
    var end: Int
}
