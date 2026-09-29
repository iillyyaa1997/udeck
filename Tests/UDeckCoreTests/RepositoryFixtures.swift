import Foundation
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// Records what a fetch was asked for, and answers from a `FakeRepository`.
final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private var override: [String: Data] = [:]
    private var failing: Set<String> = []
    let repository: FakeRepository

    init(_ repository: FakeRepository) {
        self.repository = repository
    }

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return asked
    }

    /// Answer this path with other bytes.
    func alter(_ path: String, to data: Data) {
        lock.lock(); defer { lock.unlock() }
        override[path] = data
    }

    func fail(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        failing.insert(path)
    }

    var fetch: @Sendable (String, String) async throws -> Data {
        { [self] path, _ in
            let (altered, fails) = lock.withLock { () -> (Data?, Bool) in
                asked.append(path)
                return (override[path], failing.contains(path))
            }
            if fails { throw ProviderError.unreachable("no route") }
            if let altered { return altered }
            guard let data = repository.data(at: path) else { throw ProviderError.notFound }
            return data
        }
    }
}

/// A Trash that keeps what it is given in a folder of the test's own.
final class TestTrash: PluginTrash, @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var discarded: [String] = []

    init(in directory: URL) {
        folder = directory.appendingPathComponent("Trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return discarded
    }

    func discard(_ url: URL) throws {
        let target = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: target)
        lock.lock(); defer { lock.unlock() }
        discarded.append(url.lastPathComponent)
    }
}
