import Foundation

/// A coding key that can be any string, so a row's single key can be read
/// without knowing it in advance.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(_ value: String) { self.stringValue = value }
}

extension KeyValueRow: Codable {
    /// `["label", "value"]`, optionally with a third element naming a state:
    /// `["label", "value", "warn"]`.
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let label = try container.decode(String.self)
        let value = try container.decode(String.self)
        var state: CardState?
        if !container.isAtEnd {
            let raw = try container.decode(String.self)
            guard let parsed = CardState(rawValue: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: container.codingPath,
                          debugDescription: "\"\(raw)\" is not a card state; expected one of \(CardState.allCases.map(\.rawValue).joined(separator: ", "))")
                )
            }
            state = parsed
        }
        self.init(label: label, value: value, state: state)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(label)
        try container.encode(value)
        if let state { try container.encode(state.rawValue) }
    }
}

extension SparkRow: Codable {
    private enum CodingKeys: String, CodingKey { case values, caption }

    /// Either a bare array of numbers, or an object with `values` and an
    /// optional `caption`. Both forms are part of the contract; the bare array
    /// exists because a spark usually has nothing to say beyond its numbers.
    public init(from decoder: any Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            var values: [Double] = []
            while !unkeyed.isAtEnd { values.append(try unkeyed.decode(Double.self)) }
            self.init(values: values)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            values: try c.decode([Double].self, forKey: .values),
            caption: try c.decodeIfPresent(String.self, forKey: .caption)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        if caption == nil {
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(values, forKey: .values)
        try c.encode(caption, forKey: .caption)
    }
}

extension CardRow: Codable {
    /// Every row is an object with exactly one key naming its type.
    ///
    /// Exactly one, not "at least one": a row carrying both `kv` and `meter` is
    /// an author mistake with no correct interpretation, and guessing at it
    /// would hide the mistake until it produced a wrong card.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let keys = container.allKeys
        guard keys.count == 1, let key = keys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: keys.isEmpty
                        ? "a row must name its type, e.g. {\"text\": \"…\"}"
                        : "a row must have exactly one key, found \(keys.count): \(keys.map(\.stringValue).sorted().joined(separator: ", "))")
            )
        }

        switch key.stringValue {
        case "text": self = .text(try container.decode(String.self, forKey: key))
        case "kv": self = .keyValue(try container.decode(KeyValueRow.self, forKey: key))
        case "meter": self = .meter(try container.decode(MeterRow.self, forKey: key))
        case "list": self = .list(try container.decode([ListItem].self, forKey: key))
        case "spark": self = .spark(try container.decode(SparkRow.self, forKey: key))
        case "table": self = .table(try container.decode(CardTable.self, forKey: key))
        case "log": self = .log(try container.decode([String].self, forKey: key))
        case "canvas": self = .canvas(try container.decode(CanvasRow.self, forKey: key))
        default: self = .unsupported(kind: key.stringValue)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        switch self {
        case .text(let value): try container.encode(value, forKey: AnyCodingKey("text"))
        case .keyValue(let value): try container.encode(value, forKey: AnyCodingKey("kv"))
        case .meter(let value): try container.encode(value, forKey: AnyCodingKey("meter"))
        case .list(let value): try container.encode(value, forKey: AnyCodingKey("list"))
        case .spark(let value): try container.encode(value, forKey: AnyCodingKey("spark"))
        case .table(let value): try container.encode(value, forKey: AnyCodingKey("table"))
        case .log(let value): try container.encode(value, forKey: AnyCodingKey("log"))
        case .canvas(let value): try container.encode(value, forKey: AnyCodingKey("canvas"))
        case .unsupported(let kind):
            // Round-tripping an unsupported row would fabricate a body this
            // build never understood. Encode the marker instead, honestly.
            try container.encode("row type \"\(kind)\" is not supported by this version",
                                 forKey: AnyCodingKey("text"))
        }
    }
}

extension Card: Codable {
    private enum CodingKeys: String, CodingKey { case state, title, chip, rows, actions, ttl }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            state: try c.decodeIfPresent(CardState.self, forKey: .state) ?? .ok,
            title: try c.decodeIfPresent(String.self, forKey: .title),
            chip: try c.decodeIfPresent(String.self, forKey: .chip),
            rows: try c.decodeIfPresent([CardRow].self, forKey: .rows) ?? [],
            actions: try c.decodeIfPresent([CardAction].self, forKey: .actions) ?? [],
            ttl: try c.decodeIfPresent(TimeInterval.self, forKey: .ttl)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(chip, forKey: .chip)
        try c.encode(rows, forKey: .rows)
        if !actions.isEmpty { try c.encode(actions, forKey: .actions) }
        try c.encodeIfPresent(ttl, forKey: .ttl)
    }
}
