/// Similarity of two texts, from 0 (completely different) to 1 (identical).
///
/// Below 100 bytes on both sides it is the Levenshtein ratio: one minus the
/// edit distance in runes over the longer length in bytes. Above that it is the
/// Jaccard coefficient of the lower-case word sets.
func similarity(_ a: [UInt8], _ b: [UInt8]) -> Double {
    similarity(a[...], runes(a)[...], b[...], runes(b)[...])
}

func similarity(_ a: String, _ b: String) -> Double {
    similarity(Array(a.utf8), Array(b.utf8))
}

/// `similarity` with the runes of both sides already decoded.
func similarity(
    _ aBytes: ArraySlice<UInt8>, _ aRunes: ArraySlice<UInt32>,
    _ bBytes: ArraySlice<UInt8>, _ bRunes: ArraySlice<UInt32>
) -> Double {
    if aBytes.elementsEqual(bBytes) { return 1 }
    if aBytes.isEmpty || bBytes.isEmpty { return 0 }
    if aBytes.count < 100 && bBytes.count < 100 {
        let distance = levenshtein(aRunes, bRunes)
        let maxLen = max(aBytes.count, bBytes.count)
        return 1 - Double(distance) / Double(maxLen)
    }
    return jaccard(aRunes, bRunes)
}

/// The edit distance between two rune sequences.
func levenshtein(_ a: ArraySlice<UInt32>, _ b: ArraySlice<UInt32>) -> Int {
    levenshtein(a, b, cutoff: Int.max)
}

/// The edit distance between two rune sequences when it is at most `cutoff`,
/// and some value above `cutoff` otherwise. The minimum of a row never
/// decreases from one row to the next, so a row above `cutoff` ends the work.
func levenshtein(_ a: ArraySlice<UInt32>, _ b: ArraySlice<UInt32>, cutoff: Int) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    if a.elementsEqual(b) { return 0 }
    // Keep the row as short as the shorter side.
    let (s1, s2) = a.count > b.count ? (b, a) : (a, b)
    let n = s1.count
    return withUnsafeTemporaryAllocation(of: Int.self, capacity: n + 1) { row in
        for k in 0...n { row[k] = k }
        var j = 1
        for c2 in s2 {
            var prev = j
            var rowMin = j
            var i = 1
            for c1 in s1 {
                let current: Int
                if c1 == c2 {
                    current = row[i - 1]
                } else {
                    current = min(row[i - 1] + 1, prev + 1, row[i] + 1)
                }
                row[i - 1] = prev
                prev = current
                rowMin = min(rowMin, current)
                i += 1
            }
            row[n] = prev
            if rowMin > cutoff { return rowMin }
            j += 1
        }
        return row[n]
    }
}

/// The Jaccard coefficient of the word sets of two rune sequences.
func jaccard(_ a: ArraySlice<UInt32>, _ b: ArraySlice<UInt32>) -> Double {
    let setA = tokenize(a)
    let setB = tokenize(b)
    if setA.isEmpty && setB.isEmpty { return 1 }
    if setA.isEmpty || setB.isEmpty { return 0 }
    let intersection = setA.intersection(setB).count
    let union = setA.union(setB).count
    return union == 0 ? 0 : Double(intersection) / Double(union)
}

/// The lower-case words of a rune sequence, split at whitespace, as Go's
/// `strings.Fields(strings.ToLower(s))` gives them.
func tokenize(_ s: ArraySlice<UInt32>) -> Set<[UInt32]> {
    var out = Set<[UInt32]>()
    var word: [UInt32] = []
    for r in s {
        if isSpaceRune(r) {
            if !word.isEmpty { out.insert(word); word.removeAll(keepingCapacity: true) }
        } else {
            word.append(toLower(r))
        }
    }
    if !word.isEmpty { out.insert(word) }
    return out
}

/// The simple lower-case mapping of one rune, as Go's `unicode.ToLower`.
@inline(__always)
func toLower(_ r: UInt32) -> UInt32 {
    if r < 0x80 {
        return (r >= 0x41 && r <= 0x5A) ? r + 0x20 : r
    }
    guard let scalar = Unicode.Scalar(r) else { return r }
    return scalar.properties.lowercaseMapping.unicodeScalars.first?.value ?? r
}

// MARK: - The fuzzy phase

/// Tuning constants for the fuzzy phase. They bound the work done per
/// paragraph, since the substring search costs windows times Levenshtein.
enum Fuzzy {
    /// The score a windowed match must reach to be offered as a candidate.
    static let minSimilarity = 0.6
    /// The total number of similarity calls one substring search may make,
    /// across every window size it tries. The budget is spent as a stride over
    /// start positions, so the whole paragraph stays reachable.
    static let maxComparisons = 4096
    /// Scales a fuzzy candidate's quote score, so an exact match of the same
    /// text always outranks it.
    static let penalty = 0.8
    /// The score at or above which the search stops early.
    static let perfectMatch = 0.995
}

struct FuzzyMatch: Equatable {
    var start = 0
    var end = 0
    var similarity = 0.0
}

/// A blank-line-delimited block with its byte offset in the document.
struct Paragraph: Sendable {
    var start: Int
    var end: Int
}

/// Splits `s` into paragraphs, keeping each one's offset. A paragraph keeps
/// the newline of its last line, as Go's `strings.SplitAfter` gives it.
func splitParagraphsWithOffsets(_ s: [UInt8]) -> [Paragraph] {
    var out: [Paragraph] = []
    var start = -1
    var lineStart = 0
    while lineStart < s.count {
        var lineEnd = lineStart
        while lineEnd < s.count && s[lineEnd] != 0x0A { lineEnd += 1 }
        if lineEnd < s.count { lineEnd += 1 }
        if isBlank(s, lineStart, lineEnd) {
            if start >= 0 {
                out.append(Paragraph(start: start, end: lineStart))
                start = -1
            }
        } else if start < 0 {
            start = lineStart
        }
        lineStart = lineEnd
    }
    if start >= 0 { out.append(Paragraph(start: start, end: s.count)) }
    return out
}

/// The query of a fuzzy search: the collapsed quote with its runes.
struct FuzzyQuery {
    var bytes: [UInt8]
    var runes: [UInt32]
    /// How often each rune occurs, with runes folded into 256 buckets.
    var histogram: [Int32]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.runes = TextAnchor.runes(bytes)
        var h = [Int32](repeating: 0, count: 256)
        for r in runes { h[Int(r & 0xFF)] += 1 }
        self.histogram = h
    }
}

/// Finds, per paragraph, the window most similar to `query`, and returns those
/// that reach the floor. `query` must already be collapsed.
func findFuzzyMatches(in chunks: [Chunk], document: [UInt8], query: FuzzyQuery) -> [FuzzyMatch] {
    var matches: [FuzzyMatch] = []
    if query.bytes.count < 5 { return matches }

    for chunk in chunks {
        let match = trimMatch(bestSubstringMatch(chunk, query, floor: Fuzzy.minSimilarity), in: chunk.c.text)
        if match.similarity < Fuzzy.minSimilarity { continue }
        let range = chunk.c.sourceRange(match.start, match.end)
        if range.start == range.end { continue }
        matches.append(FuzzyMatch(
            start: chunk.paragraph.start + range.start,
            end: chunk.paragraph.start + range.end,
            similarity: match.similarity
        ))
    }
    return matches
}

/// `findFuzzyMatches` over a raw document, for tests.
func findFuzzyMatchesByParagraph(_ document: String, _ query: String) -> [FuzzyMatch] {
    let doc = AnchorDocument(document)
    return findFuzzyMatches(in: doc.chunks, document: doc.bytes, query: FuzzyQuery(Array(query.utf8)))
}

/// The window of the chunk's collapsed text most similar to `query`. The
/// number of similarity calls is bounded by `Fuzzy.maxComparisons`.
///
/// Windows that cannot beat the best so far, or cannot reach `floor`, are
/// skipped without computing their similarity. The result is the same as
/// without skipping whenever the best window reaches `floor`.
func bestSubstringMatch(_ chunk: Chunk, _ query: FuzzyQuery, floor: Double = 0) -> FuzzyMatch {
    let text = chunk.c.text
    let q = query.bytes
    if text.isEmpty || q.isEmpty { return FuzzyMatch() }

    if text.count <= q.count * 2 {
        return FuzzyMatch(
            start: 0, end: text.count,
            similarity: similarity(text[...], chunk.runes[...], q[...], query.runes[...])
        )
    }

    let windowSize = q.count
    var best = FuzzyMatch()
    var pruner = Pruner(query)
    let minSize = windowSize - windowSize / 4
    let maxSize = windowSize + windowSize / 4

    for size in minSize...maxSize {
        if size <= 0 || size > text.count { continue }
        let step = windowStride(text.count, size, minSize, maxSize)
        var i = 0
        while i <= text.count - size {
            defer { i += step }
            let end = i + size
            // Only windows on rune boundaries: a split rune reads as an edit.
            if isContinuationByte(text[i]) || (end < text.count && isContinuationByte(text[end])) {
                continue
            }
            let windowRunes = chunk.runes[chunk.byteRune[i]..<chunk.byteRune[end]]
            let sim: Double
            if size < 100 && q.count < 100 && !text[i..<end].elementsEqual(q) {
                // Levenshtein: skip windows whose distance must be too large.
                guard let cutoff = pruner.cutoff(windowRunes, maxLen: max(size, q.count),
                                                 best: best.similarity, floor: floor) else { continue }
                let d = levenshtein(windowRunes, query.runes[...], cutoff: cutoff)
                sim = 1 - Double(d) / Double(max(size, q.count))
            } else {
                sim = similarity(text[i..<end], windowRunes, q[...], query.runes[...])
            }
            if sim > best.similarity {
                best = FuzzyMatch(start: i, end: end, similarity: sim)
                if sim >= Fuzzy.perfectMatch { return best }
            }
        }
    }
    return best
}

/// Bounds the edit distance between a window and the query from below, by
/// comparing how often each rune occurs in both.
struct Pruner {
    var diff: [Int32]
    let queryCount: Int

    init(_ query: FuzzyQuery) {
        diff = query.histogram
        queryCount = query.runes.count
    }

    /// The largest edit distance that still gives a similarity above `best`
    /// and at least `floor`, or nil when the window cannot get there.
    mutating func cutoff(_ window: ArraySlice<UInt32>, maxLen: Int, best: Double, floor: Double) -> Int? {
        // Every rune the window has more of than the query needs an edit, and
        // so does every rune the query has more of.
        var surplus = 0
        diff.withUnsafeMutableBufferPointer { d in
            for r in window {
                let k = Int(r & 0xFF)
                if d[k] <= 0 { surplus += 1 }
                d[k] -= 1
            }
            for r in window { d[Int(r & 0xFF)] += 1 }
        }
        let lower = max(surplus, queryCount - window.count + surplus)

        func accepted(_ d: Int) -> Bool {
            let sim = 1 - Double(d) / Double(maxLen)
            return sim > best && sim >= floor
        }
        if !accepted(lower) { return nil }
        var k = maxLen
        while k > lower && !accepted(k) { k -= 1 }
        return k
    }
}

/// The step between start positions for one window size, sharing the budget
/// evenly across every size in `minSize...maxSize`.
func windowStride(_ textLen: Int, _ size: Int, _ minSize: Int, _ maxSize: Int) -> Int {
    let sizeCount = max(maxSize - minSize + 1, 1)
    let startsPerSize = max(Fuzzy.maxComparisons / sizeCount, 1)
    let starts = textLen - size + 1
    if starts <= startsPerSize { return 1 }
    return (starts + startsPerSize - 1) / startsPerSize
}

/// Pulls whitespace off both ends of a windowed match.
func trimMatch(_ m: FuzzyMatch, in text: [UInt8]) -> FuzzyMatch {
    var m = m
    let isSpace: (UInt8) -> Bool = { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    if text[m.start..<m.end].allSatisfy(isSpace) { return FuzzyMatch() }
    while m.start < m.end && isSpace(text[m.start]) { m.start += 1 }
    while m.end > m.start && isSpace(text[m.end - 1]) { m.end -= 1 }
    return m
}
