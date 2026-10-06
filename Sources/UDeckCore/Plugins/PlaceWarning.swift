import Foundation

/// What a button that takes a plugin's place says before it does anything —
/// by what is there: a link, of which only the link goes; a copy holding
/// something of the operator's, which goes to the Trash; or uDeck's own copy,
/// which is deleted. One place, tested, for every such warning in Settings
/// and on a window: **Remove**, **Replace…** on a catalogue row, **Update**,
/// **Switch to**, **Reinstall**, **Back to** and **Install this version**,
/// and **Link a folder…** over an id that is taken.
///
/// A warning that said "the folder is deleted" of a link would be untrue the
/// one way that frightens most — and one that said nothing of the Trash of a
/// copy the operator changed, the one way that loses work.
public enum PlaceWarning {
    /// **Remove**. `link` is where a linked plugin's link leads — the folder,
    /// or what the link says when uDeck does not follow it — and nil for a
    /// plugin that is a folder; `toTrash` is the installer's own rule
    /// (`OperatorsWork.goesToTrash`), never true of a link.
    public static func removal(id: String, link: String?, toTrash: Bool) -> Phrase {
        if let link { return .catalogueRemoveLinkConfirm(id: id, target: link) }
        return toTrash ? .catalogueRemoveOwnConfirm(id: id) : .catalogueRemoveConfirm(id: id)
    }

    /// **Replace…** on a catalogue row, over what is at the id's place in the
    /// plugins folder `path`: a folder of the operator's own goes to the
    /// Trash; a link goes, and the folder it leads to stays.
    public static func replacement(id: String, path: String, link: String?) -> Phrase {
        if let link { return .catalogueReplaceLinkConfirm(id: id, target: link) }
        return .catalogueReplaceConfirm(id: id, path: path)
    }

    /// **Update**, **Switch to**, **Reinstall**, **Back to** and **Install
    /// this version**, over what is at the plugin's place: a link goes and
    /// the folder it leads to stays, as **Replace…** says it of a link; a
    /// copy holding the operator's changes goes to the Trash, replaced with
    /// `version`. A link put where the copy was while the warning about the
    /// copy was up is warned of in its own words, not as the copy.
    public static func replacingCopy(id: String, version: String, link: String?) -> Phrase {
        if let link { return .catalogueReplaceLinkConfirm(id: id, target: link) }
        return .catalogueUpdateOverChanges(id: id, version: version)
    }

    /// **Link a folder…** of `folder` over what is at its id now
    /// (`PluginLink.Occupant`), in the plugins folder `path` — nil when
    /// nothing has to be said: the id is free, or already linked to that
    /// folder. `toTrash` is the installer's rule, as for **Remove**. The
    /// folder and the folder a link there leads to are both written by
    /// `shown` — Settings' `~` for the home folder — so that one warning
    /// does not name two folders two ways.
    public static func linking(id: String, folder: String, occupant: PluginLink.Occupant, toTrash: Bool,
                               path: String, shown: (String) -> String) -> Phrase? {
        switch occupant {
        case .nothing, .link(_, sameFolder: true):
            nil
        case .installed(let source):
            .linkFolderOverInstalled(id: id, source: source, folder: shown(folder), toTrash: toTrash)
        case .folderOfYourOwn:
            .linkFolderOverOwn(id: id, path: path, folder: shown(folder), toTrash: toTrash)
        case .link(let destination, sameFolder: false):
            .linkFolderOverLink(id: id, destination: shown(destination), folder: shown(folder))
        }
    }
}

/// Why **Link a folder…** linked nothing, as Settings says it.
public enum FolderLinkRefusal: Equatable, Sendable {
    /// Another install, update, removal or link is running; they run one
    /// after another.
    case busy
    /// The folder is not one to link, or what is at its id could not be told
    /// (`PluginLink.Refusal.Reason`).
    case folder(PluginLink.Refusal.Reason)
    /// `installed.json` cannot be read, and uDeck replaces nothing while it
    /// cannot.
    case recordsBroken(String)
    /// The link was not put in place, in the installer's words.
    case failed(String)
}
