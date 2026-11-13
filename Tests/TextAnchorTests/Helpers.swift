@testable import TextAnchor

/// The UTF-8 offset of the first occurrence of `needle` in `s` from `from`, as
/// Go's `strings.Index`; -1 when absent.
func index(_ s: String, _ needle: String, from: Int = 0) -> Int {
    firstIndex(of: Array(needle.utf8), in: Array(s.utf8), from: from) ?? -1
}

/// The UTF-8 offset of the last occurrence of `needle` in `s`; -1 when absent.
func lastIndex(_ s: String, _ needle: String) -> Int {
    var at = -1
    var from = 0
    while true {
        let i = index(s, needle, from: from)
        if i < 0 { return at }
        at = i
        from = i + 1
    }
}

/// The UTF-8 length of `s`.
func len(_ s: String) -> Int { s.utf8.count }

/// `s[start..<end]` in UTF-8 offsets.
func slice(_ s: String, _ start: Int, _ end: Int) -> String {
    String(decoding: Array(s.utf8)[start..<end], as: UTF8.self)
}

/// The text a resolution selects.
func resolved(_ s: String, _ r: Resolution) -> String {
    guard let u = r.utf8Range else { return "<orphaned>" }
    return slice(s, u.lowerBound, u.upperBound)
}

/// Go's `strings.Repeat`.
func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }

/// Go's `strings.Replace(s, old, new, 1)`.
func replaceFirst(_ s: String, _ old: String, _ new: String) -> String {
    guard let r = s.range(of: old) else { return s }
    return s.replacingCharacters(in: r, with: new)
}

extension String {
    func replacingCharacters(in r: Range<String.Index>, with new: String) -> String {
        var out = self
        out.replaceSubrange(r, with: new)
        return out
    }

    /// Go's `strings.ReplaceAll`.
    func replacingAll(_ old: String, _ new: String) -> String {
        var out = ""
        var rest = self[...]
        while let r = rest.range(of: old) {
            out += rest[..<r.lowerBound]
            out += new
            rest = rest[r.upperBound...]
        }
        out += rest
        return out
    }
}

extension Substring {
    func range(of needle: String) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        var i = startIndex
        while i < endIndex {
            if self[i...].hasPrefix(needle) {
                return i..<self.index(i, offsetBy: needle.count)
            }
            i = index(after: i)
        }
        return nil
    }
}

extension String {
    func range(of needle: String) -> Range<String.Index>? {
        self[...].range(of: needle)
    }
}
