import Foundation

/// Reading and writing one JSON file, atomically.
///
/// Atomic because these files are rewritten on every layout change and every
/// settings edit; a partial write during a crash would leave the operator's
/// arrangement corrupt, and "your tabs are gone" is not a recoverable
/// impression.
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    public enum StoreError: Error, CustomStringConvertible {
        case unreadable(URL, underlying: any Error)
        case malformed(URL, underlying: any Error)
        case unwritable(URL, underlying: any Error)

        public var description: String {
            switch self {
            case .unreadable(let url, let error):
                "could not read \(url.path): \(error.localizedDescription)"
            case .malformed(let url, let error):
                "\(url.path) is not valid uDeck JSON: \(error)"
            case .unwritable(let url, let error):
                "could not write \(url.path): \(error.localizedDescription)"
            }
        }
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// See the note in `PluginDiscovery`: reached, not stored, so the store
    /// stays `Sendable`.
    private var fileManager: FileManager { .default }

    /// Loads the file, or returns nil when it does not exist yet.
    ///
    /// A missing file is a normal first-run state and not an error. A file that
    /// exists but cannot be parsed *is* an error and is thrown: silently
    /// replacing a corrupt settings file with defaults would destroy whatever
    /// the operator had configured, without telling them.
    public func load() throws -> Value? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.unreadable(url, underlying: error)
        }
        do {
            return try Self.decoder.decode(Value.self, from: data)
        } catch {
            throw StoreError.malformed(url, underlying: error)
        }
    }

    public func save(_ value: Value) throws {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try Self.encoder.encode(value)
            // `.atomic` writes to a temporary file in the same directory and
            // renames it into place, so a reader never sees a half-written file.
            try data.write(to: url, options: .atomic)
        } catch let error as EncodingError {
            throw StoreError.unwritable(url, underlying: error)
        } catch {
            throw StoreError.unwritable(url, underlying: error)
        }
    }

    /// Moves a file that could not be parsed out of the way and reports where it
    /// went, so the operator can look at it and the app can start.
    ///
    /// Only ever called on an explicit "reset this file" action — never
    /// automatically, because an unreadable file is more often a bug worth
    /// seeing than a file worth discarding.
    public func quarantine(now: Date = Date()) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let destination = url.deletingPathExtension()
            .appendingPathExtension("broken-\(stamp)")
            .appendingPathExtension(url.pathExtension)
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
