import Foundation
import Testing
@testable import TextAnchor

@Suite struct CollapseTests {
    @Test(arguments: [
        ("empty", "", ""),
        ("all whitespace", "   \n\t ", ""),
        ("single char", "a", "a"),
        ("leading and trailing stripped", "  hello  ", "hello"),
        ("interior run collapsed", "a  \n\t b", "a b"),
        ("newline becomes space", "wrapped\nline", "wrapped line"),
        ("blank line becomes one space", "para\n\nnext", "para next"),
        ("multi-byte preserved", " café  déjà ", "café déjà"),
    ])
    func collapse(_ name: String, _ input: String, _ want: String) throws {
        let c = collapseWhitespace(input)
        let inBytes = Array(input.utf8)
        #expect(string(c.text) == want, "\(name)")
        #expect(c.posMap.count == c.text.count + 1, "one per byte plus sentinel")
        #expect(c.posMap.last == inBytes.count, "sentinel")
        for i in 0..<c.text.count {
            let src = c.posMap[i]
            try #require(src >= 0 && src < inBytes.count, "posMap[\(i)] = \(src) out of range")
            if c.text[i] != 0x20 {
                #expect(c.text[i] == inBytes[src], "posMap[\(i)] = \(src)")
            }
        }
    }

    @Test(arguments: [
        ("start past end of text", "hello world", 100, 200),
        ("all whitespace input", "   ", 0, 1),
        ("empty input", "", 0, 5),
        ("negative offsets", "hello", -5, -1),
        ("inverted range", "hello", 4, 2),
        ("end far past the text", "hello", 0, 1 << 30),
        ("zero-length span", "hello", 2, 2),
    ])
    func sourceRangeDegenerate(_ name: String, _ input: String, _ start: Int, _ end: Int) {
        let c = collapseWhitespace(input)
        let r = c.sourceRange(start, end)
        #expect(r.start >= 0 && r.end <= len(input) && r.start <= r.end, "\(name): \(r)")
    }

    @Test(arguments: [
        "café déjà vu",
        "この文書は日本語です",
        "deploy 🎉 finished",
        rep("αβγ ", 20),
    ])
    func sourceRangeRuneBoundaries(_ input: String) {
        let c = collapseWhitespace(input)
        let bytes = Array(input.utf8)
        for start in 0...c.text.count {
            for end in start...c.text.count {
                let r = c.sourceRange(start, end)
                if r.start == r.end { continue }
                let startOK = r.start == 0 || !isContinuationByte(bytes[r.start])
                let endOK = r.end == bytes.count || !isContinuationByte(bytes[r.end])
                if !(startOK && endOK) {
                    Issue.record("sourceRange(\(start), \(end)) = \(r) splits a rune in \(input)")
                    return
                }
            }
        }
    }
}

@Suite struct ByteSearchTests {
    @Test(arguments: [
        ("abc", "xxabcabc", [2, 5]),
        ("aa", "aaaa", [0, 1, 2]),
        ("abab", "abababab", [0, 2, 4]),
        ("x", "abc", []),
        ("abcd", "abc", []),
    ])
    func allMatches(_ needle: String, _ hay: String, _ want: [Int]) {
        #expect(allIndices(of: Array(needle.utf8), in: Array(hay.utf8)) == want)
        #expect(firstIndex(of: Array(needle.utf8), in: Array(hay.utf8)) == want.first)
        #expect(firstIndex(of: Array(needle.utf8), in: Array(hay.utf8), from: 1) == want.first { $0 >= 1 })
    }

    @Test func countIsNonOverlapping() {
        #expect(countOccurrences(of: Array("aa".utf8), in: Array("aaaaa".utf8)) == 2)
    }

    /// A naive search takes quadratic time on this input.
    @Test func linearOnRepetitiveInput() {
        let hay = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        let needle = [UInt8](repeating: UInt8(ascii: "a"), count: 50_000) + [UInt8(ascii: "b")]
        let clock = ContinuousClock()
        let elapsed = clock.measure { #expect(firstIndex(of: needle, in: hay) == nil) }
        #expect(elapsed < .seconds(2))
    }
}
