import Foundation

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
}
