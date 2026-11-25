/// One thing a plugin can use of the plugin contract.
public enum ContractFeature: Hashable, Sendable, CustomStringConvertible {
    // What a manifest says, and so what the repository check can see.
    case manifestField(String)
    case pluginKind(String)
    case permission(String)
    case windowField(String)
    case settingField(String)
    case settingType(String)
    case optionField(String)
    /// `manifest.<lang>.json` beside the manifest.
    case translations
    case translationField(String)
    case settingTranslationField(String)

    // What a producer prints, which only running it shows.
    case cardField(String)
    case cardState(String)
    case row(String)
    /// A field inside a row: `meter.caption`, `list.icon`.
    case rowField(row: String, field: String)
    case listIcon(String)
    case tableAlignment(String)
    case actionField(String)
    case tone(String)
    case barIcon(String)

    // What a producer is handed, and what a card's action is.
    case environment(String)
    case actionEnvironment(String)

    public var description: String {
        switch self {
        case .manifestField(let name): "the manifest field \"\(name)\""
        case .pluginKind(let kind): "\"kind\": \"\(kind)\""
        case .permission(let name): "the permission \"\(name)\""
        case .windowField(let name): "the field \"window.\(name)\""
        case .settingField(let name): "the setting field \"\(name)\""
        case .settingType(let type): "the setting type \"\(type)\""
        case .optionField(let name): "the option field \"\(name)\""
        case .translations: "translations (manifest.<lang>.json)"
        case .translationField(let name): "the translation field \"\(name)\""
        case .settingTranslationField(let name): "the translated setting field \"\(name)\""
        case .cardField(let name): "the card field \"\(name)\""
        case .cardState(let state): "the card state \"\(state)\""
        case .row(let row): "the row type \"\(row)\""
        case .rowField(let row, let field): "the field \"\(field)\" of a \"\(row)\" row"
        case .listIcon(let icon): "the list icon \"\(icon)\""
        case .tableAlignment(let align): "the column alignment \"\(align)\""
        case .actionField(let name): "the action field \"\(name)\""
        case .tone(let tone): "the tone \"\(tone)\""
        case .barIcon(let icon): "the bar icon \"\(icon)\""
        case .environment(let name): "the environment variable \(name)"
        case .actionEnvironment(let name): "the environment variable \(name) in a card's action"
        }
    }
}

/// The uDeck release a contract feature first came in.
public enum ContractRelease: Hashable, Sendable, Comparable, CustomStringConvertible {
    case released(SemanticVersion)
    /// Not in any release yet: it comes with the one after `UDeckRelease.version`.
    case next

    public var description: String {
        switch self {
        case .released(let version): "uDeck \(version)"
        case .next: "the uDeck release after \(UDeckRelease.version)"
        }
    }

    public static func < (lhs: ContractRelease, rhs: ContractRelease) -> Bool {
        switch (lhs, rhs) {
        case (.released(let one), .released(let other)): one < other
        case (.released, .next): true
        case (.next, _): false
        }
    }

    /// Whether a uDeck of `version` has everything this release brought.
    func isMet(by version: SemanticVersion) -> Bool {
        switch self {
        case .released(let release): version >= release
        case .next: version > (SemanticVersion(UDeckRelease.version) ?? version)
        }
    }

    /// Whether this release is certainly `version` or later. The release
    /// after `UDeckRelease.version` has no number yet; the smallest it can
    /// have is the version right after, so only a `version` up to that one
    /// is certainly not after it.
    func isAtLeast(_ version: SemanticVersion) -> Bool {
        switch self {
        case .released(let release): return release >= version
        case .next:
            guard let current = SemanticVersion(UDeckRelease.version) else { return false }
            return version <= current.next
        }
    }
}

/// Which uDeck release first had each part of the plugin contract — so the
/// check can work out the lowest `minUDeck` that is true of a plugin, rather
/// than leave it to the author's memory (docs/plugin-repository.md,
/// "`minUDeck`").
///
/// **Every part of the contract is in here, and a test holds it to that**: it
/// lists the contract from the code — the decoders' `CodingKeys`, the enums'
/// cases, the environment a producer gets — and fails on anything not dated.
/// A new field, row type or variable is added with `.next`, and at a release
/// every `.next` becomes that release's number and `reviewedAt` moves with
/// `UDeckRelease.version`, which a test checks too.
///
/// Measured for what is here now (git, every release tag against the decoders
/// at that tag): every part of the contract was in v0.1.0, the first release,
/// except `minUDeck` itself, which came in 0.6.0.
public enum ContractFeatures {
    /// What uDeck's decoder reads and the plugin contract (docs/plugin-api.md)
    /// does not describe: `restart`, which only a resident plugin would use,
    /// and uDeck runs none yet. uDeck decodes it all the same — one missing a
    /// field keeps the plugin from loading at all (rule 3) — and the strict
    /// check says of it what it says of any field outside the contract (rule 12).
    /// It is in no release here: no release has it in the contract.
    public static let outsideTheContract: Set<String> = ["restart"]

    /// The release this registry was last brought up to date for. 0.9.4
    /// brought bars, menus, badges, an input with menus and the feed's `name`
    /// and `label`, dated above; 0.9.5 to 0.9.9 add nothing this registry
    /// dates (0.9.6 draws a user entry's `label`, a field 0.9.4 brought;
    /// 0.9.7's trust in a plugin's updates is the host's, not the card's;
    /// 0.9.8's places tell a card their size by the `size` event it always
    /// had; 0.9.9's are lines beside a card and events — `view`, `keep`,
    /// `name`, `show`, a notice's `actions` and `reply`, `unnotify` — which a
    /// uDeck before it ignores, and the docs date). 0.9.10 brings a card's
    /// `attention`, dated above. 0.9.11, 0.9.12 and 0.9.13 change
    /// nothing in the contract; 0.9.14 brings a menu option's `button`; 0.9.15
    /// and 0.9.16 change nothing in it.
    static let reviewedAt = "0.9.16"

    static let firstRelease = ContractRelease.released(SemanticVersion(major: 0, minor: 1, patch: 0))

    public static let registry: [ContractFeature: ContractRelease] = {
        var registry: [ContractFeature: ContractRelease] = [:]
        func add(_ release: ContractRelease, _ features: [ContractFeature]) {
            for feature in features { registry[feature] = release }
        }
        // Not `restart`: uDeck decodes it, and the contract does not describe
        // it (`outsideTheContract`). It is dated here on the day the contract
        // does, with the release that brings it.
        add(firstRelease, ["id", "name", "version", "api", "kind", "description", "author", "homepage", "run",
                           "interval", "timeout", "permissions", "settings", "window"].map { .manifestField($0) })
        add(.released(SemanticVersion(major: 0, minor: 6, patch: 0)), [.manifestField("minUDeck")])
        add(firstRelease, ["poll", "resident"].map { .pluginKind($0) })
        add(firstRelease, ["read", "write", "exec", "network", "screen", "secrets"].map { .permission($0) })
        add(firstRelease, ["defaultWidth", "defaultHeight", "minWidth", "minHeight"].map { .windowField($0) })
        add(firstRelease, ["key", "type", "label", "help", "default", "min", "max", "options"].map { .settingField($0) })
        add(firstRelease, ["bool", "int", "string", "enum"].map { .settingType($0) })
        add(firstRelease, ["value", "label"].map { .optionField($0) })
        add(firstRelease, [.translations])
        add(firstRelease, ["name", "description", "settings"].map { .translationField($0) })
        add(firstRelease, ["label", "help", "options"].map { .settingTranslationField($0) })

        add(firstRelease, ["state", "title", "chip", "rows", "actions", "ttl"].map { .cardField($0) })
        add(firstRelease, ["ok", "warn", "crit", "unknown"].map { .cardState($0) })
        add(firstRelease, ["text", "kv", "meter", "list", "spark", "table", "log", "canvas"].map { .row($0) })
        add(firstRelease, ["value", "label", "caption", "state"].map { .rowField(row: "meter", field: $0) })
        add(firstRelease, ["text", "note", "icon", "state"].map { .rowField(row: "list", field: $0) })
        add(firstRelease, ["values", "caption"].map { .rowField(row: "spark", field: $0) })
        add(firstRelease, ["columns", "rows"].map { .rowField(row: "table", field: $0) })
        add(firstRelease, ["title", "align"].map { .rowField(row: "table.columns", field: $0) })
        add(firstRelease, ["kind", "payload", "height"].map { .rowField(row: "canvas", field: $0) })
        add(firstRelease, ["ok", "warn", "crit", "wait", "run", "idle", "done", "pause", "info", "dot"].map { .listIcon($0) })
        add(firstRelease, ["leading", "trailing"].map { .tableAlignment($0) })
        add(firstRelease, ["label", "run", "confirm"].map { .actionField($0) })

        add(firstRelease, ["UDECK_API", "UDECK_PLUGIN_ID", "UDECK_PLUGIN_DIR", "UDECK_CACHE_DIR", "UDECK_APPEARANCE",
                           "UDECK_REFRESH_REASON", "UDECK_LANG", "UDECK_SETTING_*"].map { .environment($0) })
        add(firstRelease, ["UDECK_API", "UDECK_PLUGIN_ID", "UDECK_PLUGIN_DIR"].map { .actionEnvironment($0) })

        // Resident plugins run, and their cards may take input: 0.9.1.
        let residentRelease = ContractRelease.released(SemanticVersion(major: 0, minor: 9, patch: 1))
        add(residentRelease, ["chips", "feed", "ask", "input"].map { .row($0) })
        add(residentRelease, ["id", "text", "state", "selected"].map { .rowField(row: "chips", field: $0) })
        add(residentRelease, ["id", "role", "text", "detail", "streaming", "error"].map { .rowField(row: "feed", field: $0) })
        add(residentRelease, ["id", "title", "detail", "buttons"].map { .rowField(row: "ask", field: $0) })
        add(residentRelease, ["id", "label", "primary"].map { .rowField(row: "ask.buttons", field: $0) })
        add(residentRelease, ["id", "placeholder", "enabled", "stop"].map { .rowField(row: "input", field: $0) })

        // Bars, menus, badges, an input with menus, folding tool entries: 0.9.4.
        let barRelease = ContractRelease.released(SemanticVersion(major: 0, minor: 9, patch: 4))
        add(barRelease, [.row("bar"), .rowField(row: "input", field: "pickers")])
        add(barRelease, ["name", "label"].map { .rowField(row: "feed", field: $0) })
        add(barRelease, ["id", "items"].map { .rowField(row: "bar", field: $0) })
        add(barRelease, ["title", "tag", "badge", "menu", "button", "spacer"].map { .rowField(row: "bar.items", field: $0) })
        add(barRelease, ["text", "tone"].map { .rowField(row: "bar.title", field: $0) })
        add(barRelease, ["text", "tone", "icon", "fill"].map { .rowField(row: "bar.badge", field: $0) })
        add(barRelease, ["id", "text", "icon", "options", "selected", "note"].map { .rowField(row: "menu", field: $0) })
        add(barRelease, ["id", "icon", "label", "options", "note"].map { .rowField(row: "bar.button", field: $0) })
        add(barRelease, ["id", "text", "group", "note", "tone"].map { .rowField(row: "menu.options", field: $0) })
        add(barRelease, ["run", "wait", "idle", "ok", "warn", "crit", "info"].map { .tone($0) })
        add(barRelease, ["plus", "history", "folder", "model", "effort", "account", "gear", "run", "wait", "done", "idle",
                    "info"].map { .barIcon($0) })

        // Something waits for the person — the island says so, and the peek
        // shows its question first: 0.9.10.
        let attentionRelease = ContractRelease.released(SemanticVersion(major: 0, minor: 9, patch: 10))
        add(attentionRelease, [.cardField("attention")])
        add(attentionRelease, ["count", "ask"].map { .rowField(row: "attention", field: $0) })

        // A button at the end of a menu's option — a session closed from the
        // list of them: 0.9.14.
        let optionButtonRelease = ContractRelease.released(SemanticVersion(major: 0, minor: 9, patch: 14))
        add(optionButtonRelease, [.rowField(row: "menu.options", field: "button")])
        add(optionButtonRelease, ["id", "label"].map { .rowField(row: "menu.options.button", field: $0) })

        // Files sent with a message — dragged, pasted, chosen with 📎: the
        // release after 0.9.16.
        add(.next, [.rowField(row: "input", field: "files")])
        return registry
    }()

    /// The release that brought `feature`, or nil for something that is not
    /// part of the contract.
    public static func release(of feature: ContractFeature) -> ContractRelease? { registry[feature] }

    /// The oldest uDeck that reads `minUDeck` at all. A `minUDeck` below it
    /// means the same as none: an older uDeck ignores the field.
    public static var minimumUDeckReadFrom: ContractRelease { readFrom(registry) }

    static func readFrom(_ registry: [ContractFeature: ContractRelease]) -> ContractRelease {
        registry[.manifestField("minUDeck")] ?? .next
    }

    /// What a manifest and its translations use of the contract. A field left
    /// out or given as `null` is not used; a field the contract does not
    /// define is not part of it and is left to rule 12.
    static func used(by manifest: StrictJSON.Object, translations: [StrictJSON.Object],
                     registry: [ContractFeature: ContractRelease] = registry) -> Set<ContractFeature> {
        var used = Set<ContractFeature>()
        func present(_ object: StrictJSON.Object?) -> [String] {
            (object?.keys ?? []).filter { object?.last($0)?.isNull == false }
        }
        for field in present(manifest) where field != "minUDeck" { used.insert(.manifestField(field)) }
        if let kind = manifest.last("kind")?.string { used.insert(.pluginKind(kind)) }
        for field in present(manifest.last("permissions")?.object) { used.insert(.permission(field)) }
        for field in present(manifest.last("window")?.object) { used.insert(.windowField(field)) }
        for setting in manifest.last("settings")?.array ?? [] {
            let object = setting.object
            for field in present(object) { used.insert(.settingField(field)) }
            if let type = object?.last("type")?.string { used.insert(.settingType(type)) }
            for option in object?.last("options")?.array ?? [] {
                for field in present(option.object) { used.insert(.optionField(field)) }
            }
        }
        if !translations.isEmpty { used.insert(.translations) }
        for translation in translations {
            for field in present(translation) { used.insert(.translationField(field)) }
            for key in translation.last("settings")?.object?.keys ?? [] {
                for field in present(translation.last("settings")?.object?.last(key)?.object) {
                    used.insert(.settingTranslationField(field))
                }
            }
        }
        return used.filter { registry[$0] != nil }
    }

    /// What a card a producer printed uses of the contract — which only a run
    /// shows (`udeck-plugin run`): its fields, states, row types, the fields of
    /// each row, icons, alignments and the fields of its actions. As for a
    /// manifest, `null` is not used, and what the contract does not define is
    /// left out.
    static func used(byCard card: StrictJSON.Object,
                     registry: [ContractFeature: ContractRelease] = registry) -> Set<ContractFeature> {
        var used = Set<ContractFeature>()
        func present(_ object: StrictJSON.Object?) -> [String] {
            (object?.keys ?? []).filter { object?.first($0)?.isNull == false }
        }
        func state(_ value: StrictJSON.Value?) {
            if let text = value?.string { used.insert(.cardState(text)) }
        }
        for field in present(card) { used.insert(.cardField(field)) }
        for field in present(card.first("attention")?.object) { used.insert(.rowField(row: "attention", field: field)) }
        state(card.first("state"))
        for row in card.first("rows")?.array ?? [] {
            guard let object = row.object, object.keys.count == 1, let kind = object.keys.first else { continue }
            used.insert(.row(kind))
            let body = object.first(kind)
            switch kind {
            case "kv":
                if let items = body?.array, items.count > 2 { state(items[2]) }
            case "list":
                for item in body?.array ?? [] {
                    for field in present(item.object) { used.insert(.rowField(row: "list", field: field)) }
                    if let icon = item.object?.first("icon")?.string { used.insert(.listIcon(icon)) }
                    state(item.object?.first("state"))
                }
            case "table":
                for field in present(body?.object) { used.insert(.rowField(row: "table", field: field)) }
                for column in body?.object?.first("columns")?.array ?? [] {
                    for field in present(column.object) { used.insert(.rowField(row: "table.columns", field: field)) }
                    if let align = column.object?.first("align")?.string { used.insert(.tableAlignment(align)) }
                }
            case "bar":
                for field in present(body?.object) { used.insert(.rowField(row: "bar", field: field)) }
                for item in body?.object?.first("items")?.array ?? [] {
                    guard let itemObject = item.object, itemObject.keys.count == 1, let name = itemObject.keys.first
                    else { continue }
                    used.insert(.rowField(row: "bar.items", field: name))
                    let inner = itemObject.first(name)?.object
                    let path = name == "menu" ? "menu" : "bar." + name
                    for field in present(inner) { used.insert(.rowField(row: path, field: field)) }
                    if let tone = inner?.first("tone")?.string { used.insert(.tone(tone)) }
                    if let icon = inner?.first("icon")?.string { used.insert(.barIcon(icon)) }
                    for option in inner?.first("options")?.array ?? [] {
                        for field in present(option.object) { used.insert(.rowField(row: "menu.options", field: field)) }
                        for field in present(option.object?.first("button")?.object) {
                            used.insert(.rowField(row: "menu.options.button", field: field))
                        }
                    }
                }
            case "feed":
                for entry in body?.array ?? [] {
                    for field in present(entry.object) { used.insert(.rowField(row: "feed", field: field)) }
                }
            case "input":
                for field in present(body?.object) { used.insert(.rowField(row: "input", field: field)) }
                for picker in body?.object?.first("pickers")?.array ?? [] {
                    for field in present(picker.object) { used.insert(.rowField(row: "menu", field: field)) }
                    if let icon = picker.object?.first("icon")?.string { used.insert(.barIcon(icon)) }
                    for option in picker.object?.first("options")?.array ?? [] {
                        for field in present(option.object) { used.insert(.rowField(row: "menu.options", field: field)) }
                        for field in present(option.object?.first("button")?.object) {
                            used.insert(.rowField(row: "menu.options.button", field: field))
                        }
                    }
                }
            default:
                for field in present(body?.object) { used.insert(.rowField(row: kind, field: field)) }
                state(body?.object?.first("state"))
            }
        }
        for action in card.first("actions")?.array ?? [] {
            for field in present(action.object) { used.insert(.actionField(field)) }
        }
        return used.filter { registry[$0] != nil }
    }

    /// What `udeck-plugin run` says of a card that uses more than the
    /// manifest's `minUDeck` promises: the same reckoning as rule 19, for what
    /// only a run shows. Nil when the card asks nothing of uDeck that every
    /// uDeck the plugin installs on has.
    static func cardNeedsNewerUDeck(_ card: StrictJSON.Object, minUDeck declaredText: String?,
                                    registry: [ContractFeature: ContractRelease] = registry) -> String? {
        let needed = minimum(for: used(byCard: card, registry: registry), registry: registry)
        guard let feature = needed.because else { return nil }
        let because = "the card uses \(feature), which \(needed.release) brought"
        if let declaredText, let declared = SemanticVersion(declaredText) {
            guard !needed.release.isMet(by: declared) else { return nil }
            return "\(because), and \"minUDeck\" is \(declared): an older uDeck would install the plugin and not "
                + "draw that"
        }
        guard needed.release > readFrom(registry) else { return nil }
        return "\(because), and the manifest has no \"minUDeck\": an older uDeck would install the plugin and not "
            + "draw that"
    }

    /// The lowest release that has all of `features`, and the feature that
    /// decides it — nil when that is the first release anyway.
    static func minimum(for features: Set<ContractFeature>, registry: [ContractFeature: ContractRelease] = registry)
        -> (release: ContractRelease, because: ContractFeature?) {
        var result: (release: ContractRelease, because: ContractFeature?) = (firstRelease, nil)
        for feature in features.sorted(by: { $0.description < $1.description }) {
            if let release = registry[feature], release > result.release { result = (release, feature) }
        }
        return result
    }

    /// Rule 19: `minUDeck` is not below the release that has everything the
    /// plugin uses — an error — and is said to do nothing when it is not
    /// above the release that first reads it: every uDeck that reads it meets
    /// it anyway. A `minUDeck` above what the plugin uses is the author's to
    /// set: something changed in how uDeck behaves that no part of the contract
    /// names, and they know it.
    static func checkMinimumUDeck(_ manifest: StrictJSON.Object, translations: [StrictJSON.Object], path: String,
                                  registry: [ContractFeature: ContractRelease] = registry, report: inout CheckReport) {
        let needed = minimum(for: used(by: manifest, translations: translations, registry: registry), registry: registry)
        let minimumUDeckReadFrom = readFrom(registry)
        let because = needed.because.map { ": it uses \($0), which \(needed.release) brought" } ?? ""
        let declaredValue = manifest.last("minUDeck")
        if let declaredValue, !declaredValue.isNull {
            // Not text, or not a version: rules 3 and 4 say so.
            guard let text = declaredValue.string, let declared = SemanticVersion(text) else { return }
            if !needed.release.isMet(by: declared) {
                report.error(CheckRule.minimumUDeck, path, "\"minUDeck\" is \(declared), and the plugin needs "
                             + "\(needed.release)\(because)")
            } else if minimumUDeckReadFrom.isAtLeast(declared) {
                report.warning(CheckRule.minimumUDeck, path, "\"minUDeck\" is \(declared), which does nothing: "
                               + "\"minUDeck\" is read from \(minimumUDeckReadFrom) on, and every uDeck that reads it "
                               + "is \(declared) or later; leave it out")
            }
        } else if needed.release > minimumUDeckReadFrom {
            report.error(CheckRule.minimumUDeck, path, "has no \"minUDeck\", and the plugin needs \(needed.release)\(because); "
                         + "without it an older uDeck installs a plugin it cannot run")
        }
    }
}
