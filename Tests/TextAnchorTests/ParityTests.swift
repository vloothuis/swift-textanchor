import Foundation
import Testing
@testable import TextAnchor

/// Results of the Go library on a fixed corpus, written by Scripts/parity.
struct AnchorParity: Decodable {
    struct Span: Decodable {
        var doc: String
        var start: Int
        var end: Int
        var anchor: Anchor
    }
    struct Res: Decodable {
        var anchor: Int
        var target: String
        var range: [Int]?
        var confidence: Double
        var orphan_reason: String
    }
    var docs: [String: String]
    var targets: [String: String]
    var anchors: [Span]
    var resolutions: [Res]

    static let shared: AnchorParity = {
        let url = Bundle.module.url(forResource: "parity", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(AnchorParity.self, from: Data(contentsOf: url))
    }()
}

@Suite struct ParityTests {
    /// Go cuts the prefix and suffix at a byte count, which can split a
    /// character; Swift cuts at the character boundary before it. Go's JSON
    /// writes the broken bytes as U+FFFD.
    static func sameContext(_ swift: String, _ go: String, prefix: Bool) -> Bool {
        if swift == go { return true }
        let g = go.replacingOccurrences(of: "\u{FFFD}", with: "")
        return prefix ? g.hasSuffix(swift) || swift.hasSuffix(g) : g.hasPrefix(swift) || swift.hasPrefix(g)
    }

    @Test func anchors() throws {
        let p = AnchorParity.shared
        for (i, c) in p.anchors.enumerated() {
            let a = try Anchor(document: p.docs[c.doc]!, utf8Range: c.start..<c.end)
            let g = c.anchor
            #expect(a.quote == g.quote, "anchor \(i)")
            #expect(Self.sameContext(a.prefix, g.prefix, prefix: true), "anchor \(i) prefix")
            #expect(Self.sameContext(a.suffix, g.suffix, prefix: false), "anchor \(i) suffix")
            #expect(a.containingSentence == g.containingSentence, "anchor \(i) sentence")
            #expect(a.headingContext == g.headingContext, "anchor \(i) heading")
            #expect(a.paragraphIndex == g.paragraphIndex || (g.paragraphIndex == 0 && a.paragraphIndex <= 0), "anchor \(i) paragraph")
        }
    }

    /// Resolves the Go anchors, so the inputs are identical.
    @Test func resolutions() {
        let p = AnchorParity.shared
        var docs: [String: AnchorDocument] = [:]
        for r in p.resolutions {
            let doc = docs[r.target] ?? AnchorDocument(p.targets[r.target]!)
            docs[r.target] = doc
            let res = doc.resolve(p.anchors[r.anchor].anchor)
            let want = r.range.map { $0[0]..<$0[1] }
            #expect(res.utf8Range == want, "\(r.target) anchor \(r.anchor)")
            // A Go context with U+FFFD is not the context Go scored with.
            let a = p.anchors[r.anchor].anchor
            let broken = (a.prefix + a.suffix).contains("\u{FFFD}")
            #expect(broken || abs(res.confidence - r.confidence) < 1e-9, "\(r.target) anchor \(r.anchor): \(res.confidence) vs \(r.confidence)")
            #expect((res.orphanReason?.rawValue ?? "") == r.orphan_reason, "\(r.target) anchor \(r.anchor)")
        }
    }

    @Test func jsonRoundTrip() throws {
        for c in AnchorParity.shared.anchors {
            let data = try JSONEncoder().encode(c.anchor)
            #expect(try JSONDecoder().decode(Anchor.self, from: data) == c.anchor)
        }
    }
}
