// Byte-level helpers. The library works on UTF-8 bytes internally, as the Go
// library does, so that lengths, windows and thresholds measured in bytes give
// the same results. Decoding follows Go: an invalid byte decodes to U+FFFD and
// advances one byte.

let replacementRune: UInt32 = 0xFFFD

@inline(__always)
func isContinuationByte(_ b: UInt8) -> Bool {
    b & 0xC0 == 0x80
}

/// Decodes the rune that starts at `i`, as Go's `utf8.DecodeRune` does.
@inline(__always)
func decodeRune<C: RandomAccessCollection>(_ s: C, at i: C.Index) -> (rune: UInt32, size: Int)
where C.Element == UInt8, C.Index == Int {
    let end = s.endIndex
    let b0 = s[i]
    if b0 < 0x80 { return (UInt32(b0), 1) }

    func cont(_ k: Int) -> UInt32? {
        guard i + k < end else { return nil }
        let b = s[i + k]
        return isContinuationByte(b) ? UInt32(b & 0x3F) : nil
    }

    if b0 >= 0xC2 && b0 <= 0xDF {
        guard let c1 = cont(1) else { return (replacementRune, 1) }
        return ((UInt32(b0 & 0x1F) << 6) | c1, 2)
    }
    if b0 >= 0xE0 && b0 <= 0xEF {
        guard i + 1 < end else { return (replacementRune, 1) }
        let b1 = s[i + 1]
        let lo: UInt8 = b0 == 0xE0 ? 0xA0 : 0x80
        let hi: UInt8 = b0 == 0xED ? 0x9F : 0xBF
        guard b1 >= lo && b1 <= hi, let c2 = cont(2) else { return (replacementRune, 1) }
        return ((UInt32(b0 & 0x0F) << 12) | (UInt32(b1 & 0x3F) << 6) | c2, 3)
    }
    if b0 >= 0xF0 && b0 <= 0xF4 {
        guard i + 1 < end else { return (replacementRune, 1) }
        let b1 = s[i + 1]
        let lo: UInt8 = b0 == 0xF0 ? 0x90 : 0x80
        let hi: UInt8 = b0 == 0xF4 ? 0x8F : 0xBF
        guard b1 >= lo && b1 <= hi, let c2 = cont(2), let c3 = cont(3) else { return (replacementRune, 1) }
        return ((UInt32(b0 & 0x07) << 18) | (UInt32(b1 & 0x3F) << 12) | (c2 << 6) | c3, 4)
    }
    return (replacementRune, 1)
}

/// Go's `unicode.IsSpace`: the Latin-1 spaces plus the White_Space property.
@inline(__always)
func isSpaceRune(_ r: UInt32) -> Bool {
    switch r {
    case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
        return true
    default:
        return false
    }
}

/// The runes of `s`, as Go's `[]rune(s)` conversion gives them.
func runes<C: RandomAccessCollection>(_ s: C) -> [UInt32] where C.Element == UInt8, C.Index == Int {
    var out: [UInt32] = []
    out.reserveCapacity(s.count)
    var i = s.startIndex
    while i < s.endIndex {
        let (r, size) = decodeRune(s, at: i)
        out.append(r)
        i += size
    }
    return out
}

/// The start of the rune that ends just before `end`, as Go's
/// `utf8.DecodeLastRune` finds it.
func lastRuneStart(_ s: [UInt8], before end: Int, from start: Int) -> Int {
    var i = end - 1
    var steps = 0
    while i > start && isContinuationByte(s[i]) && steps < 3 {
        i -= 1
        steps += 1
    }
    let (_, size) = decodeRune(s[start..<end], at: i)
    return i + size == end ? i : end - 1
}

/// Go's `strings.TrimSpace` over `s[start..<end]`, as the trimmed bounds.
func trimSpace(_ s: [UInt8], _ start: Int, _ end: Int) -> (Int, Int) {
    var a = start
    while a < end {
        let (r, size) = decodeRune(s[start..<end], at: a)
        if !isSpaceRune(r) { break }
        a += size
    }
    var b = end
    while b > a {
        let i = lastRuneStart(s, before: b, from: a)
        let (r, _) = decodeRune(s[a..<b], at: i)
        if !isSpaceRune(r) { break }
        b = i
    }
    return (a, b)
}

/// Whether `s[start..<end]` is empty after `strings.TrimSpace`.
@inline(__always)
func isBlank(_ s: [UInt8], _ start: Int, _ end: Int) -> Bool {
    let (a, b) = trimSpace(s, start, end)
    return a >= b
}

/// Go's `strings.Index` from `from`: the first offset of `needle` in `hay`.
func firstIndex(of needle: [UInt8], in hay: [UInt8], from: Int = 0) -> Int? {
    let n = needle.count
    if n == 0 { return from <= hay.count ? from : nil }
    if n > hay.count - from { return nil }
    let first = needle[0]
    return hay.withUnsafeBufferPointer { h in
        needle.withUnsafeBufferPointer { q in
            var i = from
            let last = h.count - n
            while i <= last {
                if h[i] == first {
                    var k = 1
                    while k < n && h[i + k] == q[k] { k += 1 }
                    if k == n { return i }
                }
                i += 1
            }
            return nil
        }
    }
}

/// Go's `strings.Count`: the number of non-overlapping occurrences.
func countOccurrences(of needle: [UInt8], in hay: [UInt8]) -> Int {
    guard !needle.isEmpty else { return runes(hay).count + 1 }
    var count = 0
    var from = 0
    while let i = firstIndex(of: needle, in: hay, from: from) {
        count += 1
        from = i + needle.count
    }
    return count
}

/// Splits `s` at every "\n", as Go's `strings.Split(s, "\n")`, returning the
/// bounds of each line without its newline.
func splitLines(_ s: [UInt8], _ start: Int = 0, _ end: Int? = nil) -> [(Int, Int)] {
    let end = end ?? s.count
    var out: [(Int, Int)] = []
    var lineStart = start
    var i = start
    while i < end {
        if s[i] == 0x0A {
            out.append((lineStart, i))
            lineStart = i + 1
        }
        i += 1
    }
    out.append((lineStart, end))
    return out
}

@inline(__always)
func string<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    String(decoding: bytes, as: UTF8.self)
}
