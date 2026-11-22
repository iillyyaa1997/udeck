import Foundation
import Testing
@testable import UDeckAgents

@Suite("Agent process")
struct AgentProcessTests {
    /// The crash this guards: a write refused after stdin was closed asked the
    /// closed handle for its descriptor first, which raises an Objective-C
    /// exception that ends the whole process — uDeck, with a resident plugin
    /// that exits while it is told something.
    @Test("a write after stdin was closed, or after the program exited, is refused, not a crash")
    func writeAfterClose() async throws {
        let process = try AgentProcess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                                       environment: ["PATH": "/usr/bin:/bin"],
                                       directory: FileManager.default.temporaryDirectory)
        try process.write(line: "hello")
        process.closeInput()
        _ = await process.exit()
        try await Task.sleep(for: .milliseconds(50))
        #expect(throws: (any Error).self) { try process.write(line: "after") }
        #expect(throws: (any Error).self) { try process.write(line: "again") }
    }
}
