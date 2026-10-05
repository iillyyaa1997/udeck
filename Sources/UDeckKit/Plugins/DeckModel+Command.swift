import AppKit
import UDeckCore

/// Whether the operator's shell finds a command in `~/.local/bin`, as it was
/// last asked (`ShellPath.read`).
public enum ShellFinding: Equatable, Sendable {
    /// Not asked: the command is not installed, or the pane has not asked yet.
    case notAsked
    case asking
    /// A new terminal window finds it.
    case finds
    /// It does not: the shell, the file to add the line to, and the line.
    case doesNotFind(shell: String, file: String, line: String)
    /// The shell would not say — it did not start, did not answer within its
    /// time, or printed no `PATH`.
    case cannotTell
}

extension DeckModel {
    /// **Install command**: this uDeck's `udeck-plugin` — inside its bundle,
    /// where `Scripts/make-app.sh` puts it — the account's own `~/.local/bin`,
    /// which is where the link goes, and whether this uDeck stays where it is
    /// (`CommandInstall`, `BundlePlace`).
    public var command: CommandInstall {
        CommandInstall(helper: CommandInstall.helper(in: Bundle.main.bundleURL),
                       folder: CommandInstall.folder(home: NSHomeDirectory()), place: Self.bundlePlace)
    }

    /// Where the running bundle is: asked once — it does not move while uDeck
    /// runs — of the system, whether macOS runs it from a translocated copy,
    /// and of its volume, whether that is read-only; `BundlePlace` decides
    /// from those and the path.
    private static let bundlePlace: BundlePlace = {
        let bundle = Bundle.main.bundleURL
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let place = BundlePlace.of(bundle: bundle.path, translocated: isTranslocated(bundle), readOnlyVolume: readOnly)
        DeckLog.plugins.info("uDeck runs from \(bundle.path, privacy: .public): \(String(describing: place), privacy: .public)")
        return place
    }()

    /// Whether macOS runs `bundle` from a translocated copy, as the Security
    /// framework says it: `SecTranslocateIsTranslocatedURL`, from
    /// `SecTranslocate.h`, which the Security module Swift imports does not
    /// declare — `cannot find 'SecTranslocateIsTranslocatedURL' in scope`,
    /// measured building uDeck on 2026-10-05 — so it is looked up by name in
    /// the framework. False when it is not there or cannot tell; the path is
    /// the second witness (`BundlePlace.of`).
    private static func isTranslocated(_ bundle: URL) -> Bool {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>,
                                                   UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateIsTranslocatedURL") else { return false }
        var translocated = false
        return unsafeBitCast(symbol, to: IsTranslocated.self)(bundle as CFURL, &translocated, nil) && translocated
    }

    /// `~/.local/bin/udeck-plugin`, as the operator writes it.
    public var commandDisplayPath: String { displayPath(command.link.path) }

    /// `~/.local/bin`, as the operator writes it.
    public var commandFolderDisplayPath: String { displayPath(command.folder.path) }

    /// What is at the command's place now, asked of the disk — and, when it is
    /// this uDeck's, whether the operator's shell finds it: asked of the shell
    /// itself, away from the main thread, within a few seconds.
    ///
    /// Asked when Settings → Plugins appears and after every **Install
    /// command** and **Remove command**: the disk and the shell's files can
    /// change between two looks at the pane, and nothing else says so.
    public func refreshCommandState() {
        let state = command.state()
        if state != commandState { commandState = state }
        guard state == .installed else {
            shellFindsCommand = .notAsked
            return
        }
        guard shellFindsCommand != .asking else { return }
        shellFindsCommand = .asking
        let shell = ShellPath.accountShell(environment: ProcessInfo.processInfo.environment)
        let folder = command.folder.path
        let home = NSHomeDirectory()
        let user = NSUserName()
        Task { [weak self] in
            let path = await ShellPath.read(shell: shell, home: home, user: user)
            guard let self else { return }
            guard let path else {
                self.shellFindsCommand = .cannotTell
                return
            }
            if ShellPath.includes(folder, in: path) {
                self.shellFindsCommand = .finds
            } else {
                let advice = ShellPath.advice(shell: shell)
                let name = shell.split(separator: "/").last.map(String.init) ?? shell
                self.shellFindsCommand = .doesNotFind(shell: name, file: advice.file, line: advice.line)
            }
        }
    }

    /// **Install command**.
    public func installCommand() {
        commandProblem = nil
        do {
            try command.install()
            DeckLog.plugins.info("installed the command: \(self.command.link.path, privacy: .public)")
        } catch {
            commandProblem = error as? CommandInstall.Refusal ?? .cannotWrite("\(error)")
        }
        shellFindsCommand = .notAsked
        refreshCommandState()
    }

    /// **Remove command**: the link, never what it leads to.
    public func removeCommand() {
        commandProblem = nil
        do {
            try command.remove()
            DeckLog.plugins.info("removed the command: \(self.command.link.path, privacy: .public)")
        } catch {
            commandProblem = error as? CommandInstall.Refusal ?? .cannotWrite("\(error)")
        }
        refreshCommandState()
    }
}
