import Foundation

/// What an agent does right now, for the line above the field — as the
/// terminal's «✻ Crafting… (18m 43s · ↓ 87.2k tokens)» (the operator's «1»,
/// 11-26: the card said «Working» for an hour while nothing happened).
public enum AgentActivity: Sendable, Equatable {
    /// A call to the model sent, nothing back yet.
    case requesting
    case thinking
    case writing
    /// The model writes a call of this tool.
    case preparing(String)
    /// This tool runs.
    case tool(String)
    /// It waits for the person's answer.
    case asking
    /// The conversation is summed up to free its context: `/compact`, or the
    /// CLI's own when it fills (`status: compacting`, claude 2.1.332).
    case compacting
    /// The call failed and is tried again: why — an HTTP status, an error's
    /// name — which attempt, and when the next one goes.
    case retrying(status: Int?, error: String, attempt: Int, next: Date?)
}

/// The tokens that came back in a turn: the model's own count at the end of
/// each call, and between, an estimate from the text that streamed in.
public struct TurnTokens: Sendable, Equatable {
    public var counted = 0
    public var streamedCharacters = 0
    /// Thinking the CLI estimated as it went: it streams no thinking text,
    /// only its size (`thinking_tokens`, claude 2.1.332).
    public var thought = 0

    public init() {}

    /// About four characters a token.
    public var total: Int { counted + streamedCharacters / 4 + thought }
    /// Part of `total` is an estimate.
    public var estimated: Bool { streamedCharacters > 0 || thought > 0 }

    mutating func streamed(_ text: String) { streamedCharacters += text.count }

    mutating func thought(_ tokens: Int) { thought += max(0, tokens) }

    /// A call's own count: what streamed during it, its thinking too, is in it.
    mutating func call(_ tokens: Int) {
        counted += tokens
        streamedCharacters = 0
        thought = 0
    }

    /// The turn's count so far, said whole (Codex's usage after each call).
    mutating func countedSoFar(_ tokens: Int) {
        counted = max(0, tokens)
        streamedCharacters = 0
        thought = 0
    }
}
