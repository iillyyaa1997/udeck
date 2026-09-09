import Foundation

/// A value a plugin setting can hold.
///
/// Deliberately small. A plugin that needs richer configuration should read a
/// file of its own; the point of declared settings is that the host can render
/// a real settings screen for them without the plugin shipping any UI.
public enum SettingValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)

    /// How the value reaches the plugin: as JSON, in an environment variable.
    /// JSON rather than a bare string so that a plugin can tell `false` from
    /// `"false"` and `12` from `"12"` without guessing.
    public var jsonLiteral: String {
        switch self {
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .string(let value):
            String(data: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        }
    }

    public var typeName: String {
        switch self {
        case .bool: "bool"
        case .int: "int"
        case .string: "string"
        }
    }
}

extension SettingValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath,
                  debugDescription: "a setting value must be a boolean, an integer or a string")
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// One choice in an `enum` setting.
public struct SettingOption: Codable, Equatable, Sendable {
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// A setting a plugin declares so the host can render it.
public struct SettingDeclaration: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bool
        case int
        case string
        case enumeration = "enum"
    }

    public var key: String
    public var type: Kind
    public var label: String
    public var help: String?
    public var defaultValue: SettingValue
    public var minimum: Int?
    public var maximum: Int?
    public var options: [SettingOption]?

    private enum CodingKeys: String, CodingKey {
        case key, type, label, help
        case defaultValue = "default"
        case minimum = "min"
        case maximum = "max"
        case options
    }

    public init(
        key: String,
        type: Kind,
        label: String,
        help: String? = nil,
        defaultValue: SettingValue,
        minimum: Int? = nil,
        maximum: Int? = nil,
        options: [SettingOption]? = nil
    ) {
        self.key = key
        self.type = type
        self.label = label
        self.help = help
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
        self.options = options
    }

    /// Why this declaration cannot be rendered, if it cannot.
    public var problem: String? {
        if key.range(of: "^[a-z0-9][a-z0-9_]*$", options: .regularExpression) == nil {
            return "key must be lowercase letters, digits and underscores"
        }
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "label must not be blank"
        }
        switch (type, defaultValue) {
        case (.bool, .bool), (.int, .int), (.string, .string):
            break
        case (.enumeration, .string(let value)):
            guard let options, !options.isEmpty else {
                return "an enum setting must list its options"
            }
            guard options.contains(where: { $0.value == value }) else {
                return "the default \"\(value)\" is not one of the declared options"
            }
        default:
            return "declared type is \(type.rawValue) but the default is a \(defaultValue.typeName)"
        }
        if let minimum, let maximum, minimum > maximum {
            return "min (\(minimum)) is greater than max (\(maximum))"
        }
        if case .int(let value) = defaultValue {
            if let minimum, value < minimum { return "the default \(value) is below min \(minimum)" }
            if let maximum, value > maximum { return "the default \(value) is above max \(maximum)" }
        }
        return nil
    }

    /// How wide an `int` setting's range is allowed to be when the manifest
    /// gives only one end of it.
    public static let defaultIntegerSpan = 1000

    /// A range that is always legal, whatever the manifest declared.
    ///
    /// The bounds are a plugin author's, so they cannot be assumed to be
    /// ordered or even both present. A `min` with no `max` used to produce a
    /// reversed range, and a reversed range is a fatal error in SwiftUI's
    /// `Stepper` rather than an empty one — a valid manifest could crash the
    /// settings screen.
    public var editingRange: ClosedRange<Int> {
        let lower = minimum ?? 0
        // Saturating, not wrapping and not trapping. A declared minimum of
        // `Int.max` with no maximum is a legal manifest — nothing rejects it —
        // and adding the span to it overflowed, which is a trap in Swift and
        // took the settings window with it the moment the plugin was expanded.
        let upper: Int
        if let maximum {
            upper = maximum
        } else {
            let (sum, overflowed) = lower.addingReportingOverflow(Self.defaultIntegerSpan)
            upper = overflowed ? Int.max : sum
        }
        return lower ... max(lower, upper)
    }

    /// Brings a stored value back into the declared range, or falls back to the
    /// default when it cannot. Used when loading a settings file that a previous
    /// version of the plugin wrote against different bounds.
    public func coerce(_ value: SettingValue) -> SettingValue {
        switch (type, value) {
        case (.bool, .bool):
            return value
        case (.int, .int(let raw)):
            var clamped = raw
            if let minimum { clamped = max(clamped, minimum) }
            if let maximum { clamped = min(clamped, maximum) }
            return .int(clamped)
        case (.string, .string):
            return value
        case (.enumeration, .string(let raw)):
            guard let options, options.contains(where: { $0.value == raw }) else { return defaultValue }
            return value
        default:
            return defaultValue
        }
    }
}
