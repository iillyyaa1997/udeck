import Foundation

/// Naming the other copy, which is the only useful thing uDeck can say about the failure
/// it actually suffers.
///
/// Measured twice in a virtual machine: a second copy of uDeck carrying the same bundle
/// identifier takes the login record merely by being launched, and the system then opens
/// *that* copy at login. The system will not say which one it has on file — `SMAppService`
/// exposes no such property, and the tool that knows (`sfltool dumpbtm`) is signed with
/// entitlements no ordinary application has.
///
/// What an application *can* do without any permission is list the copies of itself that
/// exist, which is how Mac Mouse Fix and Tailscale both name a rival copy. It is not proof
/// that a particular copy took the record; it is the fact that turns "the record went
/// away" into something the operator can act on, and it is stated as such.

/// The copies of uDeck on this Mac other than the one running.
///
/// The running copy has to come out of the list, or the application points at itself and
/// tells the operator to go and look at the thing they are already using. Paths are
/// compared with symlinks resolved and without regard to case, because the volume uDeck
/// lives on is case-insensitive by default and `/Users/x/Applications` and
/// `/Users/x/applications` are the same directory there.
public func otherCopies(than running: URL, among all: [URL]) -> [URL] {
    let mine = settled(running)
    return all.filter { settled($0).compare(mine, options: .caseInsensitive) != .orderedSame }
}

private func settled(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
}

/// What the settings screen says under the switch, when it says anything at all.
///
/// One value rather than a handful of flags, and the copies travel inside it: the sentence
/// about a record that went away is a different sentence when there is another copy to
/// name, and a screen that can show both halves separately is a screen that will.
public enum LoginItemMessage: Equatable, Sendable {
    /// Registered, and the system wants the operator to allow it.
    case waitsForApproval

    /// It was opening at login, and the system's record is gone — with the other copies
    /// that exist, if any, since one of them is the likely reason.
    case vanished(otherCopies: [URL])

    /// The operator asked for it and the system declined to record it. The same copies
    /// matter here and for the same reason: this is what it looks like from a copy that
    /// is not the one the system has on file.
    case didNotTake(otherCopies: [URL])

    /// Asking, registering or unregistering failed, and this is what was said.
    case couldNotAsk(reason: String)
}

/// What to say, given what went wrong and what else is on the disk.
///
/// Nothing is the ordinary answer, and the card says nothing then: the switch and the path
/// of the copy that would open are the whole of it on a day when the system agrees.
public func message(for trouble: LoginItemTrouble?, otherCopies: [URL]) -> LoginItemMessage? {
    switch trouble {
    case nil: nil
    case .waitsForApproval: .waitsForApproval
    case .recordVanished: .vanished(otherCopies: otherCopies)
    case .didNotTake: .didNotTake(otherCopies: otherCopies)
    case .couldNotAsk(let reason): .couldNotAsk(reason: reason)
    }
}
