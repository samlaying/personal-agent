import Foundation

/// FTS5's `unicode61` tokenizer treats a run of Chinese characters as one token, so a search
/// for 世界 would miss 你好世界. Indexing and querying with a space inserted between adjacent
/// ideographs fixes that: 你好世界 is indexed as 你 好 世 界, and the query 世界 becomes the
/// phrase `"世 界"`, which matches those adjacent tokens.
public enum CJKText {
    public static func tokenize(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        for (offset, scalar) in scalars.enumerated() {
            output.append(scalar)
            if let next = scalars[safe: offset + 1], needsBoundary(scalar, next) {
                output.append(" ")
            }
        }
        return String(output)
    }

    /// unicode61 treats CJK characters and ASCII letters as token characters, so
    /// 容xyz would index as one token and the phrase "内 容" could never match.
    /// A space is needed wherever a CJK character touches a CJK or ASCII-alphanumeric
    /// character; ASCII punctuation is already a separator.
    private static func needsBoundary(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        if isIdeograph(a) && isIdeograph(b) { return true }
        if isIdeograph(a) && isAlnumASCII(b) { return true }
        if isAlnumASCII(a) && isIdeograph(b) { return true }
        return false
    }

    private static func isAlnumASCII(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    /// Undoes `tokenize`, so snippets read like the original text again.
    public static func detokenize(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        for (offset, scalar) in scalars.enumerated() {
            if scalar == " ",
               let previous = scalars[safe: offset - 1],
               let next = scalars[safe: offset + 1],
               isWide(previous), isWide(next) {
                continue
            }
            output.append(scalar)
        }
        return String(output)
    }

    /// Builds an FTS MATCH expression: one quoted phrase per whitespace-separated term.
    /// Returns nil for an empty query.
    public static func ftsQuery(_ text: String) -> String? {
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return nil }

        return terms.map { term -> String in
            if term.unicodeScalars.contains(where: isIdeograph) {
                let tokens = tokenize(term).split(whereSeparator: \.isWhitespace)
                let phrase = tokens.joined(separator: " ").replacingOccurrences(of: "\"", with: "")
                return "\"\(phrase)\""
            }
            return "\"\(term.replacingOccurrences(of: "\"", with: ""))\""
        }.joined(separator: " ")
    }

    /// Scripts written without spaces between words.
    static func isIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FDF,    // CJK radicals
             0x3040...0x30FF,    // Hiragana, Katakana
             0x3400...0x4DBF,    // CJK extension A
             0x4E00...0x9FFF,    // CJK unified ideographs
             0xAC00...0xD7AF,    // Hangul syllables
             0xF900...0xFAFF,    // CJK compatibility ideographs
             0x20000...0x2FA1F:  // CJK extensions B and later
            true
        default:
            false
        }
    }

    /// Ideographs plus the punctuation set off by full-width spacing.
    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        isIdeograph(scalar)
            || (0x3000...0x303F).contains(scalar.value)
            || (0xFF00...0xFFEF).contains(scalar.value)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
