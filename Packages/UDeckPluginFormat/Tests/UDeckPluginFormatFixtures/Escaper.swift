#if canImport(Darwin)
import Foundation

/// A producer whose child gets away: it leaves the process group uDeck ends
/// with `setsid`, and keeps the producer's standard output and error open.
///
/// The child waits for `<scratch>/returned`, which the test makes once the run
/// has returned (`verdict`); then it writes once to the pipe and records in
/// `<scratch>/verdict` whether anybody was still reading it: `open` or
/// `closed`. The producer prints its card only once the child has left the
/// group, so that ending the group cannot reach the child first.
///
/// The child gives up waiting after five minutes, so that a test process that
/// died leaves nothing behind for long. Not sooner: beside the tests that hold
/// the cooperative pool's threads with the processes they wait on, a test of
/// it that takes under a second alone took 30 s, and a child that wrote before
/// the run returned would find its pipe read.
public enum Escaper {
    /// The producer's script, after its `#!/bin/sh` line.
    public static func script(in scratch: URL) -> String {
        """
        dir='\(scratch.path)'
        /usr/bin/perl -e '
            use POSIX ();
            POSIX::setsid() or exit 3;
            $SIG{PIPE} = "IGNORE";
            my $dir = $ARGV[0];
            open(my $left, ">", "$dir/detached") or exit 5; close($left);
            for (1 .. 12000) { last if -e "$dir/returned"; select(undef, undef, undef, 0.025); }
            my $wrote = syswrite(STDOUT, "late\\n");
            open(my $said, ">", "$dir/verdict.part") or exit 6;
            print $said (defined $wrote ? "open" : "closed"); close($said);
            rename("$dir/verdict.part", "$dir/verdict");
        ' "$dir" &
        i=0
        while [ ! -e "$dir/detached" ] && [ $i -lt 400 ]; do sleep 0.025; i=$((i + 1)); done
        printf '{"rows": [{"text": "printed"}]}'
        """
    }

    /// Tells the child the run has returned, and waits — up to ten seconds; it
    /// answers within one of its 25 ms looks — for what its write found.
    public static func verdict(in scratch: URL) -> String? {
        FileManager.default.createFile(atPath: scratch.appendingPathComponent("returned").path, contents: nil)
        let file = scratch.appendingPathComponent("verdict")
        for _ in 0 ..< 400 {
            if let said = try? String(contentsOf: file, encoding: .utf8) { return said }
            usleep(25_000)
        }
        return nil
    }

    /// Lets the child go now rather than in ten seconds, and waits for its
    /// last word: for a test that stopped before it asked for the verdict, so
    /// that the child is not writing into `scratch` while the test's
    /// temporary folder is taken away. Not a signal by its pid, which could
    /// reach a stranger once the child is gone.
    public static func stop(in scratch: URL) {
        _ = verdict(in: scratch)
    }
}
#endif
