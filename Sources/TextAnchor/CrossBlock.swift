/// Tuning constants for the cross-block phase (phase 3).
enum CrossBlock {
    /// The most paragraphs a quote may span and still enter phase 3.
    static let maxChunks = 32
    /// How many paragraphs may have been inserted inside the quoted range.
    static let slack = 2
    /// Subtracted from the score per paragraph inserted into or deleted from
    /// the middle of the range.
    static let gapPenalty = 0.15
    /// The endpoint text used to screen paragraphs, in runes.
    static let probeRunes = 48
    /// The probe similarity a paragraph needs to be considered as an endpoint.
    static let screenFloor = 0.5
    /// How many paragraph pairs are fully evaluated.
    static let shortlist = 8
    /// The endpoint text aligned in full evaluation, in runes.
    static let endpointRunes = 512
    /// The endpoint length, in runes, under which an endpoint must match
    /// exactly. A short endpoint is usually a heading, and the floor admits
    /// two edits in five runes.
    static let exactBelow = 12
}

/// Splits a quote into its collapsed blank-line chunks, as runes.
func quoteChunks(_ quote: String) -> [[UInt32]] {
    quoteChunks(Array(quote.utf8))
}

func quoteChunks(_ quote: [UInt8]) -> [[UInt32]] {
    splitParagraphsWithOffsets(quote).compactMap { p in
        let t = collapseWhitespace(Array(quote[p.start..<p.end])).text
        return t.isEmpty ? nil : runes(t)
    }
}

extension AnchorDocument {
    /// Close candidates for a quote that spans several paragraphs.
    ///
    /// Such a quote is a run of paragraphs `q[0..<k]`: it starts inside
    /// `q[0]`, covers the middle whole, and ends inside `q[k-1]`. The start
    /// endpoint is matched against the end of a paragraph `i`, the end
    /// endpoint against the start of a later paragraph `j`, and the middle
    /// against the paragraphs between them. Each endpoint, the middle and
    /// the weighted whole must reach the similarity floor, so the
    /// surrounding text alone can never place an anchor.
    func findCrossBlock(_ quote: [UInt8], aligner al: inout Aligner) -> [Candidate] {
        let q = quoteChunks(quote)
        let k = q.count
        if k < 2 || k > CrossBlock.maxChunks || chunks.count < 2 { return [] }
        let first = q[0], last = q[k - 1]
        var middle: [UInt8] = []
        for (n, m) in q[1..<(k - 1)].enumerated() {
            if n > 0 { middle.append(0x20) }
            middle.append(contentsOf: encodeRunes(m))
        }

        var out: [Candidate] = []
        for p in screenPairs(&al, first, last, k) {
            if let c = evaluatePair(&al, p.i, p.j, first, last, middle, k) {
                out.append(c)
            }
        }
        return out
    }

    /// Scores every paragraph as a start and as an end with a short probe,
    /// and returns the best pairs that fit the quote's shape.
    func screenPairs(_ al: inout Aligner, _ first: [UInt32], _ last: [UInt32], _ k: Int) -> [(i: Int, j: Int, score: Double)] {
        let startProbe = tail(first[...], CrossBlock.probeRunes)
        let endProbe = head(last[...], CrossBlock.probeRunes)

        var asStart = [Double](repeating: 0, count: chunks.count)
        var asEnd = [Double](repeating: 0, count: chunks.count)
        for (n, ch) in chunks.enumerated() {
            asStart[n] = al.atEnd(startProbe, ch.runes[...]).sim
            asEnd[n] = al.atStart(endProbe, ch.runes[...]).sim
        }

        // Each endpoint counts by its length.
        let w0 = Double(startProbe.count), wk = Double(endProbe.count)
        var pairs: [(i: Int, j: Int, score: Double)] = []
        let maxSpan = k - 1 + CrossBlock.slack
        for i in chunks.indices where asStart[i] >= CrossBlock.screenFloor {
            var j = i + 1
            while j < chunks.count && j <= i + maxSpan {
                if asEnd[j] >= CrossBlock.screenFloor {
                    pairs.append((i, j, (w0 * asStart[i] + wk * asEnd[j]) / (w0 + wk)))
                }
                j += 1
            }
        }
        // A stable sort, best first.
        let sorted = pairs.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.map(\.element)
        return Array(sorted.prefix(CrossBlock.shortlist))
    }

    /// Aligns the full endpoints in paragraphs `i` and `j`, compares the
    /// middle, and returns the candidate when it clears every floor.
    func evaluatePair(
        _ al: inout Aligner, _ i: Int, _ j: Int,
        _ first: [UInt32], _ last: [UInt32], _ middle: [UInt8], _ k: Int
    ) -> Candidate? {
        let (start, e0) = locateStart(&al, chunks[i], first)
        let (end, ek) = locateEnd(&al, chunks[j], last)
        if !e0.holds(first.count) || !ek.holds(last.count) { return nil }

        var sum = e0.weight * e0.sim + ek.weight * ek.sim
        var weight = e0.weight + ek.weight

        // A quote with a middle needs that middle present on its own; it
        // counts by the quote's middle length.
        if !middle.isEmpty {
            if j == i + 1 { return nil }
            var docMiddle: [UInt8] = []
            for n in (i + 1)..<j {
                if n > i + 1 { docMiddle.append(0x20) }
                docMiddle.append(contentsOf: chunks[n].c.text)
            }
            let sm = similarity(middle, docMiddle)
            if sm < Fuzzy.minSimilarity { return nil }
            let wm = Double(runes(middle).count)
            sum += wm * sm
            weight += wm
        }

        let gaps = abs((j - i - 1) - (k - 2))
        let score = sum / weight - CrossBlock.gapPenalty * Double(gaps)
        if score < Fuzzy.minSimilarity { return nil }

        let range = ByteRange(start: chunks[i].paragraph.start + start, end: chunks[j].paragraph.start + end)
        if range.start >= range.end { return nil }
        return Candidate(range: range, score: score * Fuzzy.penalty)
    }

    /// Where the start endpoint `q` begins in `ch`, as a byte offset into the
    /// paragraph's raw text, and how well it matched. A long endpoint is
    /// aligned by its tail, and its head is checked where length places it.
    func locateStart(_ al: inout Aligner, _ ch: Chunk, _ q: [UInt32]) -> (Int, EndpointMatch) {
        let probe = tail(q[...], CrossBlock.endpointRunes)
        let (n, sim) = al.atEnd(probe, ch.runes[...])
        var m = EndpointMatch(sim: sim, weight: Double(probe.count))
        var from = max(ch.runes.count - n - (q.count - probe.count), 0)
        let rest = q[..<(q.count - probe.count)]
        if !rest.isEmpty {
            let far = head(rest, CrossBlock.endpointRunes)
            let farSim = al.atStart(far, ch.runes[from...]).sim
            m = m.combine(EndpointMatch(sim: farSim, weight: Double(far.count)))
        }
        while from < ch.runes.count && ch.runes[from] == 0x20 { from += 1 }
        let b = ch.runeByte[from]
        return (ch.c.sourceRange(b, ch.c.text.count).start, m)
    }

    /// Where the end endpoint `q` ends in `ch`, as an exclusive byte offset
    /// into the paragraph's raw text, and how well it matched.
    func locateEnd(_ al: inout Aligner, _ ch: Chunk, _ q: [UInt32]) -> (Int, EndpointMatch) {
        let probe = head(q[...], CrossBlock.endpointRunes)
        let (n, sim) = al.atStart(probe, ch.runes[...])
        var m = EndpointMatch(sim: sim, weight: Double(probe.count))
        var to = min(n + (q.count - probe.count), ch.runes.count)
        let rest = q[probe.count...]
        if !rest.isEmpty {
            let far = tail(rest, CrossBlock.endpointRunes)
            let farSim = al.atEnd(far, ch.runes[..<to]).sim
            m = m.combine(EndpointMatch(sim: farSim, weight: Double(far.count)))
        }
        while to > 0 && ch.runes[to - 1] == 0x20 { to -= 1 }
        let b = ch.runeByte[to]
        return (ch.c.sourceRange(0, b).end, m)
    }
}

/// How well an endpoint aligned: its similarity over the runes compared.
struct EndpointMatch {
    var sim: Double
    var weight: Double

    /// Whether an endpoint of `n` runes matched well enough to count.
    func holds(_ n: Int) -> Bool {
        n < CrossBlock.exactBelow ? sim == 1 : sim >= Fuzzy.minSimilarity
    }

    /// Merges the match of the endpoint's far edge into this one.
    func combine(_ far: EndpointMatch) -> EndpointMatch {
        let w = weight + far.weight
        return EndpointMatch(sim: (sim * weight + far.sim * far.weight) / w, weight: w)
    }
}

/// Computes endpoint alignments, reusing its buffers between calls.
struct Aligner {
    var prev: [Int] = []
    var cur: [Int] = []
    /// The number of edit-distance cells computed.
    var cells = 0

    /// How many leading runes of `text` best match `q`, and the similarity of
    /// that match: the best over n of 1 - lev(q, text[..<n]) / max(|q|, n).
    mutating func atStart(_ q: ArraySlice<UInt32>, _ text: ArraySlice<UInt32>) -> (n: Int, sim: Double) {
        if q.isEmpty || text.isEmpty { return (0, 0) }
        let window = text.prefix(alignWindow(q.count))
        return align(q, window, reversed: false)
    }

    /// `atStart` from the other end: how many trailing runes of `text` best
    /// match `q`.
    mutating func atEnd(_ q: ArraySlice<UInt32>, _ text: ArraySlice<UInt32>) -> (n: Int, sim: Double) {
        if q.isEmpty || text.isEmpty { return (0, 0) }
        let window = tail(text, alignWindow(q.count))
        return align(q, window, reversed: true)
    }

    private mutating func align(_ q: ArraySlice<UInt32>, _ t: ArraySlice<UInt32>, reversed: Bool) -> (n: Int, sim: Double) {
        let tn = t.count, qn = q.count
        if prev.count < tn + 1 {
            prev = [Int](repeating: 0, count: tn + 1)
            cur = [Int](repeating: 0, count: tn + 1)
        }
        cells += qn * tn
        // Reading both from the back aligns their ends with the same table.
        let qa: [UInt32] = reversed ? q.reversed() : Array(q)
        let ta: [UInt32] = reversed ? t.reversed() : Array(t)

        var result: (Int, Double) = (0, 0)
        prev.withUnsafeMutableBufferPointer { p in
            cur.withUnsafeMutableBufferPointer { c in
                var pp = p, cc = c
                for col in 0...tn { pp[col] = col }
                for r in 1...qn {
                    cc[0] = r
                    let qr = qa[r - 1]
                    for col in 1...tn {
                        let cost = qr == ta[col - 1] ? 0 : 1
                        cc[col] = min(pp[col] + 1, cc[col - 1] + 1, pp[col - 1] + cost)
                    }
                    swap(&pp, &cc)
                }
                // On a tie the longer match wins, so a start is not placed
                // inside a word when the runes before it score the same.
                var bestN = 0, bestSim = 0.0
                for n in 1...tn {
                    let sim = 1 - Double(pp[n]) / Double(max(qn, n))
                    if sim > 0 && sim >= bestSim { bestN = n; bestSim = sim }
                }
                result = (bestN, bestSim)
            }
        }
        return result
    }
}

/// The longest stretch of text that could align with a query of `n` runes
/// above zero similarity, plus room for insertions.
func alignWindow(_ n: Int) -> Int { n + n / 2 + 4 }

func head<T>(_ r: ArraySlice<T>, _ n: Int) -> ArraySlice<T> {
    r.count <= n ? r : r.prefix(n)
}

func tail<T>(_ r: ArraySlice<T>, _ n: Int) -> ArraySlice<T> {
    r.count <= n ? r : r.suffix(n)
}

/// The UTF-8 encoding of a rune sequence.
func encodeRunes<C: Sequence>(_ runes: C) -> [UInt8] where C.Element == UInt32 {
    var out: [UInt8] = []
    for r in runes {
        let s = Unicode.Scalar(r) ?? Unicode.Scalar(replacementRune)!
        out.append(contentsOf: String(Character(s)).utf8)
    }
    return out
}
