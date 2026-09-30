/// Small questions about text, answered without Foundation.
///
/// The format's rules are about bytes and a handful of characters, and the
/// Linux build has neither `NSRegularExpression` nor `CharacterSet` without
/// ICU, which would make a command-line check tens of megabytes. So the few
/// answers the rules need are spelt out here, each one the same answer
/// Foundation gives on a Mac — the tests hold them to it, character by
/// character.
enum ASCII {
    static func isLowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
    }
}

enum Blank {
    /// `CharacterSet.whitespaces`: tab and the space separators — and U+200B,
    /// ZERO WIDTH SPACE, which Foundation counts although Unicode does not
    /// call it a space. Listed rather than asked of Unicode's categories, so
    /// that the answer does not move with the Unicode tables of whichever
    /// standard library the code was built with.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x20, 0xA0, 0x1680, 0x2000 ... 0x200B, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    /// `CharacterSet.whitespacesAndNewlines`: the above, and the line breaks.
    static func isSpaceOrNewline(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A ... 0x0D, 0x85, 0x2028, 0x2029: true
        default: isSpace(scalar)
        }
    }

    /// Whether `text.trimmingCharacters(in: .whitespacesAndNewlines)` would be
    /// empty.
    static func isBlank(_ text: some StringProtocol) -> Bool {
        text.unicodeScalars.allSatisfy(isSpaceOrNewline)
    }

    /// Whether `text.trimmingCharacters(in: .whitespaces)` would be empty — a
    /// line break is not blank here.
    static func isBlankOnOneLine(_ text: some StringProtocol) -> Bool {
        text.unicodeScalars.allSatisfy(isSpace)
    }

    /// `text.trimmingCharacters(in: .whitespacesAndNewlines)`.
    static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpaceOrNewline($0) }),
              let last = scalars.lastIndex(where: { !isSpaceOrNewline($0) }) else { return "" }
        return String(scalars[first ... last])
    }
}

/// What Python calls white space — `str.isspace()`, and so what `str.strip()`
/// takes away and what `\s` matches in a pattern. The official repository's
/// rules were written in Python and read a licence line and a name with it, so
/// the Swift check reads them with the same characters: Python's list differs
/// from Foundation's (U+001C–U+001F are space to it, U+200B is not).
enum PythonSpace {
    static func contains(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09 ... 0x0D, 0x1C ... 0x20, 0x85, 0xA0, 0x1680, 0x2000 ... 0x200A, 0x2028, 0x2029, 0x202F, 0x205F,
             0x3000: true
        default: false
        }
    }

    /// `text.rstrip()`.
    static func trimmingEnd(_ text: Substring.UnicodeScalarView) -> Substring.UnicodeScalarView {
        var text = text
        while let last = text.last, contains(last) { text.removeLast() }
        return text
    }

    /// Whether `text.strip()` is empty.
    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(contains)
    }
}
