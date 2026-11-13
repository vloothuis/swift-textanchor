import Foundation
import Testing
@testable import QuoteFind

/// Results of the Go library on a fixed corpus, written by Scripts/parity.
struct QuoteFindParity: Decodable {
    struct Rendered: Decodable {
        var source: String
        var text: String
        var map: [Int]
    }
    struct Find: Decodable {
        var doc: String
        var quote: String
        var prefix: String
        var suffix: String
        var range: [Int]?
    }
    struct Segments: Decodable {
        var doc: String
        var start: Int
        var end: Int
        var segments: [[Int]]
    }
    var docs: [String: String]
    var rendered: [Rendered]
    var find: [Find]
    var segments: [Segments]

    static let shared: QuoteFindParity = {
        let url = Bundle.module.url(forResource: "parity", withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(QuoteFindParity.self, from: Data(contentsOf: url))
    }()
}

@Suite struct QuoteFindParityTests {
    @Test func renderedText() {
        for r in QuoteFindParity.shared.rendered {
            let got = RenderedText(markdown: r.source)
            #expect(got.text == r.text, "\(r.source.prefix(40))")
            #expect(got.sourceOffsets == r.map, "\(r.source.prefix(40))")
        }
    }

    @Test func find() {
        let p = QuoteFindParity.shared
        for f in p.find {
            let doc = p.docs[f.doc]!
            let got = QuoteFinder.find(f.quote, in: doc, prefix: f.prefix, suffix: f.suffix)
            #expect(got?.utf8Range == f.range.map { $0[0]..<$0[1] }, "\(f.doc): \(f.quote.prefix(60))")
        }
    }

    @Test func segments() {
        let p = QuoteFindParity.shared
        var docs: [String: SegmentedDocument] = [:]
        for s in p.segments {
            let d = docs[s.doc] ?? SegmentedDocument(p.docs[s.doc]!)
            docs[s.doc] = d
            let got = d.segments(utf8Range: s.start..<s.end).map { [$0.lowerBound, $0.upperBound] }
            #expect(got == s.segments, "\(s.doc) \(s.start)..<\(s.end)")
        }
    }
}
