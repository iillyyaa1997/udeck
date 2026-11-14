import Foundation
import Testing
@testable import UDeckCore

/// What a message says of an answer uDeck could not read (S4-20): the place a
/// decoder stopped at, in a few words — never the decoder's Swift description.
@Suite("What a bad answer is said as")
struct AnswerTroubleTests {
    struct Listing: Decodable {
        struct Entry: Decodable { var path: String; var mode: String }
        var sha: String
        var tree: [Entry]
    }

    func said(_ json: String) -> String {
        do {
            _ = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
            return "decoded"
        } catch {
            return AnswerTrouble.said(error)
        }
    }

    @Test("a missing key, a wrong type, a missing value and no JSON, each by where it is; anything else plainly")
    func eachByWhereItIs() {
        #expect(said(#"{"sha": "a"}"#) == "tree is missing")
        #expect(said(#"{"sha": "a", "tree": [{"path": "x", "mode": 7}]}"#) == "tree[0].mode is not what uDeck expects")
        #expect(said(#"{"sha": "a", "tree": [{"path": null, "mode": "100644"}]}"#) == "tree[0].path is not what uDeck expects")
        #expect(said("not json") == "the answer is not JSON")
        #expect(said(#"[1]"#) == "the answer was not what uDeck expects")
        #expect(AnswerTrouble.said(CocoaError(.fileReadCorruptFile)) == "the answer was not what uDeck expects")
        for json in [#"{"sha": "a"}"#, "not json", #"{"sha": "a", "tree": [{"path": "x", "mode": 7}]}"#] {
            #expect(!said(json).contains("DecodingError") && !said(json).contains("CodingKeys"), "\(json)")
        }
    }

    @Test("the gone commit of a GitLab's source names its host")
    func commitGoneNamesItsHost() {
        #expect(Strings(.english)(.catalogueCommitGone(commit: "a1b2c3d", host: "gitlab.example.test"))
                .hasPrefix("a1b2c3d is no longer on gitlab.example.test —"))
        #expect(Strings(.russian)(.catalogueCommitGone(commit: "a1b2c3d", host: "gitlab.example.test"))
                .hasPrefix("Коммита a1b2c3d больше нет на gitlab.example.test —"))
    }
}
