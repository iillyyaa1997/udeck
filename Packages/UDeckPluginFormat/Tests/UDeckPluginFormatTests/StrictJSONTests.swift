import Foundation
import Testing
@testable import UDeckPluginFormat

/// The repository check's own JSON reader: what `JSONDecoder` cannot say about
/// a file — a field given twice, a byte order mark, how a number was written.
@Suite("JSON read strictly")
struct StrictJSONTests {
    func parse(_ text: String) -> StrictJSON.Document { StrictJSON.parse(Array(text.utf8)) }

    @Test("a field given twice is said once, and both values are kept")
    func repeatedFields() throws {
        let document = parse(#"{"a": 1, "b": {"a": 2, "a": 3}, "a": 4, "c": [{"c": 1, "c": 2}], "a": 5}"#)
        #expect(document.problems == [#"gives the field "a" more than once"#, #"gives the field "c" more than once"#])
        let object = try #require(document.value?.object)
        #expect(object.first("a")?.number?.wholeValue == 1)
        #expect(object.last("a")?.number?.wholeValue == 5)
        #expect(object.keys == ["a", "b", "c"])
        #expect(object.members.count == 5)
        #expect(parse(#"{"a": 1, "b": 2}"#).problems.isEmpty)
    }

    @Test("what is not JSON is said to be not JSON", arguments: [
        "", " ", "{", "{\"a\": 1", "[1, 2", "{\"a\" 1}", "{a: 1}", "{'a': 1}", "{\"a\": 1,}", "[1,]", "[,1]",
        "{\"a\": 1} {}", "NaN", "{\"a\": NaN}", "{\"a\": Infinity}", "{\"a\": -Infinity}", "01", "1.", ".5", "-",
        "1e", "+1", "\"\\x\"", "\"\\u12\"", "\"tab\there\"", "\"a\u{0}b\"", "\"\\ud800\"", "\"\\udc00\"",
        "\"\\ud800\\u0041\"", "\"unended", "tru", "nul", "[1e400]", "[-1e400]", "[1e99999999999999999999]",
    ])
    func notJSON(_ text: String) {
        let document = parse(text)
        #expect(document.value == nil, "\(text.debugDescription)")
        #expect(document.problems.count == 1)
        #expect(document.problems.first?.hasPrefix("is not valid JSON: ") == true, "\(document.problems)")
    }

    @Test("what is JSON is read", arguments: [
        "{}", "[]", "0", "-0", "1.5e-3", "\"\\ud83d\\ude00\"", "\"\\u00e9\\n\\t\\/\\\\\\\"\"", " \t\r\n[ 1 , 2 ] ",
        "true", "false", "null", "[[[]]]", "{\"\": \"\"}", "1E+2", "\"ю\"",
    ])
    func json(_ text: String) {
        let document = parse(text)
        #expect(document.value != nil, "\(text.debugDescription): \(document.problems)")
        #expect(document.problems.isEmpty)
    }

    @Test("a byte order mark, and bytes that are not UTF-8, are named")
    func encoding() {
        let bom = StrictJSON.parse([0xEF, 0xBB, 0xBF] + Array("{}".utf8))
        #expect(bom.value == nil)
        #expect(bom.problems.first?.contains("byte order mark") == true)
        for (bytes, position) in [([0x7B, 0x22, 0xE9, 0x22], 2), ([0xC0, 0xAF], 0), ([0x22, 0xED, 0xA0, 0x80, 0x22], 1),
                                  ([0x5B, 0x31, 0xFF], 2)] as [([UInt8], Int)] {
            #expect(StrictJSON.parse(bytes).problems == ["is not UTF-8 (byte \(position) cannot be read)"])
        }
        #expect(StrictJSON.parse(Array("{\"ключ\": \"значение\"}".utf8)).problems.isEmpty)
    }

    /// The number as written, and whether it is a whole number an `Int`
    /// holds — exactly, never through a `Double`.
    @Test("a number keeps how it was written")
    func numbers() throws {
        func number(_ literal: String) throws -> StrictJSON.Number {
            try #require(parse("[\(literal)]").value?.array?.first?.number, "\(literal)")
        }
        let cases: [(String, Bool, Int?)] = [
            ("0", true, 0), ("-0", true, 0), ("1", true, 1), ("1.0", false, 1), ("1e0", false, 1), ("10e-1", false, 1),
            ("0.1e1", false, 1), ("1.5", false, nil), ("1e-400", false, nil), ("1.00000000000000000000001", false, nil),
            ("1.00000000000000001", false, nil), ("0.99999999999999999999999", false, nil),
            ("9223372036854775807", true, Int.max), ("9223372036854775808", true, nil),
            ("-9223372036854775808", true, Int.min), ("-9223372036854775809", true, nil),
            ("9223372036854775807.000", false, Int.max), ("9.223372036854775807e18", false, Int.max),
            ("9.223372036854776e18", false, nil), ("1e18", false, 1_000_000_000_000_000_000), ("1e19", false, nil),
            ("1e0000000000000000000000", false, 1), ("123e-2", false, nil), ("1200e-2", false, 12), ("1e300", false, nil),
            ("0.000", false, 0), ("-0.0e5", false, 0)
        ]
        for (literal, isIntegerLiteral, whole) in cases {
            let parsed = try number(literal)
            #expect(parsed.literal == literal)
            #expect(parsed.isIntegerLiteral == isIntegerLiteral, "\(literal)")
            #expect(parsed.wholeValue == whole, "\(literal)")
        }
        #expect(try number("1.5").double == 1.5)
        #expect(try number("1e-400").double == 0)
    }

    /// The containers left open are counted on a stack of the reader's own,
    /// so depth costs no stack frames; the limit is `JSONDecoder`'s unless
    /// the caller asks for another.
    @Test("containers nest as deep as JSONDecoder reads, and deeper is refused without a crash")
    func depth() {
        // Whether each was read, as a plain answer: a failed expectation
        // describes its operands, and a value 513 deep described is a stack
        // overflow of its own.
        func read(_ bytes: [UInt8], maximumDepth: Int = StrictJSON.decoderDepth) -> Bool {
            StrictJSON.parse(bytes, maximumDepth: maximumDepth).value != nil
        }
        func nested(_ depth: Int) -> [UInt8] { Array((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8) }
        #expect(read(nested(512)))
        #expect(!read(nested(513)))
        #expect(read(nested(513), maximumDepth: 513))
        #expect(!read(nested(200_000)))
        #expect(StrictJSON.parse(nested(200_000)).problems.first?.contains("nested more than 512 deep") == true)
        #expect(read(Array(("{\"a\":" + String(repeating: "{\"a\":", count: 511) + "1" + String(repeating: "}", count: 512)).utf8)))
    }

    /// Only where uDeck reads the way `JSONSerialization` did.
    @Test("a comma before a closing bracket is accepted only when asked")
    func trailingCommas() {
        for text in [#"{"a": 1,}"#, "[1, 2,]", #"{"a": [1,], "b": {"c": 2,},}"#] {
            #expect(parse(text).value == nil)
            #expect(StrictJSON.parse(Array(text.utf8), trailingCommas: true).value != nil, "\(text)")
        }
        for text in [#"{,}"#, "[,]", #"{"a": 1,,}"#, "[1,,]"] {
            #expect(StrictJSON.parse(Array(text.utf8), trailingCommas: true).value == nil, "\(text)")
        }
    }

    @Test("text in UTF-16 or UTF-32 reads as UTF-8, as JSONSerialization read it")
    func otherEncodings() throws {
        let text = #"{"a":"Юникод 😀"}"#
        func bytes(_ units: [UInt32], width: Int, bigEndian: Bool) -> [UInt8] {
            units.flatMap { unit in
                let little = (0 ..< width).map { UInt8(truncatingIfNeeded: unit >> (8 * $0)) }
                return bigEndian ? little.reversed() : little
            }
        }
        let utf16 = text.utf16.map(UInt32.init)
        let utf32 = text.unicodeScalars.map(\.value)
        let expected = Array(text.utf8)
        #expect(StrictJSON.utf8(fromAnyUnicode: expected) == expected)
        #expect(StrictJSON.utf8(fromAnyUnicode: [0xEF, 0xBB, 0xBF] + expected) == expected)
        #expect(StrictJSON.utf8(fromAnyUnicode: [0xFF, 0xFE] + bytes(utf16, width: 2, bigEndian: false)) == expected)
        #expect(StrictJSON.utf8(fromAnyUnicode: [0xFE, 0xFF] + bytes(utf16, width: 2, bigEndian: true)) == expected)
        #expect(StrictJSON.utf8(fromAnyUnicode: bytes(utf16, width: 2, bigEndian: false)) == expected)
        #expect(StrictJSON.utf8(fromAnyUnicode: bytes(utf16, width: 2, bigEndian: true)) == expected)
        #expect(StrictJSON.utf8(fromAnyUnicode: bytes(utf32, width: 4, bigEndian: false)) == expected)
        #expect(StrictJSON.utf8(fromAnyUnicode: bytes(utf32, width: 4, bigEndian: true)) == expected)
        // Half a surrogate pair in UTF-16, and an odd number of bytes, are not text.
        #expect(StrictJSON.utf8(fromAnyUnicode: [0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00]) == nil)
        #expect(StrictJSON.utf8(fromAnyUnicode: [0xFF, 0xFE, 0x7B]) == nil)
    }
}
