import CoreGraphics
import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormat
import UDeckPluginFormatFixtures

/// When uDeck may restart into an update it put in place by itself, and the
/// settings window it opens again after (`RestartHold`, `SettingsUse`,
/// `SettingsPlace`).
@Suite("Restarting into an update")
struct UpdateRestartTests {
    let temp = TemporaryDirectory()

    // MARK: - Settings in use

    @Test("the night of 2026-11-17: open behind other windows, untouched for hours, it holds nothing")
    func aWindowForgottenOpenDoesNotHold() {
        // 0.8.1 held its restart for as long as the window was on the screen:
        // three and a half hours that night, until it was closed.
        #expect(!SettingsUse.inUse(shown: true, inFront: false, sinceTouched: 3.5 * 3600, sinceAnyInput: 4))
        #expect(!SettingsUse.inUse(shown: true, inFront: false, sinceTouched: nil, sinceAnyInput: 4))
    }

    @Test("touched in the last three minutes, it holds — in front or not")
    func aWindowJustTouchedHolds() {
        for inFront in [true, false] {
            #expect(SettingsUse.inUse(shown: true, inFront: inFront, sinceTouched: 0, sinceAnyInput: 900))
            #expect(SettingsUse.inUse(shown: true, inFront: inFront, sinceTouched: 179, sinceAnyInput: nil))
        }
        #expect(!SettingsUse.inUse(shown: true, inFront: false, sinceTouched: 180, sinceAnyInput: 0),
                "three minutes untouched, and behind: no longer in use")
    }

    @Test("in front of somebody at the Mac, it holds — ten minutes of stillness, thirty from the last touch")
    func aWindowInFrontHoldsWhileSomebodyIsThere() {
        #expect(SettingsUse.inUse(shown: true, inFront: true, sinceTouched: 900, sinceAnyInput: 5),
                "read without a click for a quarter of an hour, the pointer still moving")
        #expect(SettingsUse.inUse(shown: true, inFront: true, sinceTouched: 900, sinceAnyInput: 599),
                "a reader's hands still for nearly ten minutes")
        #expect(!SettingsUse.inUse(shown: true, inFront: true, sinceTouched: 900, sinceAnyInput: 600),
                "in front with nobody at the Mac")
        #expect(!SettingsUse.inUse(shown: true, inFront: true, sinceTouched: 1800, sinceAnyInput: 1),
                "a pointer something keeps nudging is not somebody reading for ever")
        #expect(!SettingsUse.inUse(shown: true, inFront: true, sinceTouched: nil, sinceAnyInput: 1),
                "opened again after a restart and never touched: nobody chose it")
        #expect(!SettingsUse.inUse(shown: true, inFront: true, sinceTouched: 900, sinceAnyInput: nil),
                "no idle time to be had is not somebody at the Mac")
        #expect(!SettingsUse.inUse(shown: true, inFront: false, sinceTouched: 900, sinceAnyInput: 1),
                "behind, the same stillness holds nothing")
    }

    @Test("a form open in it holds for half an hour from the last touch — then it is a window forgotten")
    func aFormOpenHoldsLonger() {
        // A source being added, its token being made in a browser meanwhile.
        #expect(SettingsUse.inUse(shown: true, inFront: false, sinceTouched: 25 * 60, sinceAnyInput: 1, formOpen: true))
        #expect(!SettingsUse.inUse(shown: true, inFront: false, sinceTouched: 25 * 60, sinceAnyInput: 1, formOpen: false))
        #expect(!SettingsUse.inUse(shown: true, inFront: false, sinceTouched: 30 * 60, sinceAnyInput: 1, formOpen: true))
        #expect(!SettingsUse.inUse(shown: true, inFront: true, sinceTouched: 3.5 * 3600, sinceAnyInput: 1, formOpen: true),
                "a form left open all night holds nothing")
        #expect(!SettingsUse.inUse(shown: false, inFront: false, sinceTouched: 0, sinceAnyInput: 0, formOpen: true))
    }

    @Test("a window not on the screen holds nothing, however recently touched")
    func aClosedWindowHoldsNothing() {
        #expect(!SettingsUse.inUse(shown: false, inFront: true, sinceTouched: 0, sinceAnyInput: 0))
    }

    // MARK: - What holds

    @Test("nothing under way: no hold")
    func nothingHolds() {
        #expect(RestartHold.first(panelOut: false, settingsInUse: false, signIn: false,
                                  pluginOperation: false, cardAction: false) == nil)
    }

    @Test("each alone is the hold, and with all of them the panel is said first")
    func eachHolds() {
        #expect(RestartHold.first(panelOut: true, settingsInUse: false, signIn: false, pluginOperation: false, cardAction: false) == .panel)
        #expect(RestartHold.first(panelOut: false, settingsInUse: true, signIn: false, pluginOperation: false, cardAction: false) == .settings)
        #expect(RestartHold.first(panelOut: false, settingsInUse: false, signIn: true, pluginOperation: false, cardAction: false) == .signIn)
        #expect(RestartHold.first(panelOut: false, settingsInUse: false, signIn: false, pluginOperation: true, cardAction: false) == .pluginOperation)
        #expect(RestartHold.first(panelOut: false, settingsInUse: false, signIn: false, pluginOperation: false, cardAction: true) == .cardAction)
        #expect(RestartHold.first(panelOut: true, settingsInUse: true, signIn: true, pluginOperation: true, cardAction: true) == .panel)
        #expect(Set(RestartHold.allCases.map(\.reason)).count == RestartHold.allCases.count, "each says its own reason")
    }

    // MARK: - Where Settings was

    func store() -> JSONFileStore<SettingsPlace> {
        JSONFileStore(url: UDeckPaths(root: temp.url).settingsToReopenFile)
    }

    func place(savedAt: Date) -> SettingsPlace {
        SettingsPlace(section: "plugins", frame: .init(CGRect(x: 120, y: 80, width: 980, height: 620)),
                      inFront: false, savedAt: savedAt)
    }

    @Test("a place written by the restart is taken by the next launch, once")
    func aFreshPlaceIsTakenOnce() throws {
        // Whole seconds: the store writes dates as ISO 8601, without fractions.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        try store().save(place(savedAt: now.addingTimeInterval(-30)))
        #expect(SettingsPlace.take(from: store(), now: now) == place(savedAt: now.addingTimeInterval(-30)))
        #expect(!FileManager.default.fileExists(atPath: store().url.path), "the file is for one launch")
        #expect(SettingsPlace.take(from: store(), now: now) == nil)
    }

    @Test("a stale place, one from a clock set back, and an unreadable file open nothing, and go")
    func aPlaceThatIsNotFreshIsDropped() throws {
        // Whole seconds, so that the first is exactly `keptFor` old once read back.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        for saved in [now.addingTimeInterval(-SettingsPlace.keptFor), now.addingTimeInterval(-86_400), now.addingTimeInterval(120)] {
            try store().save(place(savedAt: saved))
            #expect(SettingsPlace.take(from: store(), now: now) == nil, "saved \(saved.timeIntervalSince(now))s from now")
            #expect(!FileManager.default.fileExists(atPath: store().url.path))
        }
        try Data("not json".utf8).write(to: store().url)
        #expect(SettingsPlace.take(from: store(), now: now) == nil)
        #expect(!FileManager.default.fileExists(atPath: store().url.path), "an unreadable file is not left for every launch after")
        #expect(SettingsPlace.take(from: store(), now: now) == nil, "and no file at all is nothing to open")
    }

    @Test("a frame is put back only where a screen still has room for it")
    func aFrameIsPutBackOnlyOnAScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let frame = SettingsPlace.Frame(CGRect(x: 120, y: 80, width: 980, height: 620))
        #expect(frame.isOnScreen([screen]))
        #expect(!SettingsPlace.Frame(CGRect(x: 1600, y: 80, width: 980, height: 620)).isOnScreen([screen]),
                "on a display that is gone")
        #expect(!SettingsPlace.Frame(CGRect(x: 1472, y: 80, width: 980, height: 620)).isOnScreen([screen]),
                "40 points of it showing is not enough to take hold of")
        #expect(frame.isOnScreen([CGRect(x: -1920, y: 0, width: 1920, height: 1080), screen]))
        #expect(!SettingsPlace.Frame(CGRect(x: 120, y: 80, width: 0, height: 620)).isOnScreen([screen]))
    }
}
