import Foundation
import UDeckPluginFormat

/// What a field's suggestions do with what is typed (`InputRow.suggest`,
/// 0.9.25): when typing opens them, what they show for a query, and what
/// picking one does to the text. Kept apart from the views, to be tested.
public enum Suggestions {
    /// A trigger typed before the caret: the tabs it opens, what was typed
    /// after it, and the range — the trigger and the query — that a pick
    /// replaces.
    public struct Token: Equatable, Sendable {
        public var trigger: String
        public var tabs: [String]
        public var query: String
        /// In UTF-16 units, as a text view counts.
        public var range: NSRange
    }

    /// The trigger the caret stands after, if any: «/co» at the start of the
    /// text for a tab that is `start`, «@grid» after a space anywhere for one
    /// that is not. Nothing once a space is typed after it.
    public static func token(in text: String, caret: Int, tabs: [SuggestTab]) -> Token? {
        let string = text as NSString
        guard caret >= 0, caret <= string.length else { return nil }
        let before = string.substring(to: caret)
        var found: Token?
        for trigger in Set(tabs.compactMap(\.trigger).filter { !$0.isEmpty }) {
            let opened = tabs.filter { $0.trigger == trigger }
            let startOnly = opened.allSatisfy { $0.start == true }
            // The word the caret ends: from the last whitespace before it.
            let wordStart = (before.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards)?.upperBound)
                .map { before.distance(from: before.startIndex, to: $0) } ?? 0
            let word = String(before.dropFirst(wordStart))
            guard word.hasPrefix(trigger) else { continue }
            if startOnly, !before.prefix(wordStart).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let location = (String(before.prefix(wordStart)) as NSString).length
            let query = String(word.dropFirst(trigger.count))
            let token = Token(trigger: trigger, tabs: opened.map(\.id), query: query,
                              range: NSRange(location: location, length: caret - location))
            // The longer trigger wins where one is the start of another.
            if found == nil || trigger.count > found!.trigger.count { found = token }
        }
        return found
    }

    /// The items for a query, best first: those whose name starts with it,
    /// then those with a word that does, then those whose name has it, then
    /// those whose line about them has it. Case and the trigger are ignored.
    /// The same rank keeps the plugin's order.
    public static func rank(_ items: [SuggestItem], query: String, triggers: [String] = []) -> [SuggestItem] {
        let wanted = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return items }
        func bare(_ text: String) -> String {
            var text = text.lowercased()
            for trigger in triggers where text.hasPrefix(trigger) { text = String(text.dropFirst(trigger.count)) }
            return text
        }
        var scored: [(score: Int, index: Int, item: SuggestItem)] = []
        for (index, item) in items.enumerated() {
            let names = [bare(item.title ?? item.text), bare(item.text)]
            let score: Int
            if names.contains(where: { $0.hasPrefix(wanted) }) {
                score = 0
            } else if names.contains(where: { name in
                name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(wanted) }
            }) {
                score = 1
            } else if names.contains(where: { $0.contains(wanted) }) {
                score = 2
            } else if item.detail?.lowercased().contains(wanted) == true {
                score = 3
            } else {
                continue
            }
            scored.append((score, index, item))
        }
        return scored.sorted { ($0.score, $0.index) < ($1.score, $1.index) }.map(\.item)
    }

    /// The text after a pick, and where the caret goes: the item's text and a
    /// space in place of the token; with no token, at the caret — or at the
    /// start, before what is there, for a tab whose trigger counts only there.
    public static func insert(_ item: SuggestItem, into text: String, caret: Int, token: Token?,
                              atStart: Bool) -> (text: String, caret: Int)
    {
        let string = text as NSString
        let piece = item.text + " "
        if let token, token.range.location + token.range.length <= string.length {
            // No second space where one follows already.
            let end = token.range.location + token.range.length
            let spaced = end < string.length
                && string.substring(with: NSRange(location: end, length: 1)).rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            let piece = spaced ? item.text : piece
            let after = string.replacingCharacters(in: token.range, with: piece)
            return (after, token.range.location + (piece as NSString).length)
        }
        if atStart {
            let rest = text.trimmingCharacters(in: .whitespaces)
            return (piece + rest, (piece as NSString).length)
        }
        let at = max(0, min(caret, string.length))
        let needsSpace = at > 0 && !(string.substring(with: NSRange(location: at - 1, length: 1))
            .rangeOfCharacter(from: .whitespacesAndNewlines) != nil)
        let inserted = (needsSpace ? " " : "") + piece
        return (string.replacingCharacters(in: NSRange(location: at, length: 0), with: inserted),
                at + (inserted as NSString).length)
    }
}
