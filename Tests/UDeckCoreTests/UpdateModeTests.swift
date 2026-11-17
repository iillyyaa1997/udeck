import Foundation
import Testing
@testable import UDeckCore

/// What uDeck does with a version a check of its own found, and when it says so
/// in a notification (`UpdateMode`, `UpdateNotice`).
@Suite("Update mode and notices")
struct UpdateModeTests {
    // MARK: - The mode

    @Test("what each mode asks of Sparkle and of uDeck")
    func whatEachModeMeans() {
        #expect(!UpdateMode.tell.downloadsAhead && !UpdateMode.tell.restartsByItself)
        #expect(UpdateMode.downloadAhead.downloadsAhead && !UpdateMode.downloadAhead.restartsByItself)
        #expect(UpdateMode.installByItself.downloadsAhead && UpdateMode.installByItself.restartsByItself)
        #expect(UpdateMode.shipped == .installByItself, "as uDeck has updated since 0.8.1")
    }

    @Test("a mode kept is the mode read")
    func aKeptModeIsRead() {
        for mode in UpdateMode.allCases {
            for downloads in [true, false] {
                #expect(UpdateMode.kept(mode.rawValue, automaticallyDownloads: downloads) == mode)
            }
        }
    }

    @Test("the first launch after 0.8.5 reads what its one switch meant")
    func fromOneSwitch() {
        #expect(UpdateMode.kept(nil, automaticallyDownloads: true) == .installByItself)
        #expect(UpdateMode.kept(nil, automaticallyDownloads: false) == .tell)
        #expect(UpdateMode.kept("sometimes", automaticallyDownloads: false) == .tell, "a value no release wrote")
    }

    // MARK: - Notices

    @Test("found: said whatever the mode, with Update and Later")
    func found() {
        for mode in UpdateMode.allCases {
            let notice = UpdateNotice.after(.foundByItself(version: "0.8.7"), mode: mode, notifies: true, notifiedVersion: nil)
            #expect(notice == .found(version: "0.8.7"))
            #expect(notice?.offersUpdate == true)
        }
    }

    @Test("downloaded: said in downloadAhead only — installByItself says so after the restart")
    func downloaded() {
        let event = UpdateEvent.downloaded(version: "0.8.7")
        #expect(UpdateNotice.after(event, mode: .downloadAhead, notifies: true, notifiedVersion: nil) == .downloaded(version: "0.8.7"))
        #expect(UpdateNotice.after(event, mode: .installByItself, notifies: true, notifiedVersion: nil) == nil)
        #expect(UpdateNotice.after(event, mode: .tell, notifies: true, notifiedVersion: nil) == nil)
        #expect(UpdateNotice.downloaded(version: "0.8.7").offersUpdate)
    }

    @Test("updated: after a launch into the version uDeck restarted into by itself, without buttons")
    func updated() {
        for mode in UpdateMode.allCases {
            let notice = UpdateNotice.after(.launched(running: "0.8.7", restartedInto: "0.8.7"),
                                            mode: mode, notifies: true, notifiedVersion: nil)
            #expect(notice == .updated(version: "0.8.7"))
            #expect(notice?.offersUpdate == false)
        }
    }

    @Test("no updated notice after Update pressed, another restart, or a first launch")
    func notUpdated() {
        // Update pressed notes nothing; a restart by itself into 0.8.6 that was
        // refused and then replaced by hand runs something else.
        for restartedInto in [nil, "0.8.6", "0.8.8"] as [String?] {
            let event = UpdateEvent.launched(running: "0.8.7", restartedInto: restartedInto)
            #expect(UpdateNotice.after(event, mode: .installByItself, notifies: true, notifiedVersion: nil) == nil,
                    "restarted into \(restartedInto ?? "nothing")")
        }
    }

    @Test("switched off, nothing is said")
    func switchedOff() {
        let events: [UpdateEvent] = [
            .foundByItself(version: "0.8.7"), .downloaded(version: "0.8.7"),
            .launched(running: "0.8.7", restartedInto: "0.8.7"),
        ]
        for event in events {
            for mode in UpdateMode.allCases {
                #expect(UpdateNotice.after(event, mode: mode, notifies: false, notifiedVersion: nil) == nil)
            }
        }
    }

    @Test("one notice per version, whatever its kind: Later means not about this version again")
    func oncePerVersion() {
        #expect(UpdateNotice.after(.foundByItself(version: "0.8.7"), mode: .tell, notifies: true,
                                   notifiedVersion: "0.8.7") == nil)
        #expect(UpdateNotice.after(.downloaded(version: "0.8.7"), mode: .downloadAhead, notifies: true,
                                   notifiedVersion: "0.8.7") == nil, "found, Later, then switched to download ahead")
        #expect(UpdateNotice.after(.launched(running: "0.8.7", restartedInto: "0.8.7"), mode: .installByItself,
                                   notifies: true, notifiedVersion: "0.8.7") == nil)
        #expect(UpdateNotice.after(.foundByItself(version: "0.8.8"), mode: .tell, notifies: true,
                                   notifiedVersion: "0.8.7") == .found(version: "0.8.8"), "a newer version is news")
        let keys = [UpdateNotice.found(version: "1.0.0"), .downloaded(version: "1.0.0"), .updated(version: "1.0.0")].map(\.key)
        #expect(Set(keys).count == 3, "the log tells the kinds apart")
    }

    @Test("what's new opens the release's page")
    func whatsNew() {
        #expect(ReleaseNotes.page(for: "0.8.6")?.absoluteString == "https://github.com/iillyyaa1997/udeck/releases/tag/v0.8.6")
        #expect(ReleaseNotes.page(for: "../etc") == nil)
    }
}
