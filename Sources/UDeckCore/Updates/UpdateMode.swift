import Foundation
import UDeckPluginFormat

/// What uDeck does when a check of its own finds a new version — the choice in
/// Settings → About, "When a new version is out" (0.8.6).
///
/// Before 0.8.6 there was one switch, **Install updates automatically**
/// (Sparkle's `SUAutomaticallyUpdate`), and nothing between "only say so" and
/// "put it in by itself". The operator asked for the middle: download it ahead,
/// so that **Update** is a restart and nothing more.
public enum UpdateMode: String, Sendable, Equatable, CaseIterable {
    /// Say so, and download nothing until **Update** is pressed.
    case tell
    /// Download it and check its signature at once, and wait for **Update**.
    case downloadAhead
    /// Download it and restart into it when nothing holds the restart
    /// (`RestartHold`) — how uDeck has updated by itself since 0.8.1.
    case installByItself

    /// Whether Sparkle downloads what a check of its own finds
    /// (`automaticallyDownloadsUpdates`).
    public var downloadsAhead: Bool { self != .tell }

    /// Whether uDeck restarts into a downloaded update with nothing pressed.
    public var restartsByItself: Bool { self == .installByItself }

    /// As uDeck ships: as it has updated since 0.8.1.
    public static let shipped: UpdateMode = .installByItself

    /// The mode kept under `raw`, or — nothing kept, the first launch after
    /// 0.8.5 — the one 0.8.5's switch meant: on, it put updates in by itself;
    /// off, it only said so. A value no release wrote reads the same way.
    public static func kept(_ raw: String?, automaticallyDownloads: Bool) -> UpdateMode {
        if let raw, let mode = UpdateMode(rawValue: raw) { return mode }
        return automaticallyDownloads ? .installByItself : .tell
    }
}

/// What happened that a notification may be about.
public enum UpdateEvent: Equatable, Sendable {
    /// A check of its own found `version`, and nothing is downloading it.
    case foundByItself(version: String)
    /// `version` is downloaded and verified, and waits for **Update**.
    case downloaded(version: String)
    /// uDeck started as `running`; `restartedInto` is the version uDeck last
    /// restarted into *by itself*, noted at that restart, or nil.
    case launched(running: String, restartedInto: String?)
}

/// A notification about an update (0.8.6): at most one for each version —
/// "Later" means not about this version again — at the moment there is
/// something to press, and, for an update put in by itself, after the restart
/// into it.
public enum UpdateNotice: Equatable, Sendable {
    /// Found, not downloaded: **Update** and **Later**.
    case found(version: String)
    /// Downloaded and verified: **Update** and **Later**.
    case downloaded(version: String)
    /// Running the new version after uDeck restarted into it by itself.
    case updated(version: String)

    public var version: String {
        switch self {
        case .found(let version), .downloaded(let version), .updated(let version): version
        }
    }

    /// What the log says, and the notification's own identifier.
    public var key: String {
        switch self {
        case .found(let version): "found \(version)"
        case .downloaded(let version): "downloaded \(version)"
        case .updated(let version): "updated \(version)"
        }
    }

    /// Whether it carries **Update** and **Later**: there is something to put in.
    public var offersUpdate: Bool {
        if case .updated = self { return false }
        return true
    }

    /// The notice `event` is worth, or nil.
    ///
    /// Nothing with notifications switched off, nor about the version
    /// `notifiedVersion` — one notification sent for a version is the only one
    /// about it. Found: whatever the mode, because only a check that downloads
    /// nothing reports it. Downloaded: in `downloadAhead` only —
    /// `installByItself` restarts into it soon and says so afterwards, and a
    /// download there waits on the pane that asked for it. Launched: when the
    /// version running is the one uDeck noted it restarted into by itself — not
    /// after Update, which was pressed, nor after anything else that replaced
    /// the application.
    public static func after(
        _ event: UpdateEvent, mode: UpdateMode, notifies: Bool, notifiedVersion: String?
    ) -> UpdateNotice? {
        guard notifies else { return nil }
        let notice: UpdateNotice?
        switch event {
        case .foundByItself(let version):
            notice = .found(version: version)
        case .downloaded(let version):
            notice = mode == .downloadAhead ? .downloaded(version: version) : nil
        case .launched(let running, let restartedInto):
            notice = restartedInto == running ? .updated(version: running) : nil
        }
        guard let notice, notice.version != notifiedVersion else { return nil }
        return notice
    }
}

/// Where a release's notes are read: its page on GitHub, the one "What's new"
/// opens.
public enum ReleaseNotes {
    public static func page(for version: String) -> URL? {
        guard SemanticVersion(version) != nil else { return nil }
        return URL(string: "https://github.com/iillyyaa1997/udeck/releases/tag/v\(version)")
    }
}
