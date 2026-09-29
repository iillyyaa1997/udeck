import Foundation
import UDeckPluginFormat

extension Capability {
    /// The same line as `summary`, for a sheet that has a language.
    ///
    /// A consent dialogue is the one place in uDeck where being understood is
    /// not a convenience: somebody agreeing to let a program read their files
    /// has to be able to read the sentence saying so.
    public var summaryPhrase: Phrase {
        switch self {
        case .read(let glob): .capabilityRead(glob: glob)
        case .write(let glob): .capabilityWrite(glob: glob)
        case .exec(let command): .capabilityExec(command: command)
        case .network(let host): .capabilityNetwork(host: host)
        case .screen: .capabilityScreen
        case .secret(let name): .capabilitySecret(name: name)
        }
    }
}
