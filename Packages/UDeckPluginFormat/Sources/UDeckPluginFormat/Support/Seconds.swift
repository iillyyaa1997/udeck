#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Converting a duration in seconds into the nanoseconds `Task.sleep` wants.
///
/// This exists because the obvious spelling — `UInt64(seconds * 1_000_000_000)`
/// — **traps** for a large enough value, and it does not take a hostile plugin
/// to reach one. `UInt64.max` is about 1.8e19 nanoseconds, so any duration past
/// roughly 585 years overflows, and a manifest saying `"interval": 86400000000`
/// is an ordinary typo. A trap is uncatchable: it takes the whole application
/// down, and because the plugin's window is by then saved in the layout, it
/// takes it down again on every launch afterwards.
///
/// So the conversion saturates instead. Anything a producer could plausibly
/// mean fits; anything it could not is clamped to the ceiling rather than
/// aborting the process.
public enum Seconds {
    /// The longest duration uDeck will wait for anything. A day is far past any
    /// sensible poll interval and far inside what `UInt64` can hold.
    public static let ceiling: TimeInterval = 24 * 60 * 60

    public static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds, ceiling) * 1_000_000_000)
    }

    /// `String(format: "%.1f", seconds)`, without Foundation: the C library's
    /// own `%.1f`. On a Mac a test holds the two to the same text for every
    /// value it tries, the halves that round either way among them — so a
    /// failure says "2.5s" in the words it always has.
    public static func oneDecimal(_ seconds: Double) -> String {
        fixed(seconds, places: 1)
    }

    /// `seconds` with `places` digits after the point, as `%.*f` writes it.
    public static func fixed(_ seconds: Double, places: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        while true {
            let needed = withVaList([Int32(max(0, min(places, 20))), seconds]) { arguments in
                buffer.withUnsafeMutableBufferPointer { vsnprintf($0.baseAddress, $0.count, "%.*f", arguments) }
            }
            guard needed >= 0 else { return "" }
            if Int(needed) < buffer.count {
                return String(decoding: buffer.prefix(Int(needed)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            buffer = [CChar](repeating: 0, count: Int(needed) + 1)
        }
    }
}
