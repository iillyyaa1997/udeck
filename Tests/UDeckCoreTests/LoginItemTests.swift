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
