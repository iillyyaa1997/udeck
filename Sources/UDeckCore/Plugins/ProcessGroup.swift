import Darwin
import Foundation

/// A child started in a process group of its own, and everything that follows
/// from owning that group.
///
/// Foundation's `Process` cannot do this. It exposes no spawn attributes, and
/// `setpgid` called from the parent afterwards always loses the race:
/// `posix_spawn` has already exec'd the child by the time `run()` returns, and
/// `setpgid` on a process that has exec'd fails with `EACCES`. So the group has
/// to be asked for at spawn time, which means spawning by hand.
///
/// What the group buys is the thing the old implementation could not have. It
/// enumerated the process tree *before* signalling, because once the direct
/// child dies its children are re-parented to `launchd` and a later enumeration
/// no longer connects them to anything. That enumeration only ever happened on
/// a deadline or an output overrun — so a producer that spawned something
/// detached and then exited *successfully* left it behind, every poll, forever.
/// A group has no such window: `kill(-pgid, …)` reaches every member whenever
/// it is sent, whatever the direct child did or when.
///
/// **The zombie is load-bearing.** A process group exists as long as it has a
/// member, and an unreaped child is a member. So the exit status is read with
/// `waitid(…, WNOWAIT)`, which leaves the zombie in place, and the child is
/// reaped only after the group has been cleaned up. Until then the group id
/// cannot be recycled, and `kill(-pgid, …)` cannot possibly reach a stranger —
/// which is the same hazard the old code spent a start-time identity check on.
struct SpawnedProcess {
    let pid: pid_t

    /// The read ends. The caller owns them and closes them.
    let standardOutput: FileHandle
    let standardError: FileHandle

    /// The child is its own group leader, so this is also its pid — kept as a
    /// separate name because everything below signals the *group*.
    var processGroup: pid_t { pid }
}

enum SpawnError: Error, CustomStringConvertible {
    case pipeFailed(Int32)
    case spawnFailed(Int32)

    var description: String {
        switch self {
        case .pipeFailed(let code):
            "could not create a pipe: \(String(cString: strerror(code)))"
        case .spawnFailed(let code):
            "could not start the process: \(String(cString: strerror(code)))"
        }
    }
}

enum ProcessGroup {
    // MARK: - Starting

    /// Starts `executable` in a new process group, with stdout and stderr on
    /// pipes and stdin at `/dev/null`.
    static func spawn(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> SpawnedProcess {
        var outFDs: [Int32] = [-1, -1]
        var errFDs: [Int32] = [-1, -1]
        guard pipe(&outFDs) == 0 else { throw SpawnError.pipeFailed(errno) }
        guard pipe(&errFDs) == 0 else {
            close(outFDs[0]); close(outFDs[1])
            throw SpawnError.pipeFailed(errno)
        }

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        // Order matters: the write ends are moved onto 1 and 2 first, and only
        // then are the originals closed in the child. Closing first would close
        // the descriptor the dup is being made from.
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outFDs[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errFDs[1], 2)
        posix_spawn_file_actions_addclose(&actions, outFDs[1])
        posix_spawn_file_actions_addclose(&actions, errFDs[1])
        // `_np` rather than the macOS 26 spelling: the package floor is macOS
        // 14, where only the non-portable name exists.
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // SETPGROUP with a group of 0 means "be your own group leader".
        //
        // CLOEXEC_DEFAULT closes every descriptor the file actions above did not
        // name. Without it a producer inherits whatever uDeck happened to have
        // open — the other plugins' pipes among them — and a plugin holding
        // another plugin's pipe open is a plugin that stops it reaching
        // end-of-file.
        //
        // SETSIGDEF and SETSIGMASK are not tidiness. Signal dispositions survive
        // `exec`, so a child inherits the host's — and a host built on libdispatch
        // ignores signals the producer needs. A shell cannot trap a signal that
        // was already ignored when it started: POSIX says the trap has no effect.
        // Without this the polite `SIGTERM` reached a producer that could not
        // act on it, every well-behaved producer looked wedged, and each one
        // cost the full grace period and then a `SIGKILL`.
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        posix_spawnattr_setsigdefault(&attributes, &defaulted)

        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)

        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        ))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = -1
        let status = withCStrings([executable.path] + arguments) { argv in
            withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
            }
        }

        // The parent's copies of the write ends go now, whatever happened: while
        // the parent holds one, the read end never reaches end-of-file.
        close(outFDs[1])
        close(errFDs[1])

        guard status == 0 else {
            close(outFDs[0])
            close(errFDs[0])
            throw SpawnError.spawnFailed(status)
        }

        return SpawnedProcess(
            pid: pid,
            standardOutput: FileHandle(fileDescriptor: outFDs[0], closeOnDealloc: true),
            standardError: FileHandle(fileDescriptor: errFDs[0], closeOnDealloc: true)
        )
    }

    // MARK: - Waiting

    /// Blocks until the child exits, and reports how, *without reaping it*.
    ///
    /// Not reaping is deliberate — see the note on the zombie above. Call
    /// `reap` once the group has been dealt with.
    static func waitForExit(pid: pid_t) -> Termination {
        var info = siginfo_t()
        while true {
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
            if result == 0 { break }
            if errno == EINTR { continue }
            // ECHILD: somebody else reaped it, which should not happen and is
            // not a reason to hang. Report what an ordinary exit looks like.
            return .exited(code: 0)
        }
        return switch info.si_code {
        case Int32(CLD_EXITED): .exited(code: info.si_status)
        default: .signalled(signal: info.si_status)
        }
    }

    /// Collects the zombie. After this the group id may be recycled, so nothing
    /// may signal the group afterwards.
    static func reap(pid: pid_t) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }

    // MARK: - Stopping

    /// Every process in the group that is not a zombie.
    ///
    /// Asked of the kernel directly rather than by running `ps`: this is one
    /// group, it is a single `sysctl`, and it happens on every poll.
    ///
    /// The direct child is *not* excluded — it is exactly what has to be
    /// signalled while it is still running. What keeps it from making the group
    /// look busy after it has ended is that a reaped-later child is a zombie,
    /// and zombies are filtered here.
    static func liveMembers(of group: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: max(count, 1))
        guard sysctl(&mib, 4, &entries, &size, nil, 0) == 0 else { return [] }

        let found = size / MemoryLayout<kinfo_proc>.stride
        return entries.prefix(found).compactMap { entry in
            let member = entry.kp_proc.p_pid
            guard member > 1 else { return nil }
            guard entry.kp_proc.p_stat != SZOMB else { return nil }
            return member
        }
    }

    /// Signals the whole group, politely and then not, and returns when nothing
    /// is left in it.
    ///
    /// Safe to call at any point while the child is unreaped, including after it
    /// has already exited — which is the point. The old code only ever ran this
    /// from the deadline and output-cap watchers, and cancelled the escalation
    /// when the direct child died, so a child of the producer that ignored
    /// `SIGTERM` outlived the run and was never seen again.
    static func terminate(
        group: pid_t,
        grace: TimeInterval,
        pollEvery: TimeInterval
    ) async {
        guard !liveMembers(of: group).isEmpty else { return }

        kill(-group, SIGTERM)

        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if liveMembers(of: group).isEmpty { return }
            await sleepIgnoringCancellation(pollEvery)
        }

        kill(-group, SIGKILL)
    }

    /// A pause a cancellation cannot cut short.
    ///
    /// `try? await Task.sleep` looks like it does this and does the opposite:
    /// in a cancelled task it returns *immediately*, and the `try?` hides that
    /// it did. The loop above then spins at the speed of the process table for
    /// the rest of the grace period — which is how a grace period turns into a
    /// busy wait, measured as a full core for three seconds.
    ///
    /// A grace period that stops when somebody loses interest is not a grace
    /// period: the escalation after it is what makes "and then not politely" true.
    private static func sleepIgnoringCancellation(_ seconds: TimeInterval) async {
        await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }

    // MARK: - C string plumbing

    /// Calls `body` with a NULL-terminated `char *[]` that lives exactly as long
    /// as the call.
    private static func withCStrings<R>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return body(&pointers)
    }
}
