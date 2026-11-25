import Foundation

/// Files sent with a message (11-25): dragged onto the field, pasted with ⌘V
/// or chosen with 📎, uDeck sends their paths in `submit`. A picture goes to
/// the agent as a picture — Claude and Codex both look at them — and any other
/// file by its path, which the agent reads itself. A picture too big to send
/// goes by its path as well.
public struct SentFiles: Sendable, Equatable {
    public var pictures: [URL] = []
    public var others: [URL] = []

    /// Claude takes a picture up to 5 MB once in base64: about 3.75 MB of file.
    static let biggestPicture = 3_750_000
    static let pictureTypes: [String: String] = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                                 "gif": "image/gif", "webp": "image/webp"]

    public init(paths: [String]) {
        for path in paths where path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max
            if Self.pictureTypes[url.pathExtension.lowercased()] != nil, size <= Self.biggestPicture {
                pictures.append(url)
            } else {
                others.append(url)
            }
        }
    }

    public var isEmpty: Bool { pictures.isEmpty && others.isEmpty }

    /// The line the feed shows with the message: «📎 shot.png, notes.txt».
    public var shown: String? {
        isEmpty ? nil : "📎 " + (pictures + others).map(\.lastPathComponent).joined(separator: ", ")
    }

    /// What the agent is told of the files it reads itself: their paths.
    public var told: String? {
        guard !others.isEmpty else { return nil }
        return "Attached files (read them):\n" + others.map(\.path).joined(separator: "\n")
    }

    /// The message as the feed shows it and as the agent is told it.
    public func message(_ text: String) -> (shown: String, told: String) {
        let shown = [text.isEmpty ? nil : text, self.shown].compactMap { $0 }.joined(separator: "\n")
        let told = [text.isEmpty ? nil : text, self.told].compactMap { $0 }.joined(separator: "\n\n")
        return (shown, told.isEmpty ? "See the attached picture." : told)
    }

    /// The pictures as Claude takes them: the media type and the bytes in
    /// base64. One that cannot be read is left out.
    public func claudeImages() -> [(mediaType: String, base64: String)] {
        pictures.compactMap { url in
            guard let type = Self.pictureTypes[url.pathExtension.lowercased()],
                  let data = try? Data(contentsOf: url) else { return nil }
            return (type, data.base64EncodedString())
        }
    }
}
