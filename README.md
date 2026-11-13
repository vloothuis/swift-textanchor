# swift-textanchor

Durable references to spans of text in Markdown documents. An anchor still
finds its text after the document is edited.

This is a Swift port of [textanchor](https://github.com/vloothuis/textanchor),
a Go library. It gives the same results as the Go library, and it reads and
writes the same JSON.

## The problem

You want to attach something to a span of text in a Markdown file, such as a
comment, a highlight or a suggestion. You want to store it outside that file.

A byte offset breaks as soon as someone inserts a line above it. A plain text
search breaks as soon as the same words appear twice.

An anchor describes a span by its content and its surroundings. Later, it finds
the span again by searching and scoring. When it cannot find a confident match,
it says so. It does not guess.

## Install

Add the package to `Package.swift`:

```swift
.package(url: "https://github.com/vloothuis/swift-textanchor.git", from: "0.1.0"),
```

Then add a library to your target. There are two:

- `TextAnchor` creates and resolves anchors. It has no dependencies.
- `QuoteFind` finds text that a reader selected in rendered Markdown, and
  splits a range into highlight segments. It uses
  [swift-markdown](https://github.com/swiftlang/swift-markdown).

## Create and resolve an anchor

```swift
import TextAnchor

let document = "# Setup\n\nInstall the tools. Then run the tests.\n"
let range = document.range(of: "run the tests")!

// Create an anchor and store it next to your comment.
let anchor = try Anchor(document: document, range: range)
let json = try JSONEncoder().encode(anchor)

// Later, find the text again in the edited document.
let edited = "# Setup\n\nFirst install the tools.\nThen run the tests.\n"
let result = anchor.resolve(in: edited)
if let found = result.range {
    print(edited[found], result.confidence)
} else {
    // The text is gone or changed too much. Show anchor.quote to the user
    // instead of dropping the comment.
    print(result.orphanReason!)
}
```

To resolve many anchors in one document, prepare the document once:

```swift
let prepared = AnchorDocument(edited)
let results = prepared.resolve(anchors)
```

`AnchorDocument` is immutable and `Sendable`, so you can resolve on several
threads at once.

## Offsets

Swift strings have several kinds of offset. Every API takes and returns each
of these:

- `Range<String.Index>`, for Swift strings.
- UTF-16 offsets, for `NSString`, `NSRange`, AppKit and UIKit text views, and
  JavaScript.
- UTF-8 byte offsets, which match the Go library.

`Anchor(document:range:)`, `Anchor(document:utf16Range:)` and
`Anchor(document:utf8Range:)` create an anchor. A `Resolution` has `range`,
`utf16Range` and `utf8Range`. `TextOffsets` converts between the kinds.

An offset that splits a character, such as a UTF-16 offset inside an emoji,
throws `AnchorError.notOnScalarBoundary`.

## How resolution works

Resolution runs up to three searches, in this order:

1. **Exact.** It looks for the quote with all whitespace collapsed. A quote
   that was rewrapped, or that spans a heading and its body, still matches.
2. **Across paragraphs.** A quote that spans paragraphs is matched by its first
   and last paragraph. This finds it after the middle was edited.
3. **Close.** It compares the quote with windows of each paragraph. Short
   quotes use edit distance and long quotes compare their words.

Each candidate gets a score from 0 to 1:

| Part | Weight |
|------|--------|
| How well the quote matches | 40% |
| How well the text before it matches the stored prefix | 20% |
| How well the text after it matches the stored suffix | 20% |
| The heading above it and its paragraph position | 10% |
| How few other candidates there are | 10% |

The best candidate wins when it scores at least `minConfidence`, which is 0.5
by default. Otherwise the anchor is orphaned, with the reason
`quoteNotFound` or `confidenceTooLow`.

## Find a reader's selection

A reader selects text in rendered Markdown, such as a web page. The selection
has no `**`, `#` or link targets. `QuoteFinder` finds that text in the
Markdown source:

```swift
import QuoteFind

let markdown = "Some **bold** text and a [link](https://example.com)."
if let match = QuoteFinder.find("bold text and a link", in: markdown) {
    print(markdown[match.range]) // bold** text and a [link
}
```

Pass the text around the selection to pick the right one of several matches:

```swift
QuoteFinder.find(quote, in: markdown, prefix: textBefore, suffix: textAfter)
```

`RenderedText(markdown:)` gives the rendered text, with a map from each byte
back to the source.

## Highlight a range that spans blocks

One HTML element cannot cross the end of a paragraph or a list item. To
highlight a range that spans blocks, split it into segments and wrap each one
in its own element:

```swift
let doc = SegmentedDocument(markdown)
for segment in doc.segments(range) {
    // Wrap markdown[segment] in a highlight.
}
```

Segments leave out block markup, such as `## ` and `- [ ] `. They keep
emphasis, links and code spans whole.

## Compatibility with the Go library

The JSON has the same keys as the Go library: `quote`, `prefix`, `suffix`,
`containing_sentence`, `heading_context` and `paragraph_index`. Anchors made by
one library resolve in the other.

The tests compare this package with the Go library on a fixed set of
documents. `Scripts/parity` holds the Go program that writes those results.
To update them, run `go run .` in that folder.

A few results differ on purpose:

- The Go library cuts the prefix and suffix at a byte count, which can split a
  character. This package cuts at the character boundary before it.
- An offset that splits a character throws an error. The Go library accepts it.
- A `QuoteMatch` is widened to whole characters.
- The Go library parses Markdown with goldmark. This package uses cmark-gfm,
  through swift-markdown. They differ in a few rare cases, such as an escaped
  `|` in a table cell.

This package is also faster when it compares a short quote with many windows.
It skips windows that cannot win, without changing the result.

## Licence

MIT. See [LICENSE](LICENSE).
