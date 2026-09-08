import OSLog

/// uDeck's logging.
///
/// The panel's behaviour depends on things that leave no trace on screen —
/// which gate stopped the gesture, why the panel closed, what a producer said.
/// Reconstructing that from a bug report is hopeless without a record, so the
/// interesting transitions are logged through the unified logging system, where
/// they cost nothing when nobody is listening and can be read afterwards with:
///
///     log stream --predicate 'subsystem == "place.unicorns.udeck"' --level debug
///
/// Nothing here logs the contents of a card. A plugin's output is the
/// operator's data, and a system-wide log is the wrong place for it.
public enum DeckLog {
    public static let subsystem = "place.unicorns.udeck"

    public static let panel = Logger(subsystem: subsystem, category: "panel")
    public static let gesture = Logger(subsystem: subsystem, category: "gesture")
    public static let plugins = Logger(subsystem: subsystem, category: "plugins")
}
