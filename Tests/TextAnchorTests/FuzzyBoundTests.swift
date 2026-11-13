import Testing
@testable import TextAnchor

@Suite struct FuzzyBoundTests {
    /// The comparison budget bounds the number of similarity calls, whatever
    /// the paragraph length. The assertion is on the call count, not on time.
    @Test(arguments: [
        ("short quote, large paragraph", 60000, 35),
        ("long quote, large paragraph", 60000, 76),
        ("long quote, huge paragraph", 1 << 20, 76),
    ])
    func fuzzyPhaseIsBounded(_ name: String, _ textLen: Int, _ query: Int) {
        let minSize = query - query / 4
        let maxSize = query + query / 4
        var total = 0
        for size in minSize...maxSize where size > 0 && size <= textLen {
            let step = windowStride(textLen, size, minSize, maxSize)
            total += (textLen - size) / step + 1
        }
        let limit = Fuzzy.maxComparisons + (maxSize - minSize + 1)
        #expect(total <= limit, "\(name): \(total) windows over \(textLen) bytes")
    }

    /// The stride keeps the tail of a long paragraph reachable.
    @Test func fuzzyPhaseCoversWholeParagraph() {
        let filler = rep("the store writes markdown files to disk and reloads them on change ", 300)
        let quote = "the audit log records every successful write to the graph"
        let doc = filler + quote + "\n"
        let res = Anchor(quote: quote).resolve(in: doc)
        #expect(!res.isOrphaned)
        #expect(resolved(doc, res) == quote)
    }

    /// An absent quote spends the whole budget without matching, and orphans.
    @Test func fuzzyPhaseOrphansAbsentQuote() {
        let doc = rep("the store writes markdown files to disk and reloads them on change ", 900) + "\n"
        let anchor = Anchor(quote: "a completely different sentence that appears nowhere in this document at all")
        let res = anchor.resolve(in: doc)
        #expect(res.isOrphaned, "found \(resolved(doc, res))")
    }
}
