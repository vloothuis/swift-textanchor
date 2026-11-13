/// Conversions between the three ways to address a span of a string: string
/// indices, UTF-8 byte offsets (the unit of the Go library and of files) and
/// UTF-16 offsets (the unit of `NSString`, `NSRange` and JavaScript).
///
/// Every conversion returns nil for an offset outside the string or one that
/// splits a Unicode scalar.
public enum TextOffsets {
    /// The string indices of a range of UTF-8 byte offsets.
    public static func range(utf8 range: Range<Int>, in text: String) -> Range<String.Index>? {
        guard let lower = index(utf8: range.lowerBound, in: text),
              let upper = index(utf8: range.upperBound, in: text) else { return nil }
        return lower..<upper
    }

    /// The string indices of a range of UTF-16 offsets.
    public static func range(utf16 range: Range<Int>, in text: String) -> Range<String.Index>? {
        guard let lower = index(utf16: range.lowerBound, in: text),
              let upper = index(utf16: range.upperBound, in: text) else { return nil }
        return lower..<upper
    }

    /// The UTF-8 byte offsets of a range of string indices.
    public static func utf8Range(_ range: Range<String.Index>, in text: String) -> Range<Int>? {
        guard isScalarAligned(range.lowerBound, in: text), isScalarAligned(range.upperBound, in: text) else { return nil }
        let u = text.utf8
        return u.distance(from: u.startIndex, to: range.lowerBound)..<u.distance(from: u.startIndex, to: range.upperBound)
    }

    /// The UTF-16 offsets of a range of string indices.
    public static func utf16Range(_ range: Range<String.Index>, in text: String) -> Range<Int>? {
        guard isScalarAligned(range.lowerBound, in: text), isScalarAligned(range.upperBound, in: text) else { return nil }
        let u = text.utf16
        return u.distance(from: u.startIndex, to: range.lowerBound)..<u.distance(from: u.startIndex, to: range.upperBound)
    }

    /// The UTF-16 offsets of a range of UTF-8 byte offsets.
    public static func utf16Range(utf8 range: Range<Int>, in text: String) -> Range<Int>? {
        self.range(utf8: range, in: text).flatMap { utf16Range($0, in: text) }
    }

    /// The UTF-8 byte offsets of a range of UTF-16 offsets.
    public static func utf8Range(utf16 range: Range<Int>, in text: String) -> Range<Int>? {
        self.range(utf16: range, in: text).flatMap { utf8Range($0, in: text) }
    }

    /// The string index at a UTF-8 byte offset.
    public static func index(utf8 offset: Int, in text: String) -> String.Index? {
        let u = text.utf8
        guard offset >= 0, offset <= u.count else { return nil }
        let i = u.index(u.startIndex, offsetBy: offset)
        return isScalarAligned(i, in: text) ? i : nil
    }

    /// The string index at a UTF-16 offset.
    public static func index(utf16 offset: Int, in text: String) -> String.Index? {
        let u = text.utf16
        guard offset >= 0, offset <= u.count else { return nil }
        let i = u.index(u.startIndex, offsetBy: offset)
        return isScalarAligned(i, in: text) ? i : nil
    }

    static func isScalarAligned(_ i: String.Index, in text: String) -> Bool {
        guard i >= text.startIndex, i <= text.endIndex else { return false }
        return i.samePosition(in: text.unicodeScalars) != nil
    }
}
