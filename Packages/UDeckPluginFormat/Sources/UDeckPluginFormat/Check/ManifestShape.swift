/// The shape of a manifest and of its translations, field by field, as JSON
/// strictly read (`StrictJSON`) — every mismatch at once, where a decoder
/// stops at the first.
///
/// What each field has to be is the plugin contract's, and uDeck's decoder is
/// the final word on it: the strict check runs this first, for an author who
/// wants the whole list, and `JSONDecoder` right after, for anything this does
/// not know. The names of the fields come from the decoders themselves
/// (`CodingKeys`), so a field uDeck learns is a field the check knows.
///
/// A field given as `null` is the same as one left out, as it is to Swift's
/// `decodeIfPresent`; a required one is not. A field given twice counts the
/// second time, as it did in the Python check — the repeat is already an error.
enum ManifestShape {
    static var manifestFields: Set<String> { Set(PluginManifest.CodingKeys.allCases.map(\.stringValue)) }
    /// The manifest's fields that the contract defines: every one uDeck's
    /// decoder reads but `restart` (`ContractFeatures.outsideTheContract`).
    static var contractFields: Set<String> { manifestFields.subtracting(ContractFeatures.outsideTheContract) }
    static var permissionFields: Set<String> { Set(PermissionRequest.CodingKeys.allCases.map(\.stringValue)) }
    static var windowFields: Set<String> { Set(WindowHints.CodingKeys.allCases.map(\.stringValue)) }
    static var restartFields: Set<String> { Set(RestartPolicy.CodingKeys.allCases.map(\.stringValue)) }
    static var settingFields: Set<String> { Set(SettingDeclaration.CodingKeys.allCases.map(\.stringValue)) }
    static var optionFields: Set<String> { Set(SettingOption.CodingKeys.allCases.map(\.stringValue)) }
    static var translationFields: Set<String> { Set(ManifestTranslation.CodingKeys.allCases.map(\.stringValue)) }
    static var settingTranslationFields: Set<String> { Set(SettingTranslation.CodingKeys.allCases.map(\.stringValue)) }

    /// What a value is, in the words of a message.
    static func kind(of value: StrictJSON.Value) -> String {
        switch value {
        case .null: "null"
        case .bool: "true or false"
        case .number: "a number"
        case .string: "a string"
        case .array: "a list"
        case .object: "an object"
        }
    }

    /// A whole number written as one — `3`, not `3.0` — that fits in an `Int`.
    static func isInteger(_ value: StrictJSON.Value) -> Bool {
        guard let number = value.number else { return false }
        return number.isIntegerLiteral && number.wholeValue != nil
    }

    static func isStringList(_ value: StrictJSON.Value) -> Bool {
        value.array?.allSatisfy { $0.string != nil } == true
    }

    /// Type checks on one object, every mismatch collected.
    struct Fields {
        let object: StrictJSON.Object
        let place: String
        var wrong: [String] = []

        init(_ object: StrictJSON.Object, _ place: String = "") {
            self.object = object
            self.place = place
        }

        @discardableResult
        mutating func check(_ field: String, _ what: String, required: Bool = false,
                            _ test: (StrictJSON.Value) -> Bool) -> StrictJSON.Value? {
            guard let value = object.last(field), !value.isNull else {
                if required { wrong.append("\"\(place)\(field)\" is required") }
                return nil
            }
            guard test(value) else {
                wrong.append("\"\(place)\(field)\" must be \(what), not \(ManifestShape.kind(of: value))")
                return nil
            }
            return value
        }

        mutating func string(_ field: String, required: Bool = false) {
            check(field, "a string", required: required) { $0.string != nil }
        }
    }

    /// Why uDeck's decoder would refuse this manifest, as far as its shape says.
    static func problems(of manifest: StrictJSON.Value) -> [String] {
        guard let object = manifest.object else { return ["must be a JSON object"] }
        var top = Fields(object)
        if let id = top.check("id", "a string", required: true, { $0.string != nil })?.string,
           PluginIdentifier(rawValue: id) == nil {
            top.wrong.append("\"id\" is \"\(id)\", which is not a plugin id: lowercase letters, digits and \"._-\", "
                             + "1-64 characters, starting with a letter or digit")
        }
        top.string("name", required: true)
        top.string("version", required: true)
        top.check("api", "a whole number", required: true, isInteger)
        top.check("kind", PluginKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or "), required: true) {
            $0.string.flatMap(PluginKind.init(rawValue:)) != nil
        }
        for field in ["description", "author", "homepage", "minUDeck"] { top.string(field) }
        top.check("run", "a list of strings", required: true, isStringList)
        for field in ["interval", "timeout"] { top.check(field, "a number of seconds") { $0.number != nil } }
        // Every field of the top level is looked at before its mistakes are
        // taken: these three are too, and one of the wrong kind is said here,
        // in words, not left to the decoder.
        let permissions = top.check("permissions", "an object") { $0.object != nil }?.object
        let settings = top.check("settings", "a list") { $0.array != nil }?.array
        let window = top.check("window", "an object") { $0.object != nil }?.object
        var wrong = top.wrong

        if let permissions {
            var inner = Fields(permissions, "permissions.")
            for field in ["read", "write", "exec", "network", "secrets"] { inner.check(field, "a list of strings", isStringList) }
            inner.check("screen", "true or false") { if case .bool = $0 { true } else { false } }
            wrong += inner.wrong
        }

        if let settings {
            for (index, declaration) in settings.enumerated() {
                let place = "settings[\(index)]"
                guard let object = declaration.object else {
                    wrong.append("\"\(place)\" must be an object, not \(kind(of: declaration))")
                    continue
                }
                var inner = Fields(object, place + ".")
                inner.string("key", required: true)
                inner.check("type", "\"bool\", \"int\", \"string\" or \"enum\"", required: true) {
                    $0.string.flatMap(SettingDeclaration.Kind.init(rawValue:)) != nil
                }
                inner.string("label", required: true)
                inner.string("help")
                inner.check("default", "true or false, a whole number or a string", required: true) {
                    if case .bool = $0 { return true }
                    return $0.string != nil || isInteger($0)
                }
                inner.check("min", "a whole number", isInteger)
                inner.check("max", "a whole number", isInteger)
                let options = inner.check("options", "a list") { $0.array != nil }?.array ?? []
                wrong += inner.wrong
                for (number, option) in options.enumerated() {
                    let where_ = "\(place).options[\(number)]"
                    guard let object = option.object else {
                        wrong.append("\"\(where_)\" must be an object, not \(kind(of: option))")
                        continue
                    }
                    var each = Fields(object, where_ + ".")
                    each.string("value", required: true)
                    each.string("label", required: true)
                    wrong += each.wrong
                }
            }
        }

        if let window {
            var inner = Fields(window, "window.")
            for field in windowFields.sorted() { inner.check(field, "a whole number", isInteger) }
            wrong += inner.wrong
        }
        return wrong
    }

    /// Fields a manifest has that the contract does not define, as
    /// `permissions.scren` — `restart` among them, and any field inside it
    /// that uDeck's decoder does not know either.
    static func unknownFields(of manifest: StrictJSON.Object) -> [String] {
        func unknown(_ value: StrictJSON.Value?, _ known: Set<String>, _ place: String) -> [String] {
            (value?.object?.keys ?? []).filter { !known.contains($0) }.map { place + $0 }
        }
        var found = unknown(.object(manifest), contractFields, "")
        found += unknown(manifest.last("permissions"), permissionFields, "permissions.")
        found += unknown(manifest.last("window"), windowFields, "window.")
        found += unknown(manifest.last("restart"), restartFields, "restart.")
        for (index, declaration) in (manifest.last("settings")?.array ?? []).enumerated() {
            let place = "settings[\(index)]."
            found += unknown(declaration, settingFields, place)
            for (number, option) in (declaration.object?.last("options")?.array ?? []).enumerated() {
                found += unknown(option, optionFields, "\(place)options[\(number)].")
            }
        }
        return found
    }

    /// What in a translation the contract does not define.
    ///
    /// A setting key or an option value that `manifest.json` does not declare
    /// is included: uDeck ignores it, so the label it carries never appears,
    /// and the reason is nearly always a typo in the key. That comparison
    /// needs a manifest that decodes, and is skipped when `manifest` is nil.
    static func translationProblems(of translation: StrictJSON.Value, manifest: PluginManifest?) -> [String] {
        guard let object = translation.object else { return ["must be a JSON object"] }
        var top = Fields(object)
        top.string("name")
        top.string("description")
        var wrong = top.wrong + object.keys.filter { !translationFields.contains($0) }
            .map { "has the field \"\($0)\", which a translation does not have" }
        top.wrong = []
        let settings = top.check("settings", "an object keyed by setting key") { $0.object != nil }?.object
        wrong += top.wrong
        guard let settings else { return wrong }
        let declared = manifest.map { manifest in
            Dictionary(manifest.settings.map { ($0.key, Set(($0.options ?? []).map(\.value))) }) { first, _ in first }
        }
        for key in settings.keys {
            guard let entry = settings.last(key) else { continue }
            let place = "settings.\(key)"
            if let declared, declared[key] == nil {
                wrong.append("translates the setting \"\(key)\", which manifest.json does not declare")
            }
            guard let fields = entry.object else {
                wrong.append("\"\(place)\" must be an object, not \(kind(of: entry))")
                continue
            }
            var inner = Fields(fields, place + ".")
            inner.string("label")
            inner.string("help")
            wrong += inner.wrong + fields.keys.filter { !settingTranslationFields.contains($0) }
                .map { "has the field \"\(place).\($0)\", which a translation does not have" }
            inner.wrong = []
            let options = inner.check("options", "an object keyed by option value") { $0.object != nil }?.object
            wrong += inner.wrong
            for value in options?.keys ?? [] {
                if let label = options?.last(value), label.string == nil {
                    wrong.append("\"\(place).options.\(value)\" must be a string, not \(kind(of: label))")
                }
                if let declared, let values = declared[key], !values.contains(value) {
                    wrong.append("translates the option \"\(value)\" of \"\(key)\", which manifest.json does not declare")
                }
            }
        }
        return wrong
    }
}
