/// What an installed plugin's line in Settings → Plugins → Installed says under
/// its name: the one thing about it worth a glance, the most pressing first —
/// the card beside the list says the rest (the redesign, 2026-11-18).
///
/// Most pressing first, because a line has room for one: a plugin whose folder
/// has gone or that will not load does nothing else; one switched off is off,
/// whatever it was asked or answered — its switch is what turns it on again,
/// and the decision is asked of it then; one waiting for a permission, or
/// declined it, does not run, so a failure of an earlier run, or an update, is
/// not what matters about it yet; a failure says more than an update does about
/// a plugin that runs.
public enum PluginListStatus: Equatable, Sendable {
    /// Installed through uDeck, and its folder has gone.
    case folderGone
    /// Its manifest does not load, or says something uDeck refuses.
    case wontLoad
    /// Switched off.
    case off
    /// Asks for a permission nobody has decided on yet.
    case asksPermission
    /// Its permission was declined: it does not run.
    case declined
    /// Its last run failed.
    case failed
    /// An update waits — the version, when the head has a newer one.
    case update(version: String?)
    /// On, allowed, nothing wrong — said as *on*, not *running*: a plugin
    /// placed on no tab, with the panel away, runs nothing.
    case runs

    /// What the plugin is, as the line reads it.
    public struct Facts: Equatable, Sendable {
        public var folderGone = false
        public var wontLoad = false
        public var asksPermission = false
        public var declined = false
        public var enabled = true
        public var failed = false
        public var updateWaits = false
        public var newerVersion: String?

        public init(folderGone: Bool = false, wontLoad: Bool = false, asksPermission: Bool = false,
                    declined: Bool = false, enabled: Bool = true, failed: Bool = false,
                    updateWaits: Bool = false, newerVersion: String? = nil) {
            self.folderGone = folderGone
            self.wontLoad = wontLoad
            self.asksPermission = asksPermission
            self.declined = declined
            self.enabled = enabled
            self.failed = failed
            self.updateWaits = updateWaits
            self.newerVersion = newerVersion
        }
    }

    public static func of(_ facts: Facts) -> PluginListStatus {
        if facts.folderGone { return .folderGone }
        if facts.wontLoad { return .wontLoad }
        if !facts.enabled { return .off }
        if facts.asksPermission { return .asksPermission }
        if facts.declined { return .declined }
        if facts.failed { return .failed }
        if facts.updateWaits { return .update(version: facts.newerVersion) }
        return .runs
    }

    /// Said in the warning colour: something the operator has to do, or
    /// something wrong.
    public var isTrouble: Bool {
        switch self {
        case .folderGone, .wontLoad, .asksPermission, .failed: true
        case .declined, .off, .update, .runs: false
        }
    }

    /// The line's words.
    public var phrase: Phrase {
        switch self {
        case .folderGone: .pluginStatusFolderGone
        case .wontLoad: .pluginStatusWontLoad
        case .asksPermission: .pluginStatusAsksPermission
        case .declined: .pluginStatusDeclined
        case .off: .pluginStatusOff
        case .failed: .pluginStatusFailed
        case .update(let version): .pluginStatusUpdate(version: version)
        case .runs: .pluginStatusRuns
        }
    }
}
