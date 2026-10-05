import Darwin
import Foundation

/// **Install command** in Settings → Plugins: `udeck-plugin` — the command
/// authors check, make, run and link plugins with — travels inside uDeck.app,
/// at `Contents/Helpers/udeck-plugin` (`Scripts/make-app.sh` puts it there and
/// signs it with the bundle), and is installed as a link in the account's own
/// `~/.local/bin`: `~/.local/bin/udeck-plugin` → the command inside the
/// bundle.
///
/// The account's own folder, so no administrator password. A link and not a
/// copy, so that the command is whichever uDeck is installed: an update of
/// uDeck replaces the bundle, and the command with it.
///
/// Nothing that is not uDeck's is ever replaced or removed: a file, a folder,
/// or a link to anything but a uDeck's command at that place is left as it is,
/// and said (`State.foreign`). A link to the command of another copy of uDeck
/// — one moved, replaced, or a second copy — is uDeck's, and is pointed at this
/// one when the operator asks (`State.otherCopy`).
public struct CommandInstall: Sendable {
    /// The command's name, in the bundle and in `~/.local/bin`.
    public static let name = "udeck-plugin"

    /// Where the command is inside a uDeck bundle.
    ///
    /// `Contents/Helpers`, Apple's place for a helper tool in an application
    /// bundle, and not `Contents/MacOS`: a tool there is taken by
    /// `Bundle.main` and by macOS for the application itself — uDeck's
    /// Info.plist as its own, the application's identity for its permissions.
    public static let inBundle = "Contents/Helpers/udeck-plugin"

    /// The command inside the running uDeck, or nil when it has none: a
    /// development build run from `.build`, which is no bundle.
    public let helper: URL?
    /// `~/.local/bin` of the account.
    public let folder: URL
    /// Where the running uDeck is: a link is made only to a uDeck that stays
    /// where it is (`BundlePlace`).
    public let place: BundlePlace
    /// The renames the link is put in place and taken away with — the
    /// system's; a test's own, to put something at the place between two
    /// steps.
    let renames: FolderRenames

    /// `~/.local/bin/udeck-plugin`.
    public var link: URL { folder.appendingPathComponent(Self.name) }

    public init(helper: URL?, folder: URL, place: BundlePlace = .lasting) {
        self.init(helper: helper, folder: folder, place: place, renames: .system)
    }

    init(helper: URL?, folder: URL, place: BundlePlace = .lasting, renames: FolderRenames) {
        self.helper = helper
        self.folder = folder
        self.place = place
        self.renames = renames
    }

    /// The command in `bundle`, when the bundle has one that can be run.
    public static func helper(in bundle: URL) -> URL? {
        let helper = bundle.appendingPathComponent(inBundle)
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    /// `~/.local/bin` of the home folder `home`.
    public static func folder(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".local/bin", isDirectory: true)
    }

    /// What is at `~/.local/bin/udeck-plugin`.
    public enum State: Equatable, Sendable {
        /// Nothing.
        case notInstalled
        /// A link to the command inside this uDeck.
        case installed
        /// A link to the command inside another uDeck — `target`, as the
        /// link says it — whether or not that copy is still there.
        case otherCopy(target: String)
        /// Something that is not uDeck's, which uDeck leaves alone.
        case foreign(Foreign)
    }

    /// What is there instead, when it is not uDeck's.
    public enum Foreign: Equatable, Sendable {
        case file
        case folder
        /// A link to anything but a uDeck's command.
        case link(to: String)
    }

    /// What is at the command's place now, asked of the disk.
    public func state() -> State {
        state(of: link)
    }

    /// What `url` is, as the command's place would be read: nothing, a link
    /// to this uDeck's command or another's, or something that is not
    /// uDeck's.
    func state(of url: URL) -> State {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return .notInstalled }
        switch status.st_mode & S_IFMT {
        case S_IFLNK:
            break
        case S_IFDIR:
            return .foreign(.folder)
        default:
            return .foreign(.file)
        }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return .foreign(.link(to: "?"))
        }
        if let helper, Self.same(destination, helper.path) || Self.sameFile(destination, helper.path) {
            return .installed
        }
        return Self.isACommandInABundle(destination) ? .otherCopy(target: destination) : .foreign(.link(to: destination))
    }

    /// Why the command was not installed or removed.
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// This uDeck has no command inside it.
        case noHelper
        /// This uDeck runs from where it will not stay — a link to its
        /// command would lead nowhere once it quits (`BundlePlace`).
        case temporaryPlace(BundlePlace)
        /// Something that is not uDeck's is at the command's place.
        case foreign(Foreign)
        /// The disk said no, in the system's words.
        case cannotWrite(String)

        public var description: String {
            switch self {
            case .noHelper: "this uDeck has no udeck-plugin inside it"
            case .temporaryPlace(let place): "this uDeck runs from where it will not stay (\(place)); move it to Applications first"
            case .foreign(let what): "something that is not uDeck's is there: \(what)"
            case .cannotWrite(let reason): reason
            }
        }
    }

    /// Puts the link in place, `~/.local/bin` made first when it is not
    /// there: where nothing is, or over a link to another uDeck's command.
    /// Over anything else, nothing is done; and nothing at all from a uDeck
    /// that will not stay where it is (`BundlePlace`).
    ///
    /// The link is made beside its place and put there in one step: a
    /// terminal running the command meanwhile finds the old link or the new
    /// one, never none. That step is the system's own guard against
    /// whatever appears at the place after it was looked at: where nothing
    /// was, a rename that fails rather than replace anything
    /// (`RENAME_EXCL`); over another uDeck's link, an exchange (`RENAME_SWAP`),
    /// after which what came out of the place is read — and put back, and
    /// said, unless it is a link to a uDeck's command.
    public func install() throws {
        guard let helper else { throw Refusal.noHelper }
        guard place == .lasting else { throw Refusal.temporaryPlace(place) }
        switch state() {
        case .installed: return
        case .foreign(let what): throw Refusal.foreign(what)
        case .notInstalled, .otherCopy: break
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Refusal.cannotWrite("could not make \(folder.path): \(Self.because(error))")
        }
        let beside = folder.appendingPathComponent(".\(Self.name)-\(UUID().uuidString)")
        guard symlink(helper.path, beside.path) == 0 else {
            throw Refusal.cannotWrite("could not make a link in \(folder.path): \(String(cString: strerror(errno)))")
        }
        // Two looks: what is at the place can change between a look and the
        // step, and the step says so; a third change in a row is said.
        for _ in 0 ..< 2 {
            switch state() {
            case .installed:
                unlink(beside.path)
                return
            case .foreign(let what):
                unlink(beside.path)
                throw Refusal.foreign(what)
            case .notInstalled:
                let failed = renames.exclusive(beside, link)
                if failed == 0 { return }
                if failed == EEXIST { continue }
                unlink(beside.path)
                throw Refusal.cannotWrite("could not put the link at \(link.path): \(String(cString: strerror(failed)))")
            case .otherCopy:
                let failed = renames.exchange(beside, link)
                if failed == ENOENT { continue }
                guard failed == 0 else {
                    unlink(beside.path)
                    throw Refusal.cannotWrite("could not put the link at \(link.path): \(String(cString: strerror(failed)))")
                }
                // `beside` holds what was at the place a moment ago.
                switch state(of: beside) {
                case .otherCopy, .installed:
                    unlink(beside.path)
                    return
                case .notInstalled:
                    return
                case .foreign(let what):
                    // Somebody else's, put there since the look: back where it was.
                    guard renames.exchange(beside, link) == 0 else {
                        throw Refusal.cannotWrite("\(link.path) changed while the link was put in place; what was "
                                                  + "there is at \(beside.path) now — move it back to \(link.path)")
                    }
                    unlink(beside.path)
                    throw Refusal.foreign(what)
                }
            }
        }
        unlink(beside.path)
        throw Refusal.cannotWrite("\(link.path) kept changing while the link was put in place; try again")
    }

    /// Takes the link away — this uDeck's, or another uDeck's — and nothing
    /// else: what it leads to stays, and anything that is not uDeck's is left
    /// as it is.
    ///
    /// Moved aside first, in one step, and read there: what was taken out of
    /// the place is what is deleted, and only when it is a uDeck's link;
    /// anything else is put back — never over what has appeared meanwhile
    /// (`RENAME_EXCL`).
    public func remove() throws {
        switch state() {
        case .notInstalled: return
        case .foreign(let what): throw Refusal.foreign(what)
        case .installed, .otherCopy: break
        }
        let aside = folder.appendingPathComponent(".\(Self.name)-\(UUID().uuidString)")
        let failed = renames.exclusive(link, aside)
        if failed == ENOENT { return }
        guard failed == 0 else {
            throw Refusal.cannotWrite("could not take \(link.path) away: \(String(cString: strerror(failed)))")
        }
        switch state(of: aside) {
        case .installed, .otherCopy, .notInstalled:
            guard unlink(aside.path) == 0 || errno == ENOENT else {
                throw Refusal.cannotWrite("could not take \(link.path) away: \(String(cString: strerror(errno)))")
            }
        case .foreign(let what):
            guard renames.exclusive(aside, link) == 0 else {
                throw Refusal.cannotWrite("\(link.path) changed while the link was taken away; what was there is at "
                                          + "\(aside.path) now — move it back to \(link.path)")
            }
            throw Refusal.foreign(what)
        }
    }

    /// Whether `destination` is a uDeck's command: `…/<name>.app/Contents/Helpers/udeck-plugin`.
    /// By bytes, as every path here.
    public static func isACommandInABundle(_ destination: String) -> Bool {
        let names = destination.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true)
        guard names.count >= 4 else { return false }
        let tail = names.suffix(4).map { String(decoding: $0, as: UTF8.self) }
        return tail[0].utf8.count > 4 && tail[0].utf8.reversed().starts(with: ".app".utf8.reversed())
            && tail[1].utf8.elementsEqual("Contents".utf8) && tail[2].utf8.elementsEqual("Helpers".utf8)
            && tail[3].utf8.elementsEqual(name.utf8)
    }

    static func same(_ one: String, _ other: String) -> Bool {
        one.utf8.elementsEqual(other.utf8)
    }

    /// Whether the two lead to one file, every link on the way resolved —
    /// `/Applications` reached through a link of its own, say.
    static func sameFile(_ one: String, _ other: String) -> Bool {
        guard let first = FilePaths.real(one).path, let second = FilePaths.real(other).path else { return false }
        return same(first, second)
    }

    static func because(_ error: any Error) -> String {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return String(cString: strerror(Int32(error.code))) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return error.localizedDescription
    }
}

/// Where the running uDeck is, for a link to the command inside it: a link
/// is only as lasting as what it leads to.
///
/// A uDeck opened where it was downloaded, with the quarantine on it, is run
/// by macOS from a read-only copy at a random path that goes when it quits
/// (App Translocation); one opened on its disk image runs from `/Volumes/…`
/// until the image is ejected. A link to either leads nowhere afterwards, and
/// Settings would say "another copy of uDeck" at every launch. In
/// Applications — or anywhere it stays — Sparkle replaces the bundle at the
/// same path, and the link keeps leading to the command of whichever uDeck
/// is there.
public enum BundlePlace: Equatable, Sendable {
    /// Where it stays.
    case lasting
    /// A copy macOS made to run it from (App Translocation).
    case translocated
    /// A disk image mounted at `volume`, read-only.
    case diskImage(volume: String)

    /// Where `bundle` — the running uDeck's path — is: `translocated` as
    /// the system says it (`SecTranslocateIsTranslocatedURL`, asked by the
    /// app), and the path as a second witness, an `AppTranslocation` folder
    /// on the way; a read-only volume under `/Volumes` as a disk image. A
    /// disk of one's own under `/Volumes`, written to, is somewhere uDeck can
    /// stay. Every name by its bytes.
    public static func of(bundle: String, translocated: Bool, readOnlyVolume: Bool) -> BundlePlace {
        let names = bundle.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true)
        if translocated || names.contains(where: { $0.elementsEqual("AppTranslocation".utf8) }) {
            return .translocated
        }
        if readOnlyVolume, names.count >= 2, FilePaths.isAbsolute(bundle), names[0].elementsEqual("Volumes".utf8) {
            return .diskImage(volume: "/Volumes/" + String(decoding: names[1], as: UTF8.self))
        }
        return .lasting
    }
}

/// Whether the operator's shell finds a command in `~/.local/bin`, and what to
/// add where when it does not. uDeck never writes the shell's files: it says
/// the line.
public enum ShellPath {
    /// Whether `folder` is one of the folders of `path` — a `PATH` value —
    /// compared as bytes, a `/` at the end of either not counted.
    public static func includes(_ folder: String, in path: String) -> Bool {
        let wanted = trimmed(Array(folder.utf8))
        return path.utf8.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: true)
            .contains { trimmed(Array($0)) == wanted }
    }

    private static func trimmed(_ bytes: [UInt8]) -> [UInt8] {
        var bytes = bytes
        while bytes.count > 1, bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
        return bytes
    }

    /// The account's login shell: the account database's, then `SHELL`, then
    /// zsh, macOS's own.
    public static func accountShell(environment: [String: String]) -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let found = String(cString: shell)
            if !found.isEmpty { return found }
        }
        return environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    /// Marks around what the shell prints of its `PATH`, so that anything its
    /// startup files print besides is not read as it.
    static let begin = "__UDECK_PATH_BEGIN__"
    static let end = "__UDECK_PATH_END__"

    /// The `PATH` an interactive login shell of `shell` ends up with — what a
    /// new terminal window has — asked of the shell itself, as the operator's
    /// startup files make it: `shell -ilc`, in a process group of its own,
    /// with nothing to read, stopped after `deadline` seconds. Nil when it
    /// could not be told: the shell would not start, did not answer in time,
    /// or printed no `PATH`.
    ///
    /// Asked of the shell because nothing else knows: uDeck started from
    /// Finder or at login is handed launchd's `PATH`, not the one the
    /// operator's terminal has, and a shell's startup files can say anything.
    public static func read(shell: String, home: String, user: String, deadline: TimeInterval = 5,
                            runner: ProcessRunner = ProcessRunner()) async -> String? {
        let environment = [
            "HOME": home, "USER": user, "LOGNAME": user, "SHELL": shell,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb", "LANG": "en_US.UTF-8",
        ]
        let script = "printf '%s%s%s' '\(begin)' \"$PATH\" '\(end)'"
        let result = await runner.run(executable: URL(fileURLWithPath: shell), arguments: ["-ilc", script],
                                      workingDirectory: URL(fileURLWithPath: home, isDirectory: true),
                                      environment: environment, timeout: deadline)
        guard case .exited = result.termination else { return nil }
        return between(String(decoding: result.standardOutput, as: UTF8.self))
    }

    /// What the shell printed between the marks, or nil.
    static func between(_ output: String) -> String? {
        let bytes = Array(output.utf8)
        let open = Array(begin.utf8), close = Array(end.utf8)
        guard let start = firstIndex(of: open, in: bytes, from: 0) else { return nil }
        let from = start + open.count
        guard let stop = firstIndex(of: close, in: bytes, from: from) else { return nil }
        return String(decoding: bytes[from ..< stop], as: UTF8.self)
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var index = from
        while index + needle.count <= haystack.count {
            if haystack[index ..< index + needle.count].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    /// What to add, and to which file, for `shell` to look in `~/.local/bin`:
    /// the file a new terminal window of that shell reads, and the line.
    public static func advice(shell: String) -> (file: String, line: String) {
        let name = shell.utf8.split(separator: UInt8(ascii: "/")).last.map { String(decoding: $0, as: UTF8.self) } ?? shell
        switch name {
        case "zsh": return ("~/.zshrc", #"export PATH="$HOME/.local/bin:$PATH""#)
        case "bash": return ("~/.bash_profile", #"export PATH="$HOME/.local/bin:$PATH""#)
        case "fish": return ("~/.config/fish/config.fish", "fish_add_path $HOME/.local/bin")
        default: return ("~/.profile", #"export PATH="$HOME/.local/bin:$PATH""#)
        }
    }
}
