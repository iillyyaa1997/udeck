/// The uDeck release this copy of the format belongs to.
///
/// The library and `udeck-plugin` are built from the same commit as uDeck, so
/// they carry its version rather than one of their own. uDeck's tests hold this
/// to `CFBundleShortVersionString` in the app's Info.plist, so that the two
/// cannot say different numbers.
public enum UDeckRelease {
    public static let version = "0.6.0"
}
