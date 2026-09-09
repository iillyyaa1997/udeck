import Foundation

/// A language uDeck speaks.
///
/// Adding one is a file and two lines: write a `Vocabulary` — the compiler will
/// not let you leave a phrase out — add a case here, and name it in `vocabulary`
/// below. Nothing else in the application has to be touched, because nothing
/// else in the application contains a sentence.
public enum Language: String, Codable, CaseIterable, Sendable, Identifiable {
    case english = "en"
    case russian = "ru"

    public var id: String { rawValue }

    /// The language's name in itself.
    ///
    /// A language list written in the language the reader is currently stuck in
    /// is no use to the person who needs to leave it: somebody who has landed in
    /// Russian by accident is looking for the word "English", not for
    /// "Английский".
    public var endonym: String {
        switch self {
        case .english: "English"
        case .russian: "Русский"
        }
    }

    public var vocabulary: any Vocabulary {
        switch self {
        case .english: English()
        case .russian: Russian()
        }
    }

    /// The first language in the reader's own order of preference that uDeck
    /// actually speaks, or English.
    ///
    /// Matched on the language subtag alone, so `ru-RU` and `ru` both land on
    /// Russian. macOS hands over a list rather than one answer, and honouring
    /// the order is the difference between a Russian speaker whose second
    /// choice is German getting Russian rather than English.
    public static func preferred(
        from identifiers: [String] = Locale.preferredLanguages
    ) -> Language {
        for identifier in identifiers {
            let subtag = identifier.split(separator: "-").first.map(String.init)?.lowercased()
            if let subtag, let match = Language(rawValue: subtag) { return match }
        }
        return .english
    }
}

/// Everything uDeck says, in one language.
///
/// A protocol with a single requirement rather than a dictionary, so that the
/// compiler is the thing that checks a translation is complete: a `switch` over
/// `Phrase` that misses a case does not build. A dictionary would have shipped
/// the missing keys and shown them to the operator as their own names.
public protocol Vocabulary: Sendable {
    func callAsFunction(_ phrase: Phrase) -> String
}

/// The vocabulary in force, ready to be called.
///
/// Written so that a view says `strings(.actionSave)` — the phrase is named at
/// the point it is used and the language is not, which is the property that
/// makes a second language cost nothing at the call site.
public struct Strings: Sendable {
    public let language: Language
    private let vocabulary: any Vocabulary

    public init(_ language: Language) {
        self.language = language
        self.vocabulary = language.vocabulary
    }

    public func callAsFunction(_ phrase: Phrase) -> String {
        vocabulary(phrase)
    }
}
