import Foundation

/// What the system says about opening uDeck at login, and what uDeck may say about that.
///
/// The whole point of keeping this here, in the layer with no frameworks in it, is that
/// **uDeck must not keep its own copy of this setting**. An application that remembers
/// "the operator turned it on" in its own preferences and draws the switch from that
/// memory shows a switch that is on while the system has nothing recorded — and the
/// operator, who turned it off in System Settings, is told by uDeck that it is on. That
/// is not a hypothetical: Rectangle draws its checkbox from `UserDefaults` and
/// re-registers at launch whenever the two disagree, resolving every conflict in favour
/// of its own memory.
///
/// So the switch is a *reading*, taken from the system each time there is a reason to
/// take one, and everything below is about what may honestly be said about a reading.

/// The four answers the system can give, in uDeck's words rather than the framework's.
///
/// `ServiceManagement` calls them `enabled`, `notRegistered`, `requiresApproval` and
/// `notFound`; the names here say what each one means for the operator, and keeping them
/// apart from the framework's own type is what lets this file be tested without
/// registering anything on anybody's Mac.
public enum LoginItemState: Equatable, Sendable {
    /// The system will open uDeck when the operator logs in.
    case opens

    /// The system knows about uDeck and will not open it. This is what "off" means after
    /// it has once been on.
    case doesNot

    /// Registered, and the system wants the operator to allow it before it takes effect.
    ///
    /// Documented for helper executables; for a main application nobody in this project's
    /// research has observed it, which is *why* it is here rather than assumed away — an
    /// interface built around a state that never happens explains nothing, and one that
    /// cannot express a state that does happen lies.
    case waitsForApproval

    /// The system has no record of uDeck at all.
    ///
    /// Two very different situations arrive as this one answer, and an application cannot
    /// tell them apart: nobody has ever switched it on, and the record was there and is
    /// gone. That indistinguishability is the single most important fact in this file: it
    /// is why "the record disappeared" can only be noticed by *watching it disappear*,
    /// never by reading the state once.
    case systemHasNoRecord

    /// Asking the system failed. Not a state of the setting — a state of the asking.
    case couldNotAsk(reason: String)
}

/// One answer, and when it was given.
public struct LoginItemReading: Equatable, Sendable {
    public let state: LoginItemState
    public let at: Date

    public init(state: LoginItemState, at: Date) {
        self.state = state
        self.at = at
    }

    /// What the switch shows. Only one state is "on", and no other source is consulted.
    public var opensAtLogin: Bool { state == .opens }
}

/// Something worth saying out loud, or nothing at all.
///
/// Nothing at all is the ordinary case and the one to design for: the system agrees with
/// the switch, and an application that explains itself anyway is spending the operator's
/// attention on a day when nothing happened.
public enum LoginItemTrouble: Equatable, Sendable {
    /// The system is waiting for the operator to allow it.
    case waitsForApproval

    /// It was opening at login, and now the system has no record of it — with nobody
    /// having touched the switch in between.
    ///
    /// This is the failure this project measured: a second copy of uDeck with the same
    /// bundle identifier takes the record merely by being launched, and the system then
    /// acts on that copy. uDeck cannot see which copy holds the record — `SMAppService`
    /// does not say, and the tool that does needs root — so the honest sentence names
    /// what was seen (it stopped being registered) and not what was inferred.
    case recordVanished

    /// The last attempt to ask, register or unregister failed, and here is what was said.
    case couldNotAsk(reason: String)

    /// The operator asked for uDeck to open at login, and the system's answer afterwards
    /// is that it will not.
    ///
    /// Nothing threw — the asking succeeded and the record still is not there. It is a
    /// different sentence from a record that went away on its own, and it is the one that
    /// happens when the copy being asked from is not the copy the system has on file.
    case didNotTake
}

/// The decisions that do not need a window: what the switch shows, and whether there is
/// anything to say under it.
///
/// Deliberately a value, not a service: it holds the previous reading of *this run* and
/// nothing else. Nothing is written to disk, because a remembered "it used to be on"
/// surviving a restart is exactly the second source of truth this file exists to avoid.
public struct LoginItemJudgement: Equatable, Sendable {
    /// The last reading taken, or none yet.
    public private(set) var reading: LoginItemReading?

    /// What there is to say about that reading, decided when it arrived.
    ///
    /// Decided at that moment rather than computed on demand because it depends on what
    /// had happened *before* it — what the operator asked for, and whether the system had
    /// ever said it was opening in this run. A verdict that recomputed itself later would
    /// answer differently depending on when it was asked.
    public private(set) var trouble: LoginItemTrouble?

    /// Whether the system has said, at some point in this run, that it opens uDeck. What
    /// makes `recordVanished` sayable at all.
    private var hadBeenOpening = false

    /// What the operator last asked for and has not had an answer to yet.
    private var asked: Bool?

    public init() {}

    /// Say that the operator has asked for a change, before asking the system for it.
    public mutating func operatorAsked(toOpen: Bool) {
        asked = toOpen
        if !toOpen {
            // They asked for it to stop. Nothing that follows is a disappearance, and
            // whatever was being said about the old state is no longer about anything.
            hadBeenOpening = false
            trouble = nil
        }
    }

    /// Take a reading into account.
    public mutating func read(_ reading: LoginItemReading) {
        let asked = asked
        self.asked = nil
        let previous = self.reading?.state
        self.reading = reading
        if reading.state == .opens { hadBeenOpening = true }
        // The system still has the record and its switch is off: nothing was lost, and a
        // reading that says so settles the state — a later "no record" must not be read
        // back against a moment that has already been accounted for.
        if reading.state == .doesNot, asked == nil { hadBeenOpening = false }

        let fresh = Self.trouble(for: reading.state, asked: asked, hadBeenOpening: hadBeenOpening)
        trouble = Self.settle(fresh, keeping: trouble, was: previous, now: reading.state)
    }

    /// Whether a sentence already on screen survives a reading that says nothing new.
    ///
    /// The card re-reads whenever uDeck is activated or its window comes forward — and
    /// its *own* button sends the operator to System Settings, which is exactly such a
    /// trip. Without this, pressing "Open Login Items & Extensions" and coming back wiped
    /// the headline, the named copy and the button itself, leaving an off switch with no
    /// explanation although nothing about the system had changed.
    ///
    /// Only two verdicts are kept this way, and only while the answer stays the same:
    /// "the system did not take it", which no later reading re-derives, and "the asking
    /// failed", whose reason exists nowhere else on screen.
    static func settle(
        _ fresh: LoginItemTrouble?,
        keeping old: LoginItemTrouble?,
        was previous: LoginItemState?,
        now: LoginItemState
    ) -> LoginItemTrouble? {
        if fresh != nil { return fresh }
        switch old {
        case .didNotTake:
            // The same answer as the one that earned the sentence is not news.
            return previous == now ? old : nil
        case .couldNotAsk:
            // The next reading brings a real state where there was none, so "the same
            // answer" cannot be the test; it stands until something actually works.
            return now == .opens ? nil : old
        default:
            return nil
        }
    }

    public var opensAtLogin: Bool { reading?.opensAtLogin ?? false }

    /// The whole of the decision, in one place and with no window in sight.
    static func trouble(for state: LoginItemState, asked: Bool?, hadBeenOpening: Bool) -> LoginItemTrouble? {
        switch state {
        case .opens:
            return nil
        case .waitsForApproval:
            return .waitsForApproval
        case .couldNotAsk(let reason):
            return .couldNotAsk(reason: reason)
        case .doesNot:
            // The system has the record and will not act on it. That is what the operator
            // switching it off in Login Items & Extensions looks like, and it is their own
            // doing: the only thing to say about it is nothing. Saying "the record went
            // away" here — and naming an innocent second copy as the likely thief — was
            // the shape of an accusation this card used to make.
            return asked == true ? .didNotTake : nil
        case .systemHasNoRecord:
            // No record at all. Asked for and not there means the system declined;
            // unasked, after it had been opening, is the disappearance this card exists
            // for — and the two are told apart by who asked, because the system's word
            // for "never seen this" and for "it is gone" is the same one.
            if asked == true { return .didNotTake }
            if hadBeenOpening { return .recordVanished }
            return nil
        }
    }
}
