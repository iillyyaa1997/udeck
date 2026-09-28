import Foundation
import Testing
@testable import UDeckCore

/// Git's two hashes, as uDeck computes them without git.
///
/// Every expected value here was made by git itself — `git hash-object` and
/// `git mktree` in a throwaway repository on 2026-09-28 — and the frozen copy of
/// `examples/hello-card` is the folder as it was at `f5a0ca3`, whose tree
/// GitHub's listing gave as `44fccaa8…`.
@Suite("Git hashes")
struct GitHashTests {
    @Test("a blob is SHA-1 of its header and its bytes, as git hash-object says")
    func blobs() {
        #expect(GitHash.blob(Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        #expect(GitHash.blob(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(GitHash.blob(Data("a\n".utf8)) == "78981922613b2afb6025042ff6bd878ac1994e85")
        #expect(GitHash.blob(Data("#!/bin/sh\necho hi\n".utf8)) == "4163036efa65bd4a469e752267498f01ea36a55c")
    }

    /// `lib.txt` sorts before the folder `lib`, and `lib0` after it, only
    /// because a folder is compared as if its name ended in `/`.
    @Test("a tree sorts its children as git does, a folder as if it ended in a slash")
    func trees() {
        let lib = GitHash.tree([GitHash.Entry(name: "x.txt", kind: .file, sha: "587be6b4c3f93f93c489c0111bba5596147a26cb")])
        #expect(lib == "0479003445f4e5a5ff25360c607ca79ffe4e4ea1")
        let root = GitHash.tree([
            GitHash.Entry(name: "lib0", kind: .file, sha: "26af6a865b61e9a47e24ea6214a64c4cc294c215"),
            GitHash.Entry(name: "run.sh", kind: .executable, sha: "4163036efa65bd4a469e752267498f01ea36a55c"),
            GitHash.Entry(name: "lib", kind: .folder, sha: "0479003445f4e5a5ff25360c607ca79ffe4e4ea1"),
            GitHash.Entry(name: "a.txt", kind: .file, sha: "78981922613b2afb6025042ff6bd878ac1994e85"),
            GitHash.Entry(name: "lib.txt", kind: .file, sha: "fcd8df65cbc4d6014863d5fac3206803543b116a"),
        ])
        #expect(root == "c240a5c659cd64cb9a309b2d52dab997c441ff4b")
    }

    @Test("an empty folder does not exist in git")
    func emptyTree() {
        #expect(GitHash.tree([]) == nil)
    }

    @Test("a folder on disk hashes as git would record it")
    func folderOnDisk() throws {
        let temp = TemporaryDirectory()
        let root = temp.url.appendingPathComponent("tree", isDirectory: true)
        func write(_ path: String, _ text: String, mode: Int = 0o644) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        try write("a.txt", "a\n")
        try write("run.sh", "#!/bin/sh\necho hi\n", mode: 0o755)
        try write("lib/x.txt", "x\n")
        try write("lib.txt", "lib text\n")
        try write("lib0", "zero\n")
        #expect(try GitHash.tree(ofDirectoryAt: root) == "c240a5c659cd64cb9a309b2d52dab997c441ff4b")

        // What an installed folder picks up without anyone meaning it to — a
        // Finder's .DS_Store, an empty folder, a link — changes nothing.
        try write(".DS_Store", "finder")
        try write("lib/.hidden", "x")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty/inner"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                   withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(try GitHash.tree(ofDirectoryAt: root) == "c240a5c659cd64cb9a309b2d52dab997c441ff4b")

        // And the owner's execute bit is the only one that counts.
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: root.appendingPathComponent("run.sh").path)
        #expect(try GitHash.tree(ofDirectoryAt: root) != "c240a5c659cd64cb9a309b2d52dab997c441ff4b")
        try FileManager.default.setAttributes([.posixPermissions: 0o744],
                                              ofItemAtPath: root.appendingPathComponent("run.sh").path)
        #expect(try GitHash.tree(ofDirectoryAt: root) == "c240a5c659cd64cb9a309b2d52dab997c441ff4b")
    }

    @Test("the frozen hello-card from f5a0ca3 hashes to the tree GitHub listed for it")
    func helloCard() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hello-card-f5a0ca3", isDirectory: true)
        #expect(try GitHash.blob(ofFileAt: folder.appendingPathComponent("hello.sh"))
                == "bbb88658d147ecca194cfd499345de5204bccc8f")
        #expect(try GitHash.tree(ofDirectoryAt: folder) == "44fccaa893276f9d6ee963108fb0a66f59534351")
    }

    @Test("an object id is forty lowercase hex characters")
    func objectIDs() {
        #expect(GitHash.isObjectID("44fccaa893276f9d6ee963108fb0a66f59534351"))
        #expect(!GitHash.isObjectID("44FCCAA893276F9D6EE963108FB0A66F59534351"))
        #expect(!GitHash.isObjectID("44fccaa"))
        #expect(!GitHash.isObjectID("../../../../../../../../../../../etc/passwd"))
    }
}
