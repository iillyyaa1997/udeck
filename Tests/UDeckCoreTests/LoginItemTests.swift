import Foundation
import Testing
@testable import UDeckCore

/// "Open at Login" is a setting whose truth lives somewhere else — in the system's own
/// record — and every way of getting it wrong is a way of telling the operator something
/// untrue about their own Mac.
///
/// The failures these tests are written against are all real, and none of them is
/// hypothetical:
///
/// * Rectangle draws its checkbox from its own preferences, so the switch says on while
///   the system has nothing recorded.
/// * A second copy of uDeck with the same bundle identifier takes the record merely by
///   being launched — measured in a virtual machine, twice.
/// * The system answers "never seen this" and "the record is gone" with the *same* word,
///   so an application that claims to tell them apart from one reading is guessing.
@Suite("Opening at login")
struct LoginItemTests {
    let noon = Date(timeIntervalSince1970: 1_789_000_000)

    func reading(_ state: LoginItemState, _ after: TimeInterval = 0) -> LoginItemReading {
        LoginItemReading(state: state, at: noon + after)
    }

    // MARK: - The switch

    @Test("the switch is on for exactly one answer")
    func onlyOpensIsOn() {
        #expect(reading(.opens).opensAtLogin)
        for state: LoginItemState in [.doesNot, .waitsForApproval, .systemHasNoRecord, .couldNotAsk(reason: "x")] {
            #expect(!reading(state).opensAtLogin, "\(state) must not read as on")
        }
    }

    @Test("with nothing read yet, the switch is off rather than remembered")
    func nothingReadYet() {
        let judgement = LoginItemJudgement()
        #expect(!judgement.opensAtLogin)
        #expect(judgement.trouble == nil)
        #expect(judgement.reading == nil)
    }

    // MARK: - An ordinary day says nothing

    @Test("nothing is said when the system agrees with the switch")
    func quietWhenOn() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.opens))
        #expect(judgement.opensAtLogin)
        #expect(judgement.trouble == nil)
    }

    @Test("nothing is said when it is simply off")
    func quietWhenNeverOn() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.systemHasNoRecord))
        #expect(judgement.trouble == nil, "never registered is not a problem, it is the default")

        var known = LoginItemJudgement()
        known.read(reading(.doesNot))
        #expect(known.trouble == nil)
    }

    @Test("the operator switching it off is not reported back to them as a fault")
    func theOperatorsOwnChange() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.opens))
        judgement.operatorAsked(toOpen: false)
        judgement.read(reading(.systemHasNoRecord, 1))
        #expect(judgement.trouble == nil)
        #expect(!judgement.opensAtLogin)
    }

    // MARK: - The one thing worth interrupting for

    /// The measured failure, and the only shape in which it can be stated honestly: the
    /// record was seen, then it was not, and nobody asked for that.
    @Test("a record that disappears under uDeck is said out loud")
    func recordVanishes() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.opens))
        judgement.read(reading(.systemHasNoRecord, 60))
        #expect(judgement.trouble == .recordVanished)
        #expect(!judgement.opensAtLogin)
    }

    @Test("it stays said until something changes")
    func vanishedStaysVanished() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.opens))
        judgement.read(reading(.systemHasNoRecord, 60))
        judgement.read(reading(.systemHasNoRecord, 120))
        #expect(judgement.trouble == .recordVanished)

        judgement.operatorAsked(toOpen: true)
        judgement.read(reading(.opens, 180))
        #expect(judgement.trouble == nil, "switching it back on ends it")
    }

    /// The trap this is written against: "it is off" and "it went away" arrive as the
    /// same word, so a first reading of `systemHasNoRecord` must never be dressed up as
    /// a disappearance. Only having *seen* it opening earns that sentence.
    @Test("an application that never saw it open cannot claim it vanished")
    func noClaimWithoutEvidence() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.systemHasNoRecord))
        judgement.read(reading(.systemHasNoRecord, 60))
        #expect(judgement.trouble == nil)
    }

    /// The hole the first version of this file had: the operator asks for it, nothing
    /// throws, and the system's answer afterwards is still "no record". Saying nothing
    /// there leaves a switch that springs back with no explanation — which is the
    /// complaint people actually write about this setting.
    @Test("an on the system does not take is said, and not as a disappearance")
    func didNotTake() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.systemHasNoRecord))
        judgement.operatorAsked(toOpen: true)
        judgement.read(reading(.systemHasNoRecord, 1))
        #expect(judgement.trouble == .didNotTake)
        #expect(!judgement.opensAtLogin)
    }

    @Test("an on that the system takes says nothing")
    func askedAndTaken() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.systemHasNoRecord))
        judgement.operatorAsked(toOpen: true)
        judgement.read(reading(.opens, 1))
        #expect(judgement.trouble == nil)
        #expect(judgement.opensAtLogin)
    }

    /// One answer settles one request. Without that, an "on" the operator asked for
    /// hours ago keeps re-labelling every later reading: the record goes away by itself
    /// and uDeck says "the system did not take it", which blames the wrong moment.
    @Test("a request is settled by the answer to it, not by every answer after")
    func theRequestIsSettled() {
        var judgement = LoginItemJudgement()
        judgement.operatorAsked(toOpen: true)
        judgement.read(reading(.opens, 1))
        #expect(judgement.trouble == nil)

        judgement.read(reading(.systemHasNoRecord, 600))
        #expect(judgement.trouble == .recordVanished, "by then nobody had asked for anything")
    }

    @Test("waiting for approval is said as itself")
    func approval() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.waitsForApproval))
        #expect(judgement.trouble == .waitsForApproval)
        #expect(!judgement.opensAtLogin, "registered is not the same as opening")
    }

    @Test("a failure to ask is reported as a failure to ask, not as a setting")
    func askingFailed() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.opens))
        judgement.read(reading(.couldNotAsk(reason: "Operation not permitted"), 5))
        #expect(judgement.trouble == .couldNotAsk(reason: "Operation not permitted"))
        #expect(!judgement.opensAtLogin)
    }

    /// Asking failing must not be read as the record having gone: the two are different
    /// sentences and only one of them is about the operator's Mac being in a state they
    /// would want to fix.
    @Test("a failure to ask does not become a disappearance")
    func failureIsNotDisappearance() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.opens))
        judgement.read(reading(.couldNotAsk(reason: "no"), 5))
        #expect(judgement.trouble != .recordVanished)
    }

    // MARK: - Nothing is remembered

    /// A fresh judgement knows nothing, which is the point: what uDeck believed before it
    /// was restarted is not evidence about the system, and keeping it would be the second
    /// source of truth this design exists without.
    @Test("a new run starts with no opinion")
    func nothingSurvivesARun() {
        var first = LoginItemJudgement()
        first.read(reading(.opens))
        #expect(first.opensAtLogin)

        let second = LoginItemJudgement()
        #expect(!second.opensAtLogin)
        #expect(second.trouble == nil)
    }
}

/// Naming the other copy is the only useful thing uDeck can say about the failure it
/// actually suffers: the system will not tell an application which copy holds the record,
/// so what is offered instead is the list of copies that exist — and the first rule of
/// that list is that uDeck must not point at itself.
@Suite("The other copies of uDeck")
struct LoginItemCopiesTests {
    let running = URL(fileURLWithPath: "/Applications/uDeck.app")

    @Test("the running copy is never named")
    func excludesItself() {
        let found = otherCopies(than: running, among: [running])
        #expect(found.isEmpty)
    }

    @Test("a copy somewhere else is named")
    func namesTheOther() {
        let debug = URL(fileURLWithPath: "/Users/x/Applications/uDeck-debug.app")
        #expect(otherCopies(than: running, among: [running, debug]) == [debug])
    }

    /// The same bundle arrives spelled three ways from `NSWorkspace`, a trailing slash and
    /// a different case among them, and each one would have uDeck accusing itself.
    @Test("the same copy spelled differently is still itself")
    func spelling() {
        let withSlash = URL(fileURLWithPath: "/Applications/uDeck.app/")
        let otherCase = URL(fileURLWithPath: "/applications/UDECK.app")
        let doubled = URL(fileURLWithPath: "/Applications/./uDeck.app")
        #expect(otherCopies(than: running, among: [withSlash, otherCase, doubled]).isEmpty)
    }

    @Test("several copies all come through, in the order the system gave them")
    func several() {
        let a = URL(fileURLWithPath: "/Users/x/Desktop/uDeck.app")
        let b = URL(fileURLWithPath: "/Volumes/Backup/uDeck.app")
        #expect(otherCopies(than: running, among: [a, running, b]) == [a, b])
    }

    // MARK: - What is said

    @Test("an ordinary day says nothing at all")
    func quiet() {
        #expect(message(for: nil, otherCopies: []) == nil)
        #expect(message(for: nil, otherCopies: [URL(fileURLWithPath: "/x/uDeck.app")]) == nil,
                "another copy existing is not itself a problem")
    }

    @Test("a record that went away carries the copies that might explain it")
    func vanishedNamesCopies() {
        let debug = URL(fileURLWithPath: "/Users/x/Applications/uDeck-debug.app")
        #expect(message(for: .recordVanished, otherCopies: [debug]) == .vanished(otherCopies: [debug]))
        #expect(message(for: .recordVanished, otherCopies: []) == .vanished(otherCopies: []),
                "and says it plainly when there is nothing to name")
    }

    @Test("a refusal to take carries them too, for the same reason")
    func didNotTakeNamesCopies() {
        let debug = URL(fileURLWithPath: "/Users/x/Applications/uDeck-debug.app")
        #expect(message(for: .didNotTake, otherCopies: [debug]) == .didNotTake(otherCopies: [debug]))
    }

    @Test("approval and failure are passed through unchanged")
    func others() {
        #expect(message(for: .waitsForApproval, otherCopies: []) == .waitsForApproval)
        #expect(message(for: .couldNotAsk(reason: "nope"), otherCopies: []) == .couldNotAsk(reason: "nope"))
    }
}

/// What the review of stage 2 found: the card told the truth once and then lost it, and in
/// one case told an untruth that pointed at an innocent second copy.
@Suite("What the card keeps saying")
struct LoginItemPersistenceTests {
    let noon = Date(timeIntervalSince1970: 1_789_000_000)

    func reading(_ state: LoginItemState, _ after: TimeInterval = 0) -> LoginItemReading {
        LoginItemReading(state: state, at: noon + after)
    }

    /// The card's own button sends the operator to System Settings; coming back is a
    /// reading. Before this, that reading wiped the headline, the named copy and the
    /// button, leaving an off switch with no explanation.
    @Test("an on the system did not take is still said after the card reads again")
    func didNotTakeSurvives() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.systemHasNoRecord))
        judgement.operatorAsked(toOpen: true)
        judgement.read(reading(.systemHasNoRecord, 1))
        #expect(judgement.trouble == .didNotTake)

        judgement.read(reading(.systemHasNoRecord, 2))
        #expect(judgement.trouble == .didNotTake, "the same answer is not news")
    }

    @Test("and it stops being said when the answer changes")
    func didNotTakeEnds() {
        var judgement = LoginItemJudgement()
        judgement.operatorAsked(toOpen: true)
        judgement.read(reading(.systemHasNoRecord, 1))
        #expect(judgement.trouble == .didNotTake)

        judgement.read(reading(.opens, 2))
        #expect(judgement.trouble == nil)
    }

    /// The reason lives nowhere else on screen — the rest of it is in a debug log nobody
    /// reads — so a reading that brings a real state must not take it away.
    @Test("a failure to ask keeps its reason until something works")
    func couldNotAskSurvives() {
        var judgement = LoginItemJudgement()
        judgement.operatorAsked(toOpen: true)
        judgement.read(reading(.couldNotAsk(reason: "Operation not permitted"), 1))
        judgement.read(reading(.systemHasNoRecord, 2))
        #expect(judgement.trouble == .couldNotAsk(reason: "Operation not permitted"))

        judgement.read(reading(.opens, 3))
        #expect(judgement.trouble == nil)
    }

    /// Asking again is an answer of its own, and the answer decides: a retry that the
    /// system declines is "it did not take it", not the old error text.
    @Test("a fresh request replaces the sentence the old one earned")
    func askingAgainReplacesIt() {
        var judgement = LoginItemJudgement()
        judgement.operatorAsked(toOpen: true)
        judgement.read(reading(.couldNotAsk(reason: "Operation not permitted"), 1))
        #expect(judgement.trouble != nil)

        judgement.operatorAsked(toOpen: true)
        judgement.read(reading(.doesNot, 2))
        #expect(judgement.trouble == .didNotTake, "the retry's own answer, not the old error")
    }

    /// The rule on its own, without the reading that also happens to clear the latch: an
    /// off the system is holding is silence even when uDeck watched it open earlier.
    @Test("an off the system holds is silence even after it had been opening")
    func offIsNeverADisappearance() {
        #expect(LoginItemJudgement.trouble(for: .doesNot, asked: nil, hadBeenOpening: true) == nil)
        #expect(LoginItemJudgement.trouble(for: .systemHasNoRecord, asked: nil, hadBeenOpening: true) == .recordVanished)
    }

    /// The untruth: the operator switches it off in Login Items & Extensions, and uDeck
    /// reports a record that "went away" and names a second copy as the likely thief.
    @Test("switching it off in System Settings is not a record that went away")
    func offInSystemSettings() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.opens))
        judgement.read(reading(.doesNot, 60))
        #expect(judgement.trouble == nil)
        #expect(!judgement.opensAtLogin)
    }

    /// And once the system has said so, a later "no record at all" is not retro-labelled
    /// against a moment that was already accounted for.
    @Test("a reconciled off does not become a disappearance later")
    func reconciledStaysQuiet() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.opens))
        judgement.read(reading(.doesNot, 60))
        judgement.read(reading(.systemHasNoRecord, 120))
        #expect(judgement.trouble == nil)
    }

    /// What must NOT be lost while fixing the above: the measured failure is still said.
    @Test("the record vanishing outright is still said")
    func vanishedStillSaid() {
        var judgement = LoginItemJudgement()
        judgement.read(reading(.opens))
        judgement.read(reading(.systemHasNoRecord, 60))
        #expect(judgement.trouble == .recordVanished)
    }

    // MARK: - Which copies may be registered at all

    /// The foot-gun this answers: the linker embeds uDeck's Info.plist — release bundle
    /// identifier and all — into the bare binary, so `swift build && .build/debug/uDeck`
    /// draws a live switch that would ask macOS to open a path under `.build` in the
    /// installed copy's name.
    @Test("a development build is not a copy the system can be asked to open")
    func bareBinaryIsNotInstalled() {
        #expect(!isAnInstalledCopy(URL(fileURLWithPath: "/Users/x/udeck/.build/arm64-apple-macosx/debug")))
        #expect(!isAnInstalledCopy(URL(fileURLWithPath: "/Users/x/udeck/.build/debug/uDeck")))
    }

    /// The test is the bundle, not the folder: the copy in `~/Applications` is a real
    /// install and the likeliest one to be in use while somebody works on uDeck.
    @Test("an application bundle is one, wherever it was put")
    func bundlesAnywhereAreInstalled() {
        #expect(isAnInstalledCopy(URL(fileURLWithPath: "/Applications/uDeck.app")))
        #expect(isAnInstalledCopy(URL(fileURLWithPath: "/Users/x/Applications/uDeck-debug.app")))
        #expect(isAnInstalledCopy(URL(fileURLWithPath: "/Volumes/uDeck/uDeck.app")))
    }

    /// Two ways to write the rule that look right and are not: matching the *end* of the
    /// name rather than the extension, and comparing the extension case-sensitively on a
    /// volume that does not.
    @Test("the rule is the extension, and case is not part of it")
    func neitherSuffixNorCase() {
        // Both of these end in the three letters and have no extension at all — the
        // first pair written here ended in "rap" and "tap", and let the suffix version
        // of the rule through.
        #expect(!isAnInstalledCopy(URL(fileURLWithPath: "/Users/x/Workspace/myapp")))
        #expect(!isAnInstalledCopy(URL(fileURLWithPath: "/Users/x/bin/webapp")))
        #expect(isAnInstalledCopy(URL(fileURLWithPath: "/Applications/uDeck.APP")))
    }
}
