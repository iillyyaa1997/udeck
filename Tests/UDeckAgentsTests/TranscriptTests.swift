import Foundation
import Testing
@testable import UDeckAgents

/// A transcript Claude Code 2.1.330 saved for a session driven as uDeck drives
/// it, cut down to its conversation entries and with personal details replaced.
@Suite("A saved Claude Code session, read back for the feed")
struct TranscriptTests {
    static func transcript() throws -> ClaudeTranscript {
        let url = try #require(Bundle.module.url(forResource: "claude-transcript", withExtension: "jsonl",
                                                 subdirectory: "Fixtures"))
        return try ClaudeTranscript(url: url)
    }

    @Test("the conversation comes back in order: two prompts, the tool calls, their results and the answers")
    func conversation() throws {
        let transcript = try Self.transcript()
        #expect(transcript.sessionID == "b0a56267-29b4-4989-8687-ee73303d5101")
        #expect(transcript.cwd == "/tmp/udeck-fixture/work")
        var prompts: [String] = [], tools: [String] = [], answers: [String] = [], results = 0
        for entry in transcript.entries {
            switch entry {
            case .userText(let text, _): prompts.append(text)
            case .toolResults(let found, _): results += found.count
            case .assistant(let message, _):
                for block in message.blocks {
                    if case .toolUse(_, let name, _) = block { tools.append(name) }
                }
                if !message.text.isEmpty { answers.append(message.text) }
            }
        }
        #expect(prompts.count == 2)
        #expect(prompts[0].hasPrefix("Read notes.md"))
        #expect(tools.contains("Edit") && tools.contains("AskUserQuestion"))
        #expect(results == tools.count)
        #expect(answers.last?.contains("Red") == true)
        #expect(transcript.lastPrompt?.isEmpty == false)
    }

    @Test("entries of kinds it does not know, and broken lines, are skipped without failing")
    func unknownAndBroken() {
        let transcript = ClaudeTranscript(contents: """
        {"type":"api-request-blob","sessionId":"s1","blob":"…"}
        not json at all
        {"type":"user","sessionId":"s1","message":{"role":"user","content":"hello"},"timestamp":"2026-11-21T01:00:00.000Z"}
        {"type":"assistant","isSidechain":true,"sessionId":"s1","message":{"content":[{"type":"text","text":"subagent"}]}}
        {"type":"brand-new-kind","sessionId":"s1"}
        """)
        #expect(transcript.sessionID == "s1")
        #expect(transcript.entries.count == 1)
        guard case .userText(let text, let at) = transcript.entries.first else { Issue.record("no prompt"); return }
        #expect(text == "hello")
        #expect(at != nil)
    }
}
