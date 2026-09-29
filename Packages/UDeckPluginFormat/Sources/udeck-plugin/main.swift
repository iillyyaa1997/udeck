// `udeck-plugin` as it stands: a placeholder with the library linked in.
//
// It exists so that CI can prove the library builds into a static Linux binary
// before any command is written on top of it. It checks nothing, says so, and
// exits 2 — "could not check", never "checked and fine" — so that nothing can
// mistake it for a passing check. It is not released.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import UDeckPluginFormat

print("udeck-plugin \(UDeckRelease.version)")
let notice = Array("check is not built yet\n".utf8)
_ = notice.withUnsafeBytes { write(2, $0.baseAddress, $0.count) }
exit(2)
