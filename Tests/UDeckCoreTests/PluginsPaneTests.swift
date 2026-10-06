import Darwin
import Foundation
import Testing
@testable import UDeckCore
import UDeckPluginFormatFixtures

/// What Settings → Plugins decides before it draws or does anything: which
/// warning a button says, what the search path field does to the list, and
/// whether there is a run log to show. UDeckKit has no tests, so every one of
/// these decisions lives here.
@Suite("What a button that takes a plugin's place says first")
struct PlaceWarningTests {
    @Test("Remove: of a link, only the link goes; of the operator's work, the Trash; of uDeck's own copy, deleted")
    func removal() {
        #expect(PlaceWarning.removal(id: "uptime", link: "/work/uptime", toTrash: false)
                == .catalogueRemoveLinkConfirm(id: "uptime", target: "/work/uptime"))
        #expect(PlaceWarning.removal(id: "uptime", link: "/work/uptime", toTrash: true)
                == .catalogueRemoveLinkConfirm(id: "uptime", target: "/work/uptime"), "a link never goes to the Trash")
        #expect(PlaceWarning.removal(id: "uptime", link: nil, toTrash: true) == .catalogueRemoveOwnConfirm(id: "uptime"))
        #expect(PlaceWarning.removal(id: "uptime", link: nil, toTrash: false) == .catalogueRemoveConfirm(id: "uptime"))
    }

    @Test("Replace… over a link takes the link; over a folder of one's own, the Trash")
    func replacement() {
        #expect(PlaceWarning.replacement(id: "uptime", path: "~/.udeck/plugins", link: "/work/uptime")
                == .catalogueReplaceLinkConfirm(id: "uptime", target: "/work/uptime"))
        #expect(PlaceWarning.replacement(id: "uptime", path: "~/.udeck/plugins", link: nil)
                == .catalogueReplaceConfirm(id: "uptime", path: "~/.udeck/plugins"))
    }

    @Test("Update, Reinstall, Back to, Install this version: over a link only the link goes, as Replace… says; over changes, the Trash")
    func replacingCopy() {
        #expect(PlaceWarning.replacingCopy(id: "uptime", version: "1.3.0", link: "~/work/uptime")
                == PlaceWarning.replacement(id: "uptime", path: "~/.udeck/plugins", link: "~/work/uptime"))
        #expect(PlaceWarning.replacingCopy(id: "uptime", version: "1.3.0", link: "~/work/uptime")
                == .catalogueReplaceLinkConfirm(id: "uptime", target: "~/work/uptime"))
        #expect(PlaceWarning.replacingCopy(id: "uptime", version: "1.3.0", link: nil)
                == .catalogueUpdateOverChanges(id: "uptime", version: "1.3.0"))
    }

    /// C2b2's review: the warning named the folder chosen as `~/…` and the
    /// folder an existing link leads to as `/Users/…` — one sentence, two
    /// ways of writing a path.
    @Test("Link a folder…: the folder and where a link there leads are written the same way")
    func linkingWritesBothPathsAlike() {
        let shown = { (path: String) in SearchPathList.shown(path, home: "/Users/a") }
        #expect(PlaceWarning.linking(id: "uptime", folder: "/Users/a/work/uptime",
                                     occupant: .link(destination: "/Users/a/work/old", sameFolder: false),
                                     toTrash: false, path: "~/.udeck/plugins", shown: shown)
                == .linkFolderOverLink(id: "uptime", destination: "~/work/old", folder: "~/work/uptime"))
        #expect(PlaceWarning.linking(id: "uptime", folder: "/Users/a/work/uptime", occupant: .folderOfYourOwn,
                                     toTrash: true, path: "~/.udeck/plugins", shown: shown)
                == .linkFolderOverOwn(id: "uptime", path: "~/.udeck/plugins", folder: "~/work/uptime", toTrash: true))
        #expect(PlaceWarning.linking(id: "uptime", folder: "/Users/a/work/uptime", occupant: .installed(source: "github.com/o/r"),
                                     toTrash: false, path: "~/.udeck/plugins", shown: shown)
                == .linkFolderOverInstalled(id: "uptime", source: "github.com/o/r", folder: "~/work/uptime", toTrash: false))
    }

    @Test("Link a folder… says what becomes of what is at the id, and nothing when the id is free or already this folder")
    func linking() {
        func said(_ occupant: PluginLink.Occupant, toTrash: Bool = false) -> Phrase? {
            PlaceWarning.linking(id: "uptime", folder: "/work/uptime", occupant: occupant, toTrash: toTrash, path: "~/.udeck/plugins",
                                 shown: { $0 })
        }
        #expect(said(.nothing) == nil)
        #expect(said(.link(destination: "/work/uptime", sameFolder: true)) == nil)
        #expect(said(.installed(source: "github.com/o/r"))
                == .linkFolderOverInstalled(id: "uptime", source: "github.com/o/r", folder: "/work/uptime", toTrash: false))
        #expect(said(.installed(source: "github.com/o/r"), toTrash: true)
                == .linkFolderOverInstalled(id: "uptime", source: "github.com/o/r", folder: "/work/uptime", toTrash: true))
        #expect(said(.folderOfYourOwn, toTrash: true)
                == .linkFolderOverOwn(id: "uptime", path: "~/.udeck/plugins", folder: "/work/uptime", toTrash: true))
        #expect(said(.link(destination: "/work/old", sameFolder: false))
                == .linkFolderOverLink(id: "uptime", destination: "/work/old", folder: "/work/uptime"))
    }

    /// Settings says a refusal in the operator's language from what it is
    /// about, not from the command's English sentence.
    @Test("a folder that is no plugin's is refused with what it is about")
    func refusalReasons() throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let home = temp.url.appendingPathComponent("udeck", isDirectory: true)
        func reason(_ folder: URL) -> PluginLink.Refusal.Reason? {
            do {
                _ = try PluginLink.candidate(folder, home: home)
                return nil
            } catch let refusal as PluginLink.Refusal {
                return refusal.reason
            } catch {
                return nil
            }
        }
        let missing = temp.url.appendingPathComponent("missing")
        #expect(reason(missing) == .notThere(folder: missing.path))
        let file = temp.url.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        #expect(reason(file) == .notAFolder(folder: file.path))
        let empty = temp.url.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(reason(empty) == .noManifest(folder: empty.path))
        let broken = temp.url.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data(#"{"id": "broken"}"#.utf8).write(to: broken.appendingPathComponent("manifest.json"))
        guard case .manifestUnreadable(let manifest, let detail)? = reason(broken) else {
            Issue.record("\(String(describing: reason(broken)))"); return
        }
        #expect(manifest.hasSuffix("/broken/manifest.json") && detail.contains("is required"))
        let inside = home.appendingPathComponent("mine", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        guard case .insideUDeck? = reason(inside) else { Issue.record("\(String(describing: reason(inside)))"); return }
        guard case .holdsUDeck? = reason(temp.url) else { Issue.record("\(String(describing: reason(temp.url)))"); return }
    }
}

@Suite("Where to look for commands")
struct SearchPathListTests {
    let list = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]

    @Test("a folder added comes first, once; only a full path is added")
    func adding() {
        #expect(SearchPathList.adding("/Users/a/.pyenv/shims", to: list) == ["/Users/a/.pyenv/shims"] + list)
        #expect(SearchPathList.adding("/usr/bin", to: list) == list, "already there: as it was")
        #expect(SearchPathList.adding("bin", to: list) == list)
        #expect(SearchPathList.adding("caf\u{65}\u{301}", to: ["/caf\u{E9}"]) == ["/caf\u{E9}"], "not a full path")
        #expect(SearchPathList.adding("/caf\u{65}\u{301}", to: ["/caf\u{E9}"]) == ["/caf\u{65}\u{301}", "/caf\u{E9}"],
                "two spellings are two folders where the disk keeps them apart")
    }

    @Test("a folder can go unless it is the last one looked in")
    func removing() {
        #expect(SearchPathList.removing(at: 1, from: list) == ["/usr/local/bin", "/usr/bin", "/bin"])
        #expect(SearchPathList.canRemove(at: 0, from: ["/bin", "bin"]) == false, "what would be left finds nothing")
        #expect(SearchPathList.removing(at: 0, from: ["/bin"]) == ["/bin"])
        #expect(SearchPathList.canRemove(at: 1, from: ["/bin", "bin"]), "one never looked in can go")
        #expect(SearchPathList.canRemove(at: 9, from: list) == false)
    }

    @Test("a folder moves one place up or down, and stays at either end")
    func moving() {
        #expect(SearchPathList.moving(at: 2, by: -1, in: list) == ["/usr/local/bin", "/usr/bin", "/opt/homebrew/bin", "/bin"])
        #expect(SearchPathList.moving(at: 2, by: 1, in: list) == ["/usr/local/bin", "/opt/homebrew/bin", "/bin", "/usr/bin"])
        #expect(SearchPathList.moving(at: 0, by: -1, in: list) == list)
        #expect(SearchPathList.moving(at: 3, by: 1, in: list) == list)
        #expect(SearchPathList.moving(at: 0, by: 2, in: list) == list)
        #expect(SearchPathList.defaults == PluginEnvironment.defaultSearchPath)
    }

    @Test("each folder says whether it is looked in, is not there, is not a folder, or is not a full path")
    func standing() throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let file = temp.url.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        #expect(SearchPathList.standing(of: temp.url.path) == .lookedIn)
        #expect(SearchPathList.standing(of: temp.url.appendingPathComponent("not-yet").path) == .notThere)
        #expect(SearchPathList.standing(of: file.path) == .notAFolder)
        #expect(SearchPathList.standing(of: "bin") == .notAFullPath)
        #expect(SearchPathList.standing(of: "~/bin") == .notAFullPath)
    }

    @Test("the home folder is shown as ~, and only for display")
    func shown() {
        #expect(SearchPathList.shown("/Users/a/.pyenv/shims", home: "/Users/a") == "~/.pyenv/shims")
        #expect(SearchPathList.shown("/Users/a", home: "/Users/a") == "~")
        #expect(SearchPathList.shown("/Users/ab/bin", home: "/Users/a") == "/Users/ab/bin")
        #expect(SearchPathList.shown("/usr/bin", home: "/Users/a/") == "/usr/bin")
        #expect(SearchPathList.shown("/Users/a/bin", home: "/Users/a/") == "~/bin")
    }

    /// A list with no folder looked in finds nothing: the default instead, as
    /// `udeck-plugin run` reads the same file.
    @Test("settings with no folder written from / come to the default; one such folder among others is kept")
    func settingsComeToTheDefault() throws {
        for written in [#"{"pluginExecutableSearchPath": []}"#, #"{"pluginExecutableSearchPath": ["bin", "~/bin"]}"#] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(written.utf8)).validated()
            #expect(settings.pluginExecutableSearchPath == PluginEnvironment.defaultSearchPath, "\(written)")
        }
        let mixed = try JSONDecoder().decode(AppSettings.self,
                                             from: Data(#"{"pluginExecutableSearchPath": ["bin", "/opt/x"]}"#.utf8)).validated()
        #expect(mixed.pluginExecutableSearchPath == ["bin", "/opt/x"], "kept as written; Settings says bin is not looked in")
    }
}

@Suite("Show the logs")
struct RunLogShownTests {
    @Test("there is something to show once a run log is a file in the logs folder")
    func anyWritten() throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let paths = temp.paths
        #expect(!RunLog.anyWritten(in: paths), "no logs folder")
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: paths.logs.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(atPath: paths.logs.appendingPathComponent("linked.log").path,
                                                   withDestinationPath: "/etc/hosts")
        #expect(!RunLog.anyWritten(in: paths), "neither a file of another kind nor a link is a log")
        try Data("x".utf8).write(to: paths.logs.appendingPathComponent("greeter.log.1"))
        #expect(RunLog.anyWritten(in: paths))
    }
}

@Suite("Install command")
struct CommandInstallTests {
    /// A uDeck bundle of the test's own, with the command inside it where
    /// make-app.sh puts it, and an account's `~/.local/bin` of its own: never
    /// the real one.
    struct Place {
        let temp = TemporaryDirectory()
        var home: URL { temp.url.appendingPathComponent("home", isDirectory: true) }
        var folder: URL { CommandInstall.folder(home: home.path) }

        func bundle(_ name: String = "uDeck.app") throws -> URL {
            let bundle = temp.url.appendingPathComponent("Applications/\(name)", isDirectory: true)
            let helper = bundle.appendingPathComponent(CommandInstall.inBundle)
            try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho udeck-plugin\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            return bundle
        }

        func install(from bundle: URL?, place: BundlePlace = .lasting, renames: FolderRenames = .system) -> CommandInstall {
            CommandInstall(helper: bundle.flatMap(CommandInstall.helper(in:)), folder: folder, place: place, renames: renames)
        }

        /// Everything in `~/.local/bin`: nothing left beside the command.
        func names() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        }
    }

    /// The first of the calls it is asked about, once: what a test puts at
    /// the command's place between a look and the step that acts on it.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func first() -> Bool {
            lock.withLock {
                defer { done = true }
                return !done
            }
        }
    }

    static let mine = Data("#!/bin/sh\necho mine\n".utf8)

    @Test("installed: a link in ~/.local/bin, made with the folder, to the command inside the bundle; removed: the link alone")
    func installAndRemove() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let bundle = try place.bundle()
        let command = place.install(from: bundle)
        #expect(command.link.path == place.home.path + "/.local/bin/udeck-plugin")
        #expect(command.state() == .notInstalled)
        try command.install()
        #expect(command.state() == .installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: command.link.path)
                == bundle.appendingPathComponent(CommandInstall.inBundle).path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: place.folder.path) == ["udeck-plugin"],
                "nothing left beside it")
        try command.install()
        #expect(command.state() == .installed, "again: as it was")
        try command.remove()
        #expect(command.state() == .notInstalled)
        #expect(FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent(CommandInstall.inBundle).path),
                "what it led to stays")
    }

    @Test("a link to another uDeck's command is uDeck's: said, pointed at this one on Install, taken by Remove")
    func otherCopy() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let old = try place.bundle("uDeck old.app")
        try place.install(from: old).install()
        let current = try place.bundle()
        let command = place.install(from: current)
        let oldCommand = old.appendingPathComponent(CommandInstall.inBundle).path
        #expect(command.state() == .otherCopy(target: oldCommand))
        try FileManager.default.removeItem(at: old)
        #expect(command.state() == .otherCopy(target: oldCommand), "whether or not that copy is still there")
        try command.install()
        #expect(command.state() == .installed)

        try place.install(from: try place.bundle("uDeck old.app")).install()
        try command.remove()
        #expect(command.state() == .notInstalled)
    }

    @Test("anything that is not uDeck's is left exactly as it is, and said")
    func foreign() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let command = place.install(from: try place.bundle())
        try FileManager.default.createDirectory(at: place.folder, withIntermediateDirectories: true)

        try Data("#!/bin/sh\necho mine\n".utf8).write(to: command.link)
        #expect(command.state() == .foreign(.file))
        #expect(throws: CommandInstall.Refusal.foreign(.file)) { try command.install() }
        #expect(throws: CommandInstall.Refusal.foreign(.file)) { try command.remove() }
        #expect(try Data(contentsOf: command.link) == Data("#!/bin/sh\necho mine\n".utf8))

        try FileManager.default.removeItem(at: command.link)
        try FileManager.default.createSymbolicLink(atPath: command.link.path, withDestinationPath: "/opt/other/udeck-plugin")
        #expect(command.state() == .foreign(.link(to: "/opt/other/udeck-plugin")))
        #expect(throws: CommandInstall.Refusal.foreign(.link(to: "/opt/other/udeck-plugin"))) { try command.install() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: command.link.path) == "/opt/other/udeck-plugin")

        try FileManager.default.removeItem(at: command.link)
        try FileManager.default.createDirectory(at: command.link, withIntermediateDirectories: true)
        #expect(command.state() == .foreign(.folder))
    }

    @Test("a uDeck without the command inside it — a development build — installs nothing")
    func noHelper() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let command = place.install(from: nil)
        #expect(command.helper == nil)
        #expect(throws: CommandInstall.Refusal.noHelper) { try command.install() }
        #expect(!FileManager.default.fileExists(atPath: place.folder.path), "nothing made")
        let notExecutable = place.temp.url.appendingPathComponent("Plain.app", isDirectory: true)
        try FileManager.default.createDirectory(at: notExecutable.appendingPathComponent("Contents/Helpers"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: notExecutable.appendingPathComponent(CommandInstall.inBundle))
        #expect(CommandInstall.helper(in: notExecutable) == nil, "a file that cannot be run is no command")
    }

    /// A link written through another path to the same bundle — a folder
    /// reached through a link of its own — is this uDeck's command all the
    /// same: Install leaves it, and it is not "another copy".
    @Test("a link to this uDeck's command through another path to the same file is installed")
    func throughAnotherPath() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let bundle = try place.bundle()
        let alias = place.temp.url.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: bundle.deletingLastPathComponent().path)
        let through = alias.appendingPathComponent("uDeck.app/\(CommandInstall.inBundle)").path
        try FileManager.default.createDirectory(at: place.folder, withIntermediateDirectories: true)
        let command = place.install(from: bundle)
        try FileManager.default.createSymbolicLink(atPath: command.link.path, withDestinationPath: through)
        #expect(command.state() == .installed)
        try command.install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: command.link.path) == through, "left as it was")
    }

    /// Sparkle replaces the bundle at the path it had: the link leads to the
    /// command of whichever uDeck is there, and that is this one.
    @Test("an update in place keeps the command installed, by the new bundle and the old")
    func updatedInPlace() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let bundle = try place.bundle()
        try place.install(from: bundle).install()
        try FileManager.default.removeItem(at: bundle)
        _ = try place.bundle()
        let updated = place.install(from: bundle)
        #expect(updated.state() == .installed)
        try updated.install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: updated.link.path)
                == bundle.appendingPathComponent(CommandInstall.inBundle).path)
    }

    /// Opened where it was downloaded, macOS runs uDeck from a copy that goes
    /// when it quits; opened on its disk image, from a volume that goes when
    /// it is ejected. No link is made to either — and a link that is there
    /// can still be taken away.
    @Test("a uDeck that will not stay where it is makes no link, and says why")
    func notLasting() throws {
        for where_ in [BundlePlace.translocated, .diskImage(volume: "/Volumes/uDeck")] {
            let place = Place()
            defer { withExtendedLifetime(place) {} }
            let bundle = try place.bundle()
            let command = place.install(from: bundle, place: where_)
            #expect(throws: CommandInstall.Refusal.temporaryPlace(where_)) { try command.install() }
            #expect(!FileManager.default.fileExists(atPath: place.folder.path), "nothing made")
            try place.install(from: bundle).install()
            try command.remove()
            #expect(command.state() == .notInstalled)
        }
    }

    @Test("where uDeck runs from: translocated by the system's word or the path, a read-only volume under /Volumes, anywhere else lasting")
    func bundlePlace() {
        #expect(BundlePlace.of(bundle: "/Applications/uDeck.app", translocated: false, readOnlyVolume: false) == .lasting)
        #expect(BundlePlace.of(bundle: "/Users/a/Downloads/uDeck.app", translocated: true, readOnlyVolume: true) == .translocated)
        #expect(BundlePlace.of(bundle: "/private/var/folders/xy/z1/T/AppTranslocation/5F3E2A10-7C1B-4F7A-9E3D-0B1C2D3E4F50/d/uDeck.app",
                               translocated: false, readOnlyVolume: true) == .translocated, "the path, when the system cannot say")
        #expect(BundlePlace.of(bundle: "/Users/a/AppTranslocationNotes/uDeck.app", translocated: false, readOnlyVolume: false)
                == .lasting, "the folder's whole name")
        #expect(BundlePlace.of(bundle: "/Volumes/uDeck 0.5/uDeck.app", translocated: false, readOnlyVolume: true)
                == .diskImage(volume: "/Volumes/uDeck 0.5"))
        #expect(BundlePlace.of(bundle: "/Volumes/caf\u{65}\u{301}/uDeck.app", translocated: false, readOnlyVolume: true)
                == .diskImage(volume: "/Volumes/caf\u{65}\u{301}"))
        #expect(BundlePlace.of(bundle: "/Volumes/External/Applications/uDeck.app", translocated: false, readOnlyVolume: false)
                == .lasting, "a disk of one's own, written to")
        #expect(BundlePlace.of(bundle: "Volumes/x/uDeck.app", translocated: false, readOnlyVolume: true) == .lasting)
    }

    /// Something put at the command's place between the look and the rename:
    /// the rename is the system's `RENAME_EXCL`, which fails rather than
    /// replace it, and what is there is looked at again and said.
    @Test("a file put at the place after it was found empty is left as it is, and said")
    func appearedWhereNothingWas() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let link = place.folder.appendingPathComponent(CommandInstall.name)
        let once = Once()
        let renames = FolderRenames(exchange: FolderRenames.system.exchange, exclusive: { from, to in
            if once.first() { try? Self.mine.write(to: link) }
            return FolderRenames.system.exclusive(from, to)
        })
        let command = place.install(from: try place.bundle(), renames: renames)
        #expect(throws: CommandInstall.Refusal.foreign(.file)) { try command.install() }
        #expect(try Data(contentsOf: link) == Self.mine)
        #expect(try place.names() == [CommandInstall.name], "nothing left beside it")
    }

    /// Another uDeck's link taken away, and a file of somebody else's put in
    /// its place, between the look and the exchange: what the exchange took
    /// out of the place is read, and put back.
    @Test("a file put in place of another uDeck's link before the exchange is put back, and said")
    func appearedWhereAnotherCopyWas() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        try place.install(from: try place.bundle("uDeck old.app")).install()
        let link = place.folder.appendingPathComponent(CommandInstall.name)
        let once = Once()
        let renames = FolderRenames(exchange: { from, to in
            if once.first() {
                try? FileManager.default.removeItem(at: to)
                try? Self.mine.write(to: to)
            }
            return FolderRenames.system.exchange(from, to)
        }, exclusive: FolderRenames.system.exclusive)
        let command = place.install(from: try place.bundle(), renames: renames)
        #expect(command.state() == .otherCopy(target: place.temp.url.appendingPathComponent(
            "Applications/uDeck old.app/\(CommandInstall.inBundle)").path))
        #expect(throws: CommandInstall.Refusal.foreign(.file)) { try command.install() }
        #expect(try Data(contentsOf: link) == Self.mine)
        #expect(try place.names() == [CommandInstall.name], "nothing left beside it")
    }

    @Test("another uDeck's link gone before the exchange: the link goes where nothing is now")
    func anotherCopyWent() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        try place.install(from: try place.bundle("uDeck old.app")).install()
        let once = Once()
        let renames = FolderRenames(exchange: { from, to in
            if once.first() { try? FileManager.default.removeItem(at: to) }
            return FolderRenames.system.exchange(from, to)
        }, exclusive: FolderRenames.system.exclusive)
        let command = place.install(from: try place.bundle(), renames: renames)
        try command.install()
        #expect(command.state() == .installed)
        #expect(try place.names() == [CommandInstall.name])
    }

    @Test("a file put in place of the link before Remove takes it is put back, and said")
    func appearedBeforeRemove() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let bundle = try place.bundle()
        try place.install(from: bundle).install()
        let link = place.folder.appendingPathComponent(CommandInstall.name)
        let once = Once()
        let renames = FolderRenames(exchange: FolderRenames.system.exchange, exclusive: { from, to in
            if once.first() {
                try? FileManager.default.removeItem(at: from)
                try? Self.mine.write(to: from)
            }
            return FolderRenames.system.exclusive(from, to)
        })
        #expect(throws: CommandInstall.Refusal.foreign(.file)) { try place.install(from: bundle, renames: renames).remove() }
        #expect(try Data(contentsOf: link) == Self.mine)
        #expect(try place.names() == [CommandInstall.name], "nothing left beside it")
    }

    /// C2b2's review: a file put in place of another uDeck's link before the
    /// exchange is put back by a second exchange — and that one takes out of
    /// the place whatever is there by then. Something put there between the
    /// two exchanges was deleted unread; it stays now, and the refusal says
    /// where it is.
    @Test("what the exchange back takes out of the place is deleted only when it is the link made here")
    func appearedBetweenTheExchanges() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        try place.install(from: try place.bundle("uDeck old.app")).install()
        let link = place.folder.appendingPathComponent(CommandInstall.name)
        let theirs = Data("#!/bin/sh\necho theirs\n".utf8)
        let calls = Calls()
        let renames = FolderRenames(exchange: { from, to in
            switch calls.next() {
            case 1:
                // Before the first exchange: another uDeck's link replaced by a file.
                try? FileManager.default.removeItem(at: to)
                try? Self.mine.write(to: to)
            case 2:
                // Before the exchange back: the link made here replaced by another file.
                try? FileManager.default.removeItem(at: to)
                try? theirs.write(to: to)
            default:
                break
            }
            return FolderRenames.system.exchange(from, to)
        }, exclusive: FolderRenames.system.exclusive)
        let command = place.install(from: try place.bundle(), renames: renames)
        do {
            try command.install()
            Issue.record("installed over two files of somebody else's")
        } catch let refusal as CommandInstall.Refusal {
            guard case .cannotWrite(let said) = refusal else {
                Issue.record("refused with \(refusal), not with where the second file is")
                return
            }
            let beside = try place.names().filter { $0 != CommandInstall.name }
            #expect(beside.count == 1, "the second file kept beside the place: \(beside)")
            if let name = beside.first {
                #expect(try Data(contentsOf: place.folder.appendingPathComponent(name)) == theirs)
                #expect(said.contains(place.folder.appendingPathComponent(name).path), "the refusal says where it is: \(said)")
            }
        }
        #expect(try Data(contentsOf: link) == Self.mine, "the first file is back at the place")
        #expect(calls.count == 2)
    }

    /// Counts the calls it is asked about, for a test that acts on the second.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0

        func next() -> Int {
            lock.withLock {
                made += 1
                return made
            }
        }

        var count: Int { lock.withLock { made } }
    }

    /// The button is not offered where it can only be refused: the line
    /// above it says why (C2b2's review: a comment said "not offered" of a
    /// button shown greyed out).
    @Test("Install is offered only by a uDeck with the command inside it, where it stays; Remove over a uDeck's link from anywhere")
    func buttons() throws {
        let place = Place()
        defer { withExtendedLifetime(place) {} }
        let bundle = try place.bundle()
        let lasting = place.install(from: bundle)
        #expect(lasting.buttons(for: .notInstalled) == [.install])
        #expect(lasting.buttons(for: .otherCopy(target: "/Old/uDeck.app/Contents/Helpers/udeck-plugin")) == [.install, .remove])
        #expect(lasting.buttons(for: .installed) == [.remove])
        #expect(lasting.buttons(for: .foreign(.file)).isEmpty)
        #expect(lasting.buttons(for: .foreign(.link(to: "/opt/x"))).isEmpty)
        for where_ in [BundlePlace.translocated, .diskImage(volume: "/Volumes/uDeck")] {
            let passing = place.install(from: bundle, place: where_)
            #expect(passing.buttons(for: .notInstalled).isEmpty, "\(where_)")
            #expect(passing.buttons(for: .otherCopy(target: "/Old/uDeck.app/Contents/Helpers/udeck-plugin")) == [.remove])
            #expect(passing.buttons(for: .installed) == [.remove])
        }
        let development = place.install(from: nil)
        #expect(development.buttons(for: .notInstalled).isEmpty, "a development build has no command to link")
        #expect(development.buttons(for: .otherCopy(target: "/Old/uDeck.app/Contents/Helpers/udeck-plugin")) == [.remove])
    }

    @Test("a uDeck's command is told by where it is in a bundle, by bytes")
    func aCommandInABundle() {
        #expect(CommandInstall.isACommandInABundle("/Applications/uDeck.app/Contents/Helpers/udeck-plugin"))
        #expect(CommandInstall.isACommandInABundle("/Users/a/Downloads/uDeck 2.app/Contents/Helpers/udeck-plugin"))
        #expect(!CommandInstall.isACommandInABundle("/Applications/uDeck.app/Contents/MacOS/udeck-plugin"))
        #expect(!CommandInstall.isACommandInABundle("/opt/homebrew/bin/udeck-plugin"))
        #expect(!CommandInstall.isACommandInABundle("/.app/Contents/Helpers/udeck-plugin"))
        #expect(!CommandInstall.isACommandInABundle("/Applications/uDeck.app/Contents/Helpers/udeck-plugin-old"))
    }
}

@Suite("Whether the shell finds the command")
struct ShellPathTests {
    @Test("a folder is in PATH by its bytes, a / at the end not counted")
    func includes() {
        #expect(ShellPath.includes("/Users/a/.local/bin", in: "/usr/bin:/Users/a/.local/bin/:/bin"))
        #expect(ShellPath.includes("/Users/a/.local/bin/", in: "/Users/a/.local/bin"))
        #expect(!ShellPath.includes("/Users/a/.local/bin", in: "/usr/bin:/Users/a/.local/binx:/bin"))
        #expect(!ShellPath.includes("/Users/a/.local/bin", in: "~/.local/bin:/usr/bin"), "a ~ in PATH is not expanded")
        #expect(!ShellPath.includes("/caf\u{E9}", in: "/caf\u{65}\u{301}"))
    }

    @Test("what to add, and where, by the shell")
    func advice() {
        #expect(ShellPath.advice(shell: "/bin/zsh") == ("~/.zshrc", #"export PATH="$HOME/.local/bin:$PATH""#))
        #expect(ShellPath.advice(shell: "/bin/bash").file == "~/.bash_profile")
        #expect(ShellPath.advice(shell: "/opt/homebrew/bin/fish") == ("~/.config/fish/config.fish", "fish_add_path $HOME/.local/bin"))
        #expect(ShellPath.advice(shell: "/bin/ksh").file == "~/.profile")
    }

    /// A shell of the test's own: it prints what startup files print, then
    /// runs the command it was given — never the operator's shell.
    @Test("the PATH a login shell ends up with is read between the marks, whatever its startup files print")
    func read() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let shell = temp.url.appendingPathComponent("fake-shell")
        try Data("""
            #!/bin/sh
            echo 'Welcome! __UDECK_PATH_END__ is not where it starts'
            PATH="$HOME/.local/bin:$PATH"; export PATH
            shift
            exec /bin/sh -c "$1"
            """.utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let path = await ShellPath.read(shell: shell.path, home: temp.url.path, user: "nobody")
        #expect(path == temp.url.path + "/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin")

        let silent = temp.url.appendingPathComponent("silent-shell")
        try Data("#!/bin/sh\necho nothing\n".utf8).write(to: silent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: silent.path)
        #expect(await ShellPath.read(shell: silent.path, home: temp.url.path, user: "nobody") == nil)
        #expect(await ShellPath.read(shell: temp.url.appendingPathComponent("no-shell").path, home: temp.url.path,
                                     user: "nobody") == nil)
        #expect(ShellPath.between("a__UDECK_PATH_BEGIN__/x:/y__UDECK_PATH_END__b") == "/x:/y")
        #expect(ShellPath.between("__UDECK_PATH_BEGIN__/x") == nil)
    }

    /// Interactive and login, as a new terminal window starts it: zsh reads
    /// `~/.zshrc` only when interactive, and that is the file the advice
    /// names. The fake shell prints what it was given, where the PATH goes.
    @Test("the shell is asked as a new terminal window starts it: interactive and login")
    func interactiveLogin() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let shell = temp.url.appendingPathComponent("flags-shell")
        try Data("#!/bin/sh\nprintf '%s%s%s' '__UDECK_PATH_BEGIN__' \"$1\" '__UDECK_PATH_END__'\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        #expect(await ShellPath.read(shell: shell.path, home: temp.url.path, user: "nobody") == "-ilc")
    }

    /// A shell that printed a PATH and did not end by itself — killed —
    /// cannot be taken at its word: the startup files may not have finished.
    @Test("a shell that did not end by itself is not read, whatever it printed")
    func killed() async throws {
        let temp = TemporaryDirectory()
        defer { withExtendedLifetime(temp) {} }
        let shell = temp.url.appendingPathComponent("killed-shell")
        try Data("#!/bin/sh\nprintf '%s%s%s' '__UDECK_PATH_BEGIN__' '/usr/bin' '__UDECK_PATH_END__'\nkill -KILL $$\n".utf8)
            .write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        #expect(await ShellPath.read(shell: shell.path, home: temp.url.path, user: "nobody") == nil)
    }
}
