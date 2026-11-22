import Foundation
import Security

/// Who uDeck and its helper accept on the other end of their connection.
///
/// The helper answers permission asks for agents that run shell commands, so
/// the one thing it must never do is take an answer from one of those
/// commands — and uDeck must never take a forged event, or hand a session's
/// environment, to something posing as the helper. Both ends are the same
/// user, so neither a private folder nor a uid check tells them apart. Code
/// signatures do: each side sets a requirement on its XPC connection, and the
/// system checks it against the sender of every message (by the audit token
/// that message carries — not by a pid, and not once at connect time, which a
/// process could satisfy and then hand its end to another).
///
/// The requirement is fixed when the side starts, never read again from disk:
/// - Developer ID build: "signed by this team, with this identifier", from the
///   running code's own signature — replacing the files on disk changes nothing.
/// - Ad-hoc build (development, the lab): the other side's exact code hash, read
///   once at start from the bundle this code came from. An ad-hoc build is not
///   a security boundary: whoever can replace the bundle can replace both sides.
public enum CodeIdentity {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public struct Signature: Sendable, Equatable {
        /// The signing identifier (`codesign --identifier`), not the bundle's
        /// Info.plist.
        public let identifier: String
        /// The Developer ID team; nil for an ad-hoc signature.
        public let team: String?
    }

    /// This process's own signature — read from disk, then held against the
    /// running code itself, so a bundle swapped underneath the process cannot
    /// change what it believes it is. Throws rather than guessing: a process
    /// that cannot tell who it is must not decide whom to trust.
    public static func ownSignature() throws -> Signature {
        let code = try ownStaticCode()
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess,
            let dictionary = info as? [String: Any],
            let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        else { throw Failure("this process's signature cannot be read") }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        let expected = try team.map { teamRequirement(identifier: identifier, team: $0) } ?? ownRequirement()
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expected as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement
        else { throw Failure("not a code requirement: \(expected)") }
        var running: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &running) == errSecSuccess, let running else {
            throw Failure("no own code")
        }
        let valid = SecCodeCheckValidity(running, SecCSFlags(), requirement)
        guard valid == errSecSuccess else {
            throw Failure("the running code does not match its own signature on disk (\(valid))")
        }
        return Signature(identifier: identifier, team: team)
    }

    /// This process's own designated requirement.
    public static func ownRequirement() throws -> String {
        try text(of: designated(try ownStaticCode()))
    }

    /// The designated requirement of the code at `url` (a bundle or a binary).
    public static func designatedRequirement(ofCodeAt url: URL) throws -> String {
        var code: SecStaticCode?
        let opened = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code)
        guard opened == errSecSuccess, let code else { throw Failure("cannot read the code at \(url.path) (\(opened))") }
        return try text(of: designated(code))
    }

    /// "Signed with a Developer ID of `team`, with this identifier."
    public static func teamRequirement(identifier: String, team: String) -> String {
        #"anchor apple generic and certificate leaf[subject.OU] = "\#(team)" and identifier "\#(identifier)""#
    }

    /// What this side requires of the other: same team and the other's
    /// identifier when this side has a team, else the other's code hash as
    /// found at `codeAt` now.
    public static func peerRequirement(identifier: String, codeAt url: URL) throws -> String {
        if let team = try ownSignature().team { return teamRequirement(identifier: identifier, team: team) }
        return try designatedRequirement(ofCodeAt: url)
    }

    /// Throws unless `text` is a requirement Security can use.
    public static func validate(_ text: String) throws {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              requirement != nil
        else { throw Failure("not a code requirement: \(text)") }
    }

    /// The application bundle a helper at `executable` lives in:
    /// `X.app/Contents/Helpers/udeck-agentd` belongs to `X.app`.
    public static func enclosingApplication(of executable: URL) -> URL? {
        let helpers = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app"
        else { return nil }
        return bundle
    }

    static func ownStaticCode() throws -> SecStaticCode {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { throw Failure("no own code") }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            throw Failure("no own static code")
        }
        return staticCode
    }

    private static func designated(_ code: SecStaticCode) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else {
            throw Failure("the code has no designated requirement (\(status)) — is it signed?")
        }
        return requirement
    }

    private static func text(of requirement: SecRequirement) throws -> String {
        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess, let text else {
            throw Failure("the requirement cannot be printed")
        }
        return text as String
    }
}
