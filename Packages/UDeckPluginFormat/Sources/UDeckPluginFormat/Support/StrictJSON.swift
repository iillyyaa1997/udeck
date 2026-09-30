/// JSON read the strict way, with nothing but the standard library.
///
/// `JSONDecoder` answers what a manifest *means* to uDeck, and uDeck keeps
/// using it. It cannot answer what the repository check has to know about the
/// text itself: that a field is given twice (a reviewer reads one of the two
/// values, and which one a decoder keeps is nobody's promise — Apple's keep the
/// first, Python's the last), that the file opens with a byte order mark, or how
/// a number was *written* — `4.0` where a whole number belongs, or `format`
/// written as `1.00000000000000000000001`, which a `Double` rounds to 1.
///
/// So this reads UTF-8 bytes into values that keep every member of an object in
/// the order written, repeats included, and every number as its literal.
/// RFC 8259 and nothing more: no byte order mark, no `NaN` or `Infinity`, no
/// control characters inside strings, no number a `Double` cannot hold.
enum StrictJSON {
    indirect enum Value: Equatable, Sendable {
        case null
        case bool(Bool)
        case number(Number)
        case string(String)
        case array([Value])
        case object(Object)
    }

    struct Number: Equatable, Sendable {
        /// Exactly as written.
        var literal: String
        /// No fraction and no exponent: `3`, not `3.0` or `3e0`.
        var isIntegerLiteral: Bool
        /// The value, which a `Double` holds without becoming infinite.
        var double: Double
        /// The exact value when it is a whole number that fits in an `Int`:
        /// `1`, `1.0` and `10e-1` are 1; `1.00000000000000000000001` is no
        /// whole number at all, however a `Double` rounds it.
        var wholeValue: Int?
    }

    struct Member: Equatable, Sendable {
        var key: String
        var value: Value
    }

    struct Object: Equatable, Sendable {
        /// Every member in the order written, a repeated key as often as it
        /// was written.
        let members: [Member]
        /// Where each key was given first and last, so that asking for a
        /// field costs the same in an object of three members as in one of
        /// three hundred thousand — a check that asks for every key of a
        /// translation asks as often as there are keys.
        private let positions: [String: Positions]
        /// Each key once, in the order it first appears.
        let keys: [String]

        private struct Positions: Equatable, Sendable {
            var first: Int
            var last: Int
        }

        init(members: [Member]) {
            var positions: [String: Positions] = [:]
            positions.reserveCapacity(members.count)
            var keys: [String] = []
            for (index, member) in members.enumerated() {
                if positions[member.key] != nil {
                    positions[member.key]?.last = index
                } else {
                    positions[member.key] = Positions(first: index, last: index)
                    keys.append(member.key)
                }
            }
            self.members = members
            self.positions = positions
            self.keys = keys
        }

        /// The value given first — what Apple's readers keep.
        func first(_ key: String) -> Value? { positions[key].map { members[$0.first].value } }
        /// The value given last — what Python's reader keeps.
        func last(_ key: String) -> Value? { positions[key].map { members[$0.last].value } }
    }

    /// What reading gave: the value, or nil when the bytes are not JSON, and
    /// every problem found, in words that follow a file's name.
    struct Document: Sendable {
        var value: Value?
        var problems: [String]
    }

    /// Apple's `JSONDecoder` reads 512 containers deep and no deeper.
    static let decoderDepth = 512

    /// Reads `bytes` as JSON. `trailingCommas` accepts `[1,]` and `{"a":1,}`,
    /// as `JSONSerialization` does — only for reading the way uDeck always has.
    static func parse(_ bytes: [UInt8], maximumDepth: Int = decoderDepth, trailingCommas: Bool = false) -> Document {
        if let bad = firstInvalidUTF8(bytes) {
            return Document(value: nil, problems: ["is not UTF-8 (byte \(bad) cannot be read)"])
        }
        var reader = Reader(bytes: bytes, maximumDepth: maximumDepth, trailingCommas: trailingCommas)
        do {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { throw reader.failure("starts with a byte order mark") }
            reader.skipSpace()
            let value = try reader.value()
            reader.skipSpace()
            guard reader.index == bytes.count else { throw reader.failure("has more after the value") }
            return Document(value: value, problems: reader.repeated.map { "gives the field \"\($0)\" more than once" })
        } catch {
            return Document(value: nil, problems: ["is not valid JSON: \(error)"])
        }
    }

    /// Where the first byte that does not belong to UTF-8 is, or nil when there
    /// is none. Strict, as the standard library is: no overlong forms, no
    /// surrogates.
    static func firstInvalidUTF8(_ bytes: [UInt8]) -> Int? {
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        var position = 0
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): position += UTF8.width(scalar)
            case .emptyInput: return nil
            case .error: return position
            }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private struct Reader {
        let bytes: [UInt8]
        let maximumDepth: Int
        let trailingCommas: Bool
        var index = 0
        var repeated: [String] = []
        var reported = Set<String>()

        init(bytes: [UInt8], maximumDepth: Int, trailingCommas: Bool) {
            self.bytes = bytes
            self.maximumDepth = maximumDepth
            self.trailingCommas = trailingCommas
        }

        func failure(_ what: String) -> Failure {
            let before = bytes[..<min(index, bytes.count)]
            let line = before.filter { $0 == 0x0A }.count + 1
            let column = before.count - (before.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0) + 1
            return Failure(description: "\(what), at line \(line), column \(column)")
        }

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipSpace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
        }

        mutating func expect(_ word: String) throws -> Void {
            let expected = Array(word.utf8)
            guard bytes[index...].starts(with: expected) else { throw failure("expected a value") }
            index += expected.count
        }

        /// A container being read: where its items, or its members, start on
        /// the stack they share with every container around it — and for an
        /// object, the key of the member whose value comes next.
        private enum Open {
            case array(from: Int)
            case object(from: Int, key: String)
        }

        /// The value at `index`, containers and all. Iterative, with the open
        /// containers on a stack of its own: a file nested a thousand deep must
        /// cost a thousand stack entries, not a thousand stack frames of a
        /// thread with half a megabyte of them.
        ///
        /// And linear. The items of every open array wait on one stack, the
        /// members of every open object on another, each appended in place;
        /// a container is built once, when it closes, from the top of its
        /// stack. A container held in the stack entry that is being changed —
        /// taken out, added to, put back — is copied whole on every addition
        /// while a second reference to it lives, and a passport of 256,000
        /// fields took over two minutes that way.
        mutating func value() throws -> Value {
            var open: [Open] = []
            var items: [Value] = []
            var members: [Member] = []
            // The keys seen so far in each open object, innermost last.
            var seen: [Set<String>] = []
            while true {
                skipSpace()
                var done: Value
                switch current {
                case UInt8(ascii: "{")?, UInt8(ascii: "[")?:
                    guard open.count < maximumDepth else { throw failure("nested more than \(maximumDepth) deep") }
                    let isObject = current == UInt8(ascii: "{")
                    index += 1
                    skipSpace()
                    if current == (isObject ? UInt8(ascii: "}") : UInt8(ascii: "]")) {
                        index += 1
                        done = isObject ? .object(Object(members: [])) : .array([])
                    } else if isObject {
                        open.append(.object(from: members.count, key: try key()))
                        seen.append([])
                        continue
                    } else {
                        open.append(.array(from: items.count))
                        continue
                    }
                case UInt8(ascii: "\"")?: done = .string(try string())
                case UInt8(ascii: "t")?: try expect("true"); done = .bool(true)
                case UInt8(ascii: "f")?: try expect("false"); done = .bool(false)
                case UInt8(ascii: "n")?: try expect("null"); done = .null
                case let byte? where byte == UInt8(ascii: "-") || (0x30 ... 0x39).contains(byte):
                    done = .number(try number())
                default: throw failure("expected a value")
                }
                // Hand the value to the container it belongs to, closing every
                // container that ends with it.
                closing: while let top = open.last {
                    skipSpace()
                    switch top {
                    case .array(let start):
                        items.append(done)
                        if current == UInt8(ascii: ",") {
                            index += 1
                            skipSpace()
                            if !(trailingCommas && current == UInt8(ascii: "]")) { break closing }
                        }
                        guard current == UInt8(ascii: "]") else { throw failure("expected \",\" or \"]\"") }
                        index += 1
                        done = .array(Array(items[start...]))
                        items.removeSubrange(start...)
                        open.removeLast()
                    case .object(let start, let key):
                        if !seen[seen.count - 1].insert(key).inserted, reported.insert(key).inserted { repeated.append(key) }
                        members.append(Member(key: key, value: done))
                        if current == UInt8(ascii: ",") {
                            index += 1
                            skipSpace()
                            if !(trailingCommas && current == UInt8(ascii: "}")) {
                                open[open.count - 1] = .object(from: start, key: try self.key())
                                break closing
                            }
                        }
                        guard current == UInt8(ascii: "}") else { throw failure("expected \",\" or \"}\"") }
                        index += 1
                        done = .object(Object(members: Array(members[start...])))
                        members.removeSubrange(start...)
                        seen.removeLast()
                        open.removeLast()
                    }
                }
                if open.isEmpty { return done }
            }
        }

        /// A member's name and the colon after it.
        mutating func key() throws -> String {
            guard current == UInt8(ascii: "\"") else { throw failure("expected a field name in quotes") }
            let key = try string()
            skipSpace()
            guard current == UInt8(ascii: ":") else { throw failure("expected \":\" after a field name") }
            index += 1
            return key
        }

        mutating func string() throws -> String {
            index += 1
            var out: [UInt8] = []
            while let byte = current {
                index += 1
                switch byte {
                case UInt8(ascii: "\""): return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard let escaped = current else { break }
                    index += 1
                    switch escaped {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escaped)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        // A pair of escapes is one character beyond the first
                        // plane. Half a pair is no character at all, and
                        // neither of Apple's readers takes one.
                        if (0xD800 ... 0xDBFF).contains(code), bytes[index...].starts(with: Array("\\u".utf8)) {
                            index += 2
                            let low = try hex4()
                            guard (0xDC00 ... 0xDFFF).contains(low) else { throw failure("half a surrogate pair") }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw failure("half a surrogate pair") }
                        out.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default:
                        index -= 1
                        throw failure("\\\(Character(Unicode.Scalar(escaped))) is not an escape")
                    }
                case 0x00 ..< 0x20:
                    index -= 1
                    throw failure("a control character inside a string")
                default: out.append(byte)
                }
            }
            throw failure("a string that does not end")
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw failure("\\u needs four hexadecimal digits") }
            var code: UInt32 = 0
            for byte in bytes[index ..< index + 4] {
                guard let digit = Self.hexDigit(byte) else { throw failure("\\u needs four hexadecimal digits") }
                code = code << 4 | digit
            }
            index += 4
            return code
        }

        static func hexDigit(_ byte: UInt8) -> UInt32? {
            switch byte {
            case 0x30 ... 0x39: UInt32(byte - 0x30)
            case 0x41 ... 0x46: UInt32(byte - 0x37)
            case 0x61 ... 0x66: UInt32(byte - 0x57)
            default: nil
            }
        }

        mutating func digits() -> ArraySlice<UInt8> {
            let start = index
            while let byte = current, (0x30 ... 0x39).contains(byte) { index += 1 }
            return bytes[start ..< index]
        }

        mutating func number() throws -> Number {
            let start = index
            let negative = current == UInt8(ascii: "-")
            if negative { index += 1 }
            let whole = digits()
            guard !whole.isEmpty else { throw failure("expected a digit") }
            guard whole.count == 1 || whole.first != UInt8(ascii: "0") else { throw failure("a number with a leading zero") }
            var fraction: ArraySlice<UInt8> = []
            if current == UInt8(ascii: ".") {
                index += 1
                fraction = digits()
                guard !fraction.isEmpty else { throw failure("expected a digit after \".\"") }
            }
            var exponent = 0
            var hasExponent = false
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                hasExponent = true
                index += 1
                let sign: Int = current == UInt8(ascii: "-") ? -1 : 1
                if current == UInt8(ascii: "-") || current == UInt8(ascii: "+") { index += 1 }
                let written = digits()
                guard !written.isEmpty else { throw failure("expected a digit in the exponent") }
                // Past a million the answer no longer changes: nothing that
                // large or that small is a whole number an `Int` holds.
                exponent = sign * written.reduce(0) { min($0 * 10 + Int($1 - 0x30), 1_000_000) }
            }
            let literal = String(decoding: bytes[start ..< index], as: UTF8.self)
            guard let double = Double(literal), double.isFinite else {
                throw failure("\(literal) is too large a number to read")
            }
            return Number(literal: literal, isIntegerLiteral: fraction.isEmpty && !hasExponent, double: double,
                          wholeValue: Self.whole(negative: negative, digits: Array(whole + fraction),
                                                 scale: exponent - fraction.count))
        }

        /// `digits × 10^scale` exactly, when that is a whole number inside `Int`.
        static func whole(negative: Bool, digits: [UInt8], scale: Int) -> Int? {
            var digits = digits.drop { $0 == 0x30 }
            guard !digits.isEmpty else { return 0 }
            var scale = scale
            while digits.last == 0x30 { digits.removeLast(); scale += 1 }
            guard scale >= 0, digits.count + scale <= 19 else { return nil }
            var magnitude: UInt64 = 0
            for digit in digits + Array(repeating: 0x30, count: scale) {
                let (times, overflow) = magnitude.multipliedReportingOverflow(by: 10)
                let (sum, carry) = times.addingReportingOverflow(UInt64(digit - 0x30))
                guard !overflow, !carry else { return nil }
                magnitude = sum
            }
            if negative { return magnitude <= UInt64(Int.max) + 1 ? Int(truncatingIfNeeded: 0 &- magnitude) : nil }
            return magnitude <= UInt64(Int.max) ? Int(magnitude) : nil
        }
    }
}

extension StrictJSON.Value {
    var object: StrictJSON.Object? { if case .object(let object) = self { object } else { nil } }
    var string: String? { if case .string(let text) = self { text } else { nil } }
    var array: [StrictJSON.Value]? { if case .array(let items) = self { items } else { nil } }
    var number: StrictJSON.Number? { if case .number(let number) = self { number } else { nil } }
    var isNull: Bool { self == .null }
}

extension StrictJSON {
    /// JSON text in whichever Unicode encoding it came in, as UTF-8 — what
    /// `JSONSerialization` accepted, measured on macOS 27: a byte order mark
    /// for UTF-8 or UTF-16, or without one the pattern of zero bytes the first
    /// characters leave (RFC 4627, section 3), which is how it tells UTF-32.
    /// UTF-32 with a byte order mark it refused, and so does this: the mark
    /// reads as UTF-16's, and the text after it starts with a zero. Nil when
    /// the bytes are not the encoding they look like.
    ///
    /// Only for reading the way uDeck always has. The repository check reads
    /// UTF-8 and nothing else (`parse`).
    static func utf8(fromAnyUnicode bytes: [UInt8]) -> [UInt8]? {
        func has(_ prefix: [UInt8]) -> Bool { bytes.starts(with: prefix) }
        let zero = bytes.prefix(4).map { $0 == 0 }
        if has([0xEF, 0xBB, 0xBF]) { return Array(bytes.dropFirst(3)) }
        if has([0xFE, 0xFF]) { return transcode(bytes.dropFirst(2), unit: 2, bigEndian: true) }
        if has([0xFF, 0xFE]) { return transcode(bytes.dropFirst(2), unit: 2, bigEndian: false) }
        if zero.count == 4 {
            if zero == [true, true, true, false] { return transcode(bytes[...], unit: 4, bigEndian: true) }
            if zero == [false, true, true, true] { return transcode(bytes[...], unit: 4, bigEndian: false) }
        }
        if zero.count >= 2 {
            if zero[0], !zero[1] { return transcode(bytes[...], unit: 2, bigEndian: true) }
            if !zero[0], zero[1] { return transcode(bytes[...], unit: 2, bigEndian: false) }
        }
        return bytes
    }

    private static func transcode(_ bytes: ArraySlice<UInt8>, unit: Int, bigEndian: Bool) -> [UInt8]? {
        guard bytes.count % unit == 0 else { return nil }
        let start = bytes.startIndex
        var units: [UInt32] = []
        units.reserveCapacity(bytes.count / unit)
        for offset in stride(from: 0, to: bytes.count, by: unit) {
            var value: UInt32 = 0
            for index in 0 ..< unit {
                let byte = UInt32(bytes[start + offset + (bigEndian ? index : unit - 1 - index)])
                value = value << 8 | byte
            }
            units.append(value)
        }
        var out: [UInt8] = []
        let failed = unit == 2
            ? Swift.transcode(units.map { UInt16($0) }.makeIterator(), from: UTF16.self, to: UTF8.self,
                              stoppingOnError: true) { out.append($0) }
            : Swift.transcode(units.makeIterator(), from: UTF32.self, to: UTF8.self,
                              stoppingOnError: true) { out.append($0) }
        return failed ? nil : out
    }
}
