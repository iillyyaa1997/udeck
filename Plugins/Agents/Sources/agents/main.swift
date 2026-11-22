import AgentsCore
import Foundation

// Agents — a resident uDeck plugin. uDeck starts it, writes events to its stdin
// (one JSON object per line) and draws whatever card it prints. It runs until
// uDeck closes its stdin.

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let home = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir), isDirectory: true)

@MainActor
func run() async {
    let app = AgentsApp(home: home) { line in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
    app.render()
    // The conversation changes on its own (streaming, a question arriving):
    // the card is looked at five times a second and written when it changed.
    let ticker = Task { @MainActor in
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            app.render()
        }
    }
    do {
        for try await line in FileHandle.standardInput.bytes.lines {
            await app.handle(line)
        }
    } catch {}
    ticker.cancel()
    for conversation in app.conversations {
        for agent in conversation.agents.values { await agent.close() }
    }
}

await run()
