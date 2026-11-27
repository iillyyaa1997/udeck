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
    // Stopped by uDeck's helper — SIGTERM, an update of uDeck — every session
    // is closed first: before, this process died at once and each `claude` it
    // ran lived on alone (11-27).
    signal(SIGTERM, SIG_IGN)
    signal(SIGHUP, SIG_IGN)
    let stops = [SIGTERM, SIGHUP].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                await app.closeAll()
                exit(0)
            }
        }
        source.resume()
        return source
    }
    defer { stops.forEach { $0.cancel() } }
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
    // Stopped by uDeck — an update, most often: all at once and briefly, as
    // on SIGTERM. Five seconds for each CLI held an update that long (11-27).
    await app.closeAll()
}

await run()
