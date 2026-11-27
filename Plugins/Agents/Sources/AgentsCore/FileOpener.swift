import Foundation

/// A `file:` link clicked in the feed (uDeck 0.9.27): the file in the editor
/// at its line, or with ⌘ in Finder, with ⌥ in Quick Look; a folder in
/// Finder. The editor is the setting's: the Mac's own choice for the file,
/// or VS Code, Xcode, Cursor, Zed by their own ways of opening at a line.
enum FileOpener {
    /// What runs for a link: the program and its arguments.
    static func command(_ link: String, keys: Set<String>, editor: String) -> (String, [String])? {
        guard let url = URL(string: link), url.isFileURL else { return nil }
        let path = url.path
        let line = url.fragment.flatMap { $0.hasPrefix("L") ? Int($0.dropFirst()) : nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return nil }
        if keys.contains("command") { return ("/usr/bin/open", ["-R", path]) }
        if keys.contains("option") { return ("/usr/bin/qlmanage", ["-p", path]) }
        if directory.boolValue { return ("/usr/bin/open", [path]) }
        let at = line.map { ":\($0)" } ?? ""
        switch editor {
        case "vscode": return ("/usr/bin/open", ["vscode://file" + path + at])
        case "cursor": return ("/usr/bin/open", ["cursor://file" + path + at])
        case "zed": return ("/usr/bin/open", ["zed://file" + path + at])
        case "xcode": return line.map { ("/usr/bin/xed", ["--line", String($0), path]) } ?? ("/usr/bin/xed", [path])
        default: return ("/usr/bin/open", [path])
        }
    }

    static func open(_ link: String, keys: Set<String>, editor: String) {
        guard let (program, arguments) = command(link, keys: keys, editor: editor) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
