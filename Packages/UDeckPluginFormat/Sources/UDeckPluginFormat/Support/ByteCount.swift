/// A size, the way a row in Settings says it: `6 KB`, `1.4 MB`, `14 MB`.
///
/// Binary units under the everyday names, because the limits they are
/// measured against are binary: "up to 10 MB" is 10 MiB.
public enum ByteCount {
    public static func text(_ bytes: Int, kilo: String, mega: String, unit: String = "B",
                            separator: String = ".") -> String {
        if bytes < 1024 { return "\(max(bytes, 0)) \(unit)" }
        if bytes < 1024 * 1024 {
            return "\(Int((Double(bytes) / 1024).rounded(.up))) \(kilo)"
        }
        let megabytes = Double(bytes) / (1024 * 1024)
        if megabytes >= 10 { return "\(Int(megabytes.rounded())) \(mega)" }
        let tenths = Int((megabytes * 10).rounded())
        return "\(tenths / 10)\(separator)\(tenths % 10) \(mega)"
    }
}
