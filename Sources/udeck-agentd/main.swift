import Darwin
import Foundation
import os
import UDeckAgentHost

// udeck-agentd — the helper that owns uDeck's agents.
//
// A launchd login agent of the uDeck bundle (Contents/Library/LaunchAgents,
// registered by uDeck with SMAppService), started on demand when uDeck
// connects to its Mach service. Agents started here keep working while uDeck
// quits, crashes or updates; with no agent running and nobody connected for a
// while, the helper leaves, and launchd starts it again at the next connection.
//
//   udeck-agentd                    run as the launchd job
//   udeck-agentd hello              connect to the job as a client and say what
//                                   happened — for the lab: a program that is
//                                   not uDeck must be turned away
//
// Who may connect: only the uDeck this helper ships in, by code signature,
// checked on every message (CodeIdentity). Nothing on the command line widens
// that.

let logger = Logger(subsystem: "place.unicorns.udeck.agentd", category: "helper")

func say(_ text: String) {
    logger.notice("\(text, privacy: .public)")
    FileHandle.standardError.write(Data(("udeck-agentd: " + text + "\n").utf8))
}

func fail(_ text: String, code: Int32 = 64) -> Never {
    say(text)
    exit(code)
}

let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
guard let app = CodeIdentity.enclosingApplication(of: executable),
      let appIdentifier = Bundle(url: app)?.bundleIdentifier
else { fail("not inside uDeck.app/Contents/Helpers; launchd starts this from the bundle") }
let service = HostPaths.agentLabel(bundleIdentifier: appIdentifier)
let version = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["hello"] {
    // A client that is not uDeck: whatever the helper says, or how it hung up.
    let requirement = try? CodeIdentity.peerRequirement(identifier: service, codeAt: executable)
    let client = AgentHostClient(machServiceName: service, helperRequirement: requirement)
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let hello = try await client.hello(client: "udeck-agentd hello")
            print("admitted by helper \(hello.info.version) pid \(hello.info.pid)")
        } catch {
            print("refused: \(error)")
        }
        done.signal()
    }
    if done.wait(timeout: .now() + 15) == .timedOut { print("no answer in 15 s") }
    exit(0)
}
if let unknown = arguments.first { fail("unknown argument \(unknown)") }
// Started by hand, the Mach service is not this process's to serve: the
// listener would wait for connections that can never come.
guard getppid() == 1 else { fail("launchd starts this, as the job \(service); `udeck-agentd hello` tries it") }

let peerRequirement: String
do {
    peerRequirement = try CodeIdentity.peerRequirement(identifier: appIdentifier, codeAt: app)
} catch {
    fail("cannot work out who may connect: \(error)", code: 70)
}

let host = AgentHost()
let info = HostInfo(version: version)
let shutdown = Shutdown()
let server: HostServer
do {
    server = try HostServer(listening: .machService(service), peerRequirement: peerRequirement, host: host,
                            info: info, log: { say($0) }, onQuit: { shutdown.begin(reason: "asked to quit") })
} catch {
    fail("cannot listen: \(error)", code: 70)
}
shutdown.attach(server: server, host: host)
server.start()
say("\(version) (pid \(getpid())) serving \(service); peers must satisfy: \(peerRequirement)")

// SIGTERM (logout, shutdown, the job unregistered) and SIGINT: stop the agents
// cleanly, then go. On a queue of their own: after dispatchMain() the main
// queue is drained by a worker thread, so main-actor code must not run there.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGPIPE, SIG_IGN)
let signalQueue = DispatchQueue(label: "udeck.agentd.signals")
let signalSources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler { @Sendable in shutdown.begin(reason: "signal \(number)") }
    source.resume()
    return source
}

// Idle: no agent running and nobody connected for ten minutes. launchd starts
// the helper again when uDeck next connects.
let idleTimer = DispatchSource.makeTimerSource(queue: signalQueue)
idleTimer.schedule(deadline: .now() + 60, repeating: 60)
idleTimer.setEventHandler { @Sendable in
    Task {
        guard server.connectionCount == 0, ContinuousClock.now - server.lastActivity > .seconds(600),
              await !host.hasRunningAgents
        else { return }
        shutdown.begin(reason: "idle")
    }
}
idleTimer.resume()

dispatchMain()

/// Runs the shutdown once, however many ways it is asked for.
final class Shutdown: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var server: HostServer?
    private var host: AgentHost?

    func attach(server: HostServer, host: AgentHost) {
        lock.withLock {
            self.server = server
            self.host = host
        }
    }

    func begin(reason: String) {
        let (first, server, host) = lock.withLock { () -> (Bool, HostServer?, AgentHost?) in
            defer { started = true }
            return (!started, self.server, self.host)
        }
        guard first, let server, let host else { return }
        say("stopping (\(reason))")
        // Nothing new is taken from here on; connections stay open so uDeck
        // sees its agents finish.
        server.stopListening()
        Task {
            // Within launchd's ExitTimeOut (30 s in the job's plist), with a margin.
            await host.shutdown(grace: .seconds(25))
            server.closeConnections()
            say("stopped")
            exit(0)
        }
    }
}
