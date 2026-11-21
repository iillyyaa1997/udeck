import Foundation

/// What uDeck writes to Claude Code's stdin, one line each.
///
/// Requests uDeck starts carry an id it chooses; the CLI's answer echoes it
/// (`ClaudeControlResponse.requestID`). Answers to the CLI's own requests echo
/// the id the CLI chose.
public enum ClaudeOutbound {
    /// The arguments uDeck starts `claude` with — the same the official Agent SDK
    /// uses for a client that answers permission prompts itself, read from its
    /// source (0.3.330). The binary is the user's own and is not modified.
    public static func arguments(model: String? = nil, resume sessionID: String? = nil,
                                 permissionMode: String? = nil) -> [String]
    {
        // --include-partial-messages: the answer arrives word by word, as in
        // the terminal, instead of one block at a time.
        var arguments = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
                         "--permission-prompt-tool=stdio", "--include-partial-messages"]
        if let model { arguments += ["--model", model] }
        if let sessionID { arguments += ["--resume", sessionID] }
        if let permissionMode { arguments += ["--permission-mode", permissionMode] }
        return arguments
    }

    /// The first request of a session. uDeck registers no hooks of its own and
    /// renders no tool dialogs yet, and says so: a dialog kind a client did not
    /// declare is never sent to it.
    public static func initialize(id: String, dialogKinds: [String] = []) -> JSONValue {
        control(id: id, ["subtype": "initialize", "hooks": .object([:]),
                         "supportedDialogKinds": .array(dialogKinds.map(JSONValue.string))])
    }

    /// A message from the user. `images` are base64 PNG or JPEG with their type.
    public static func userMessage(_ text: String, images: [(mediaType: String, base64: String)] = []) -> JSONValue {
        var content: [JSONValue] = images.map { image in
            ["type": "image", "source": ["type": "base64", "media_type": .string(image.mediaType),
                                          "data": .string(image.base64)]]
        }
        content.append(["type": "text", "text": .string(text)])
        return ["type": "user", "message": ["role": "user", "content": .array(content)],
                "parent_tool_use_id": nil, "session_id": ""]
    }

    // MARK: - Answers to the CLI's requests

    /// Let the tool run as asked — or with `input` changed. `rules`, when the
    /// user chose "always", are the ask's own `permission_suggestions`.
    public static func allow(_ requestID: String, input: JSONValue, rules: [JSONValue] = []) -> JSONValue {
        var result: [String: JSONValue] = ["behavior": "allow", "updatedInput": input]
        if !rules.isEmpty { result["updatedPermissions"] = .array(rules) }
        return answer(requestID, .object(result))
    }

    public static func deny(_ requestID: String, message: String) -> JSONValue {
        answer(requestID, ["behavior": "deny", "message": .string(message)])
    }

    /// The user's choices for an AskUserQuestion ask: question text → the chosen
    /// option's label (several labels joined by ", " for a multi-select).
    public static func answers(_ requestID: String, to ask: ClaudePermissionAsk,
                               chosen: [String: [String]]) -> JSONValue
    {
        var input = ask.input.object ?? [:]
        input["answers"] = .object(chosen.mapValues { .string($0.joined(separator: ", ")) })
        return allow(requestID, input: .object(input))
    }

    // MARK: - Requests uDeck starts

    /// Stop the running turn. With `cancelQueued` (only for a CLI that advertises
    /// `interrupt_cancel_queued_v1`) the messages waiting behind it are dropped
    /// too — Stop means stop everything; without it they run next.
    public static func interrupt(id: String, cancelQueued: Bool = false) -> JSONValue {
        var request: [String: JSONValue] = ["subtype": "interrupt"]
        if cancelQueued { request["cancel_queued"] = true }
        return control(id: id, request)
    }

    public static func setModel(id: String, _ model: String) -> JSONValue {
        control(id: id, ["subtype": "set_model", "model": .string(model)])
    }

    public static func setPermissionMode(id: String, _ mode: String) -> JSONValue {
        control(id: id, ["subtype": "set_permission_mode", "mode": .string(mode)])
    }

    /// For a context bar: the summary only, without the per-category token
    /// counting the full answer costs.
    public static func contextUsage(id: String) -> JSONValue {
        control(id: id, ["subtype": "get_context_usage", "detail": "summary"])
    }

    /// For the limits: plan windows only, without the seven-day transcript scan.
    public static func usage(id: String) -> JSONValue {
        control(id: id, ["subtype": "get_usage", "skip_behaviors": true])
    }

    public static func fileSuggestions(id: String, query: String) -> JSONValue {
        control(id: id, ["subtype": "file_suggestions", "query": .string(query)])
    }

    public static func listModels(id: String) -> JSONValue { control(id: id, ["subtype": "list_models"]) }

    // MARK: -

    private static func control(id: String, _ request: [String: JSONValue]) -> JSONValue {
        ["type": "control_request", "request_id": .string(id), "request": .object(request)]
    }

    private static func answer(_ requestID: String, _ response: JSONValue) -> JSONValue {
        ["type": "control_response",
         "response": ["subtype": "success", "request_id": .string(requestID), "response": response]]
    }
}
