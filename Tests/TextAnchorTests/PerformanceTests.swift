import Foundation
import Testing
@testable import TextAnchor

#if DEBUG
let isReleaseBuild = false
#else
let isReleaseBuild = true
#endif

/// A review of a long document: 200 anchors in about 100,000 characters,
/// resolved after an edit. It runs only in a release build:
/// `swift test -c release`.
@Suite(.enabled(if: isReleaseBuild)) struct PerformanceTests {
    static func document() -> String {
        var doc = "# Handbook\n\n"
        var i = 0
        while doc.utf8.count < 100_000 {
            doc += "## Section \(i)\n\nThe service in section \(i) reads its settings at startup and writes "
            doc += "a report every \(i % 7 + 1) hours. Operators check the report before they restart it.\n\n"
            doc += "- Step \(i).1: stop the worker\n- Step \(i).2: rotate the logs\n\n"
            i += 1
        }
        return doc
    }

    @Test func reviewOfLongDocument() throws {
        let doc = Self.document()
        let bytes = Array(doc.utf8)
        var anchors: [Anchor] = []
        var k = 0
        while anchors.count < 200 {
            let start = (k * 7919) % (bytes.count - 200)
            let len = [12, 40, 120, 300][k % 4]
            k += 1
            anchors.append(try Anchor(document: doc, utf8Range: start..<(start + len)))
        }
        let edited = "A new opening paragraph.\n\n" + doc
            .replacingOccurrences(of: "reads its settings", with: "loads its settings")
            .replacingOccurrences(of: ". ", with: ".\n")
        let clock = ContinuousClock()
        var results: [Resolution] = []
        let elapsed = clock.measure { results = AnchorDocument(edited).resolve(anchors) }
        let resolved = results.filter { !$0.isOrphaned }.count
        print("resolved \(resolved)/\(anchors.count) in \(elapsed)")
        #expect(resolved >= 190)
        #expect(elapsed < .seconds(30))
    }
}
