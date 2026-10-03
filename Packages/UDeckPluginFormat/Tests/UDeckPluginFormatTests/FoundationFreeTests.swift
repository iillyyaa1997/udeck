import Foundation
import Testing
@testable import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// What the library does without Foundation's heavier half — so that it builds
/// on Linux against FoundationEssentials, with no ICU — held to what the same
/// code did with it.
///
/// Each rewrite has two kinds of test. Pinned cases run everywhere and say what
/// the answer is. Comparisons with the Foundation API the code used to call run
/// on a Mac, where that API is the one uDeck shipped with, and they are the
/// proof that nothing an operator could see has moved.
@Suite("Without Foundation's heavier half")
struct FoundationFreeTests {

    // MARK: - Identifiers and setting keys, byte by byte

    /// Every string of up to three characters from an alphabet chosen to be
    /// awkward — the allowed characters, their neighbours, every line break a
    /// regular expression's `$` has an opinion about, and a few from beyond
    /// ASCII that look like allowed ones — and a few at the length limits.
    static let awkward: [String] = {
        let alphabet = ["a", "z", "0", "9", ".", "_", "-", "A", "/", " ", "\n", "\r", "\r\n", "\u{0B}", "\u{0C}",
                        "\u{85}", "\u{2028}", "\u{2029}", "\u{0}", "é", "\u{301}", "٣", "ａ"]
        var all = [""]
        var previous = [""]
        for _ in 1 ... 3 {
            previous = previous.flatMap { head in alphabet.map { head + $0 } }
            all += previous
        }
        for length in [63, 64, 65] {
            all += ["a", "a-", "a\n"].map { String(repeating: "b", count: length - 1) + $0 }
        }
        return all
    }()

    @Test("an id is the pattern people read, byte by byte")
    func identifiersPinned() {
        for accepted in ["a", "0", "disk-space", "x.y_z", "9lives", String(repeating: "a", count: 64)] {
            #expect(PluginIdentifier(rawValue: accepted) != nil, "\(accepted.debugDescription) was refused")
        }
        for refused in ["", ".", "..", "-a", "_a", ".a", "A", "a b", "a/b", "sample\n", "sample\r\n", "a\u{2028}",
                        "é", "ａ", "٣", String(repeating: "a", count: 65)] {
            #expect(PluginIdentifier(rawValue: refused) == nil, "\(refused.debugDescription) was accepted")
        }
        for accepted in ["a", "rows", "show_waiting_only", "0_", String(repeating: "k", count: 200)] {
            #expect(SettingDeclaration.isKey(accepted), "\(accepted.debugDescription) was refused")
        }
        for refused in ["", "_a", "A", "a-b", "a.b", "rows\n", "rows\r", "ключ", "a b"] {
            #expect(!SettingDeclaration.isKey(refused), "\(refused.debugDescription) was accepted")
        }
    }

    #if canImport(Darwin)
    /// The regular expressions uDeck used before, asked the same questions.
    @Test("on a Mac, ids and keys are exactly what the regular expressions said")
    func identifiersMatchTheRegularExpressions() {
        func matches(_ text: String, _ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        var disagreements: [String] = []
        for text in Self.awkward {
            if (PluginIdentifier(rawValue: text) != nil) != matches(text, PluginIdentifier.pattern) {
                disagreements.append("id \(text.debugDescription)")
            }
            if SettingDeclaration.isKey(text) != matches(text, "^[a-z0-9][a-z0-9_]*$") {
                disagreements.append("key \(text.debugDescription)")
            }
        }
        #expect(Self.awkward.count > 12_000)
        #expect(disagreements.isEmpty, "\(disagreements.prefix(20))")
    }
    #endif

    // MARK: - Blank text

    @Test("blank is Foundation's whitespace, pinned")
    func blankPinned() {
        #expect(Blank.isBlank(""))
        #expect(Blank.isBlank(" \t\r\n\u{0B}\u{0C}\u{85}\u{A0}\u{2028}\u{2029}\u{3000}\u{200B}"))
        #expect(!Blank.isBlank(" a "))
        #expect(!Blank.isBlank("\u{FEFF}"), "a byte order mark is not a space")
        #expect(!Blank.isBlank("\u{301}"))
        #expect(Blank.isBlankOnOneLine(" \t\u{200B}"))
        #expect(!Blank.isBlankOnOneLine("\n"), "a line break is not blank on one line — run[0] of \"\\n\"")
        #expect(!Blank.isBlankOnOneLine("\u{2028}"))
    }

    // Every Unicode scalar against the character sets the code used to trim
    // with is in UDeckPluginFormatTimingTests: a million scalars keep a core
    // busy for a second, which a test beside uDeck's measure of its own CPU
    // must not.

    /// What a producer printed is trimmed before it is read as a card, and a
    /// failure keeps its stderr trimmed: once with Foundation's
    /// `trimmingCharacters(in: .whitespacesAndNewlines)`, now with `Blank`.
    @Test("trimming is Foundation's, pinned")
    func trimmedPinned() {
        #expect(Blank.trimmed(" \n\t{\"rows\": []}\r\n\u{3000}") == "{\"rows\": []}")
        #expect(Blank.trimmed("\u{FEFF}{}\u{200B}") == "\u{FEFF}{}", "a byte order mark stays, and is the card's to answer for")
        #expect(Blank.trimmed(" a b ") == "a b")
        #expect(Blank.trimmed("\u{85}\u{2028}") == "")
    }

    #if canImport(Darwin)
    /// Every awkward string. Every scalar there is, alone and around a word,
    /// is in UDeckPluginFormatTimingTests, for the CPU it takes.
    @Test("on a Mac, trimming is exactly what trimming whitespace and newlines said")
    func trimmedMatchesFoundation() {
        var disagreements: [String] = []
        for text in Self.awkward where Blank.trimmed(text) != text.trimmingCharacters(in: .whitespacesAndNewlines) {
            disagreements.append(text.debugDescription)
        }
        #expect(disagreements.isEmpty, "\(disagreements.prefix(20))")
    }

    /// A failure says how long a producer was given: "within 2s", "within 2.5s".
    @Test("on a Mac, one decimal is exactly what String(format:) wrote")
    func oneDecimalMatchesFormat() {
        var values: [Double] = [0, -0.0, 0.05, 0.15, 0.25, 0.35, 0.45, 2.5, 2.45, 2.55, 1.05, 1e15 + 0.5, 1e300, -2.5,
                                .infinity, -.infinity, .nan, .ulpOfOne, Double.greatestFiniteMagnitude, 0.049_999_999_999]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0 ..< 20_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            values.append(Double(seed >> 11) / Double(1 << 40))
            values.append(Double((seed >> 20) % 100_000) / 1000 + 0.05)
        }
        var disagreements: [String] = []
        for value in values where Seconds.oneDecimal(value) != String(format: "%.1f", value) {
            disagreements.append("\(value): \(Seconds.oneDecimal(value)) against \(String(format: "%.1f", value))")
        }
        #expect(disagreements.isEmpty, "\(disagreements.prefix(10))")
        #expect(Seconds.fixed(0.0049, places: 2) == String(format: "%.2f", 0.0049))
        #expect(Seconds.fixed(3, places: 0) == "3")
    }
    #endif

    // MARK: - The passport, without JSONSerialization

    static let passports: [String] = {
        var texts: [String] = []
        for format in ["1", "1.0", "1e0", "10e-1", "1.5", "-0", "-0.0", "0", "2", "-1", "9007199254740993",
                       "9223372036854775807", "9223372036854775808", "1e300", "1e400", "1e-400", "1e-320",
                       "0.1", "1.0000000000000002", "1.00000000000000001", "true", "false", "null", "\"1\"",
                       "[1]", "{}", "01", "+1", "NaN",
                       // What wave A's review measured moving under JSONDecoder,
                       // and the neighbours of each.
                       "1.00000000000000000000001", "0.99999999999999999999999", "2.00000000000000000001",
                       "1e0000000000000000000000", "9.223372036854776e18", "9223372036854775807.0",
                       "9223372036854775807e0", "92233720368547758070e-1", "-9223372036854775808", "1E0", "1.0e+0"] {
            texts.append(#"{"format": \#(format), "name": "x"}"#)
        }
        for name in ["\"\"", "\"   \"", "\"x\"", "\"\(String(repeating: "n", count: 64))\"",
                     "\"\(String(repeating: "n", count: 65))\"", "\"\(String(repeating: "ю", count: 64))\"",
                     #""e\u0301""#, #""\ud800""#, #""\ud83d\ude00""#, "5", "null", "true", #"["x"]"#] {
            texts.append(#"{"format": 1, "name": \#(name)}"#)
        }
        for description in ["null", "\"\"", "\"d\"", "5", "[]", "{}", "\"\(String(repeating: "d", count: 280))\"",
                            "\"\(String(repeating: "d", count: 281))\"", "true", "1e300"] {
            texts.append(#"{"format": 1, "name": "x", "description": \#(description)}"#)
        }
        texts += ["", " ", "not json", "[1]", "1", "\"x\"", "null", #"{"format":1,"name":"x",}"#,
                  #"{"format":1,"name":"x"} trailing"#, #"{"format":1,"name":"One","name":"Two"}"#,
                  #"{"format":2,"format":1,"name":"x"}"#, #"{"format":1,"name":"x","extra":{"deep":[1,{"a":null}]}}"#,
                  #"{"format":1,"name":"x","n":1e300}"#, "\t{\"format\":1,\"name\":\"x\"}\r\n",
                  #"{"format":1,"name":"x","list":[1,2,]}"#, #"{"format":1,"name":"x",,}"#, #"{"format":1,,"name":"x"}"#,
                  #"{"format":1,"name":"x","n":-1e400}"#]
        for depth in [511, 512, 513] {
            texts.append("{\"format\":1,\"name\":\"x\",\"deep\":" + String(repeating: "[", count: depth)
                         + String(repeating: "]", count: depth) + "}")
        }
        return texts
    }()

    /// Where the passport reads differently from uDeck before it, on purpose,
    /// and what it says now. `format` is read from the number as written, and
    /// only a whole number is one: JSONSerialization read the first two below
    /// through a `Double`, as 1 and as 0. The third and fourth `Double`
    /// cannot hold at all — 2^63 rounded up, which JSONSerialization clamped to
    /// `Int.max`, and a minus infinity it ignored in an unknown field. The last
    /// is 1 with an exponent of twenty-two zeros, which JSONSerialization
    /// refused as not JSON and is simply 1.
    static let moved: [String: Result<RepositoryPassport, RepositoryPassport.Problem>] = [
        #"{"format": 1.00000000000000001, "name": "x"}"#: .failure(.invalid("\"format\" must be a whole number")),
        #"{"format": 1e-400, "name": "x"}"#: .failure(.invalid("\"format\" must be a whole number")),
        #"{"format": 9.223372036854776e18, "name": "x"}"#: .failure(.invalid("\"format\" must be a whole number")),
        #"{"format":1,"name":"x","n":-1e400}"#: .failure(.missing),
        #"{"format": 1e0000000000000000000000, "name": "x"}"#: .success(RepositoryPassport(format: 1, name: "x")),
    ]

    @Test("a passport reads as before, pinned")
    func passportPinned() {
        func read(_ text: String) -> Result<RepositoryPassport, RepositoryPassport.Problem> {
            RepositoryPassport.read(Data(text.utf8))
        }
        #expect(read(#"{"format": 1.0, "name": "x"}"#) == .success(RepositoryPassport(format: 1, name: "x")))
        #expect(read(#"{"format": 1.5, "name": "x"}"#) == .failure(.invalid("\"format\" must be a whole number")))
        #expect(read(#"{"format": true, "name": "x"}"#) == .failure(.invalid("\"format\" must be a whole number")))
        #expect(read(#"{"format": -0, "name": "x"}"#) == .failure(.invalid("\"format\" must be 1 or more, got 0")))
        #expect(read(#"{"format": 9007199254740993, "name": "x"}"#)
                == .failure(.futureFormat(declared: 9_007_199_254_740_993)), "a whole number stays whole")
        #expect(read(#"{"format": 1, "name": "x", "description": null}"#) == .success(RepositoryPassport(format: 1, name: "x")))
        #expect(read("[1]") == .failure(.missing))
        // In UTF-16, with its byte order mark, as JSONSerialization read it too.
        let utf16 = Data([0xFF, 0xFE]) + Data(#"{"format":1,"name":"Юникод"}"#.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        #expect(RepositoryPassport.read(utf16) == .success(RepositoryPassport(format: 1, name: "Юникод")))
        // UTF-32 without a byte order mark, told by its zeros; with one, refused,
        // as JSONSerialization refused it.
        let utf32 = Data(#"{"format":1,"name":"x"}"#.unicodeScalars.flatMap { scalar in
            (0 ..< 4).map { UInt8(truncatingIfNeeded: scalar.value >> (8 * $0)) }
        })
        #expect(RepositoryPassport.read(utf32) == .success(RepositoryPassport(format: 1, name: "x")))
        #expect(RepositoryPassport.read(Data([0xFF, 0xFE, 0, 0]) + utf32) == .failure(.missing))

        // `format` is the number as written: a whole number, however it is
        // spelt, and nothing a Double merely rounds to one.
        let whole = RepositoryPassport(format: 1, name: "x")
        for format in ["1", "1.0", "1e0", "10e-1", "1.0e+0", "0.1e1", "1e0000000000000000000000"] {
            #expect(read(#"{"format": \#(format), "name": "x"}"#) == .success(whole), "\(format)")
        }
        let notWhole = RepositoryPassport.Problem.invalid("\"format\" must be a whole number")
        for format in ["1.00000000000000000000001", "0.99999999999999999999999", "1.00000000000000001",
                       "2.00000000000000000001", "1e-400", "9223372036854775808", "9.223372036854776e18", "1e300"] {
            #expect(read(#"{"format": \#(format), "name": "x"}"#) == .failure(notWhole), "\(format)")
        }
        // Near 2^63, where a Double's rounding changed which refusal it is:
        // the largest Int is a format from the future, one more is no whole
        // number an Int holds.
        for format in ["9223372036854775807", "9223372036854775807.0", "92233720368547758070e-1"] {
            #expect(read(#"{"format": \#(format), "name": "x"}"#) == .failure(.futureFormat(declared: Int.max)), "\(format)")
        }
        #expect(read(#"{"format": -9223372036854775808, "name": "x"}"#)
                == .failure(.invalid("\"format\" must be 1 or more, got \(Int.min)")))

        // As deep as JSONSerialization read — 513 containers, the passport
        // itself one of them — and no deeper.
        func nested(_ depth: Int) -> String {
            "{\"format\":1,\"name\":\"x\",\"deep\":" + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "}"
        }
        #expect(read(nested(512)) == .success(whole))
        #expect(read(nested(513)) == .failure(.missing))
        #expect(read(nested(30_000)) == .failure(.missing), "deep is refused, not a crash")
        // Deeper still is larger than a passport may be, and is not read at all.
        #expect(read(nested(100_000)) == .failure(.invalid(RepositoryPassport.tooLarge(nested(100_000).utf8.count))))

        // A comma before a closing bracket, which JSONSerialization allowed;
        // half a surrogate pair, which it did not.
        #expect(read(#"{"format":1,"name":"x","list":[1,2,],}"#) == .success(whole))
        #expect(read(#"{"format":1,"name":"\ud800"}"#) == .failure(.missing))
        // A field given twice counts the first time.
        #expect(read(#"{"format":2,"format":1,"name":"x"}"#) == .failure(.futureFormat(declared: 2)))
    }

    /// A number past what a `Double` holds. JSONSerialization refused `1e400`
    /// as not JSON and read `-1e400` as minus infinity; the passport's reader
    /// refuses both, as JSONDecoder does. A passport holding one is "not JSON"
    /// whatever the sign.
    @Test("a number past a Double's range is not JSON, whatever its sign")
    func hugeNumbersAreNotJSON() {
        for number in ["1e400", "-1e400", "-1e309"] {
            #expect(RepositoryPassport.read(Data(#"{"format": 1, "name": "x", "extra": \#(number)}"#.utf8)) == .failure(.missing))
        }
    }

    #if canImport(Darwin)
    /// `RepositoryPassport.read` as it was, with JSONSerialization and
    /// CoreFoundation's boolean test — the reference the new one is held to.
    static func readAsBefore(_ data: Data) -> Result<RepositoryPassport, RepositoryPassport.Problem> {
        guard let object = try? JSONSerialization.jsonObject(with: data), let fields = object as? [String: Any] else {
            return .failure(.missing)
        }
        func isBoolean(_ value: Any) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        guard let raw = fields["format"], !isBoolean(raw), let format = raw as? Int else {
            return .failure(.invalid("\"format\" must be a whole number"))
        }
        guard format >= 1 else { return .failure(.invalid("\"format\" must be 1 or more, got \(format)")) }
        guard format <= RepositoryPassport.supportedFormat else { return .failure(.futureFormat(declared: format)) }
        guard let name = fields["name"] as? String, (1...64).contains(name.count) else {
            return .failure(.invalid("\"name\" must be text of 1 to 64 characters"))
        }
        var description: String?
        if let value = fields["description"], !(value is NSNull) {
            guard let text = value as? String, text.count <= 280 else {
                return .failure(.invalid("\"description\" must be text of at most 280 characters"))
            }
            description = text
        }
        return .success(RepositoryPassport(format: format, name: name, description: description))
    }

    @Test("on a Mac, a passport reads exactly as it did with JSONSerialization")
    func passportMatchesJSONSerialization() {
        var inputs = Self.passports.map { Data($0.utf8) }
        let text = #"{"format": 1, "name": "Юникод"}"#
        inputs.append(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8))
        for encoding: String.Encoding in [.utf16, .utf16BigEndian, .utf16LittleEndian, .utf32, .utf32LittleEndian] {
            inputs.append(text.data(using: encoding)!)
        }
        inputs.append(Data(#"{"format":1,"name":"caf"#.utf8) + Data([0xE9]) + Data(#""}"#.utf8))
        inputs.append(Data(("{\"format\":1,\"name\":\"x\",\"deep\":" + String(repeating: "[", count: 600)
                            + String(repeating: "]", count: 600) + "}").utf8))
        for data in inputs {
            let text = String(decoding: data, as: UTF8.self)
            if let now = Self.moved[text] {
                #expect(RepositoryPassport.read(data) == now, "\(text.debugDescription)")
                #expect(Self.readAsBefore(data) != now, "\(text.debugDescription) did not move; take it off the list")
            } else {
                #expect(RepositoryPassport.read(data) == Self.readAsBefore(data),
                        "\(String(decoding: data.prefix(60), as: UTF8.self).debugDescription)")
            }
        }
        let compared = Set(inputs.map { String(decoding: $0, as: UTF8.self) })
        #expect(Self.moved.keys.allSatisfy(compared.contains), "every input that moved is compared")
        #expect(inputs.count > 80)
    }
    #endif

    // MARK: - Git's hashes, without FileHandle and String(format:)

    @Test("a file larger than one read hashes as its bytes do")
    func largeFileHashes() throws {
        let temp = TemporaryDirectory()
        // Three and a bit reads of 64 KiB, and not a multiple of anything.
        let bytes = Data((0 ..< (3 * 65_536 + 12_345)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let file = temp.url.appendingPathComponent("large.bin")
        try bytes.write(to: file)
        #expect(try GitHash.blob(ofFileAt: file) == GitHash.blob(bytes))
        let empty = temp.url.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(try GitHash.blob(ofFileAt: empty) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        #expect(throws: (any Error).self) { try GitHash.blob(ofFileAt: temp.url.appendingPathComponent("missing")) }
    }

    /// `attributesOfItem` gives an `NSNumber` on a Mac and a plain `UInt` where
    /// there is no `NSNumber`, and a size read as neither is every file's size
    /// being zero.
    @Test("a file's size and mode read as numbers, however Foundation boxes them")
    func attributeNumbers() {
        #expect(GitHash.integer(Int(5)) == 5)
        #expect(GitHash.integer(UInt(5)) == 5)
        #expect(GitHash.integer(UInt64(1) << 40) == 1 << 40)
        #expect(GitHash.integer(UInt16(0o755)) == 0o755)
        #expect(GitHash.integer(NSNumber(value: 0o644)) == 0o644)
        #expect(GitHash.integer(UInt.max) == nil, "past Int is no size")
        #expect(GitHash.integer(nil) == nil)
        #expect(GitHash.integer("five") == nil)
    }

    // MARK: - Listing a plugins folder

    @Test("a dot-folder and a link to a folder are not plugins")
    func hiddenAndLinkedFolders() throws {
        let temp = TemporaryDirectory()
        let manifest = #"{ "id": "real", "name": "Real", "version": "1.0.0", "api": 1, "kind": "poll", "run": ["./run.sh"], "interval": 5, "timeout": 2 }"#
        temp.writePlugin(folder: "real", manifest: manifest,
                         script: (name: "run.sh", body: "#!/bin/sh\n", executable: true))
        temp.writePlugin(folder: ".hidden", manifest: manifest)
        try FileManager.default.createSymbolicLink(at: temp.plugins.appendingPathComponent("linked"),
                                                   withDestinationURL: temp.plugins.appendingPathComponent("real"))
        try Data("not a folder".utf8).write(to: temp.plugins.appendingPathComponent("stray"))
        let found = PluginDiscovery(searchPath: []).scan(temp.plugins)
        #expect(found.map(\.folderName) == ["real"])
    }

    #if canImport(Darwin)
    /// A Mac hides a folder by a flag as well as by a dot, and discovery has
    /// always skipped both.
    @Test("on a Mac, a folder flagged hidden is skipped, as it always was")
    func flaggedFolderIsHidden() throws {
        let temp = TemporaryDirectory()
        temp.writePlugin(folder: "flagged", manifest: "{}")
        var folder = temp.plugins.appendingPathComponent("flagged")
        var values = URLResourceValues()
        values.isHidden = true
        try folder.setResourceValues(values)
        #expect(PluginDiscovery(searchPath: []).scan(temp.plugins).isEmpty)
    }
    #endif
}
