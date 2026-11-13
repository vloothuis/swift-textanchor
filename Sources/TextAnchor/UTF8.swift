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

/// The first occurrence of `needle` in `hay` at or after `from`, as Go's
/// `strings.Index`. It runs in linear time, whatever the input.
package func firstIndex(of needle: [UInt8], in hay: [UInt8], from: Int = 0) -> Int? {
    if needle.isEmpty { return from >= 0 && from <= hay.count ? from : nil }
    var found: Int?
    ByteSearch(needle).scan(hay, from: from) { i in found = i; return false }
    return found
}

/// Every occurrence of `needle` in `hay`, overlapping ones included, in one
/// linear pass. `needle` must not be empty.
package func allIndices(of needle: [UInt8], in hay: [UInt8]) -> [Int] {
    var out: [Int] = []
    ByteSearch(needle).scan(hay, from: 0) { i in out.append(i); return true }
    return out
}

/// Go's `strings.Count`: the number of non-overlapping occurrences.
func countOccurrences(of needle: [UInt8], in hay: [UInt8]) -> Int {
    guard !needle.isEmpty else { return runes(hay).count + 1 }
    var count = 0
    var next = 0
    ByteSearch(needle).scan(hay, from: 0) { i in
        if i >= next { count += 1; next = i + needle.count }
        return true
    }
    return count
}

/// Knuth-Morris-Pratt search: linear in the text and the pattern.
struct ByteSearch {
    let needle: [UInt8]
    /// For each prefix of the needle, the length of its longest proper
    /// border: a prefix that is also a suffix.
    let border: [Int]

    init(_ needle: [UInt8]) {
        self.needle = needle
        var b = [Int](repeating: 0, count: needle.count)
        var k = 0
        for i in needle.indices.dropFirst() {
            while k > 0 && needle[i] != needle[k] { k = b[k - 1] }
            if needle[i] == needle[k] { k += 1 }
            b[i] = k
        }
        border = b
    }

    /// Calls `found` with the start of each match at or after `from`, in
    /// order, until it returns false.
    func scan(_ hay: [UInt8], from: Int, _ found: (Int) -> Bool) {
        let n = needle.count
        guard n > 0, from >= 0, from <= hay.count else { return }
        var k = 0
        for i in from..<hay.count {
            while k > 0 && hay[i] != needle[k] { k = border[k - 1] }
            if hay[i] == needle[k] { k += 1 }
            if k == n {
                if !found(i - n + 1) { return }
                k = border[k - 1]
            }
        }
    }
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
