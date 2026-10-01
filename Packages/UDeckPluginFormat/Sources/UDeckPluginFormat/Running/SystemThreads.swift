#if canImport(Darwin)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Darwin

/// A lock, from the system's own mutex. `NSLock` lives in the half of
/// Foundation this package does without, so running a plugin — which uDeck
/// and `udeck-plugin run` share — takes its locks from here.
final class SystemLock: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>

    init() {
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        pthread_mutex_init(mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deinitialize(count: 1)
        mutex.deallocate()
    }

    func lock() { pthread_mutex_lock(mutex) }
    func unlock() { pthread_mutex_unlock(mutex) }

    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Work that blocks — `waitid`, a `poll` on a child's pipes — on a thread of
/// its own rather than one of the cooperative pool's: a pool thread held by a
/// process that takes its time is one fewer for everything else, and with a
/// few plugins running at once the pool runs out.
enum SystemThread {
    private final class Work {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
    }

    /// Starts `body` on a new detached thread.
    ///
    /// When the system will not make one — out of threads, which is a machine
    /// in trouble — `body` runs in a detached task instead: it holds a pool
    /// thread while it blocks, which is worse, and still better than a wait
    /// nobody does.
    static func detach(_ body: @escaping @Sendable () -> Void) {
        let work = Unmanaged.passRetained(Work(body)).toOpaque()
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        defer { pthread_attr_destroy(&attributes) }
        pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED)
        var thread: pthread_t?
        let started = pthread_create(&thread, &attributes, { raw in
            let work = Unmanaged<Work>.fromOpaque(raw).takeRetainedValue()
            work.body()
            return nil
        }, work)
        guard started != 0 else { return }
        Unmanaged<Work>.fromOpaque(work).release()
        Task.detached { body() }
    }
}
#endif
