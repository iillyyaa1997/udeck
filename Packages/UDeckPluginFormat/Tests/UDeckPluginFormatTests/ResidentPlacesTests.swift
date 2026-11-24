import Foundation
import Testing
@testable import UDeckPluginFormat

/// A resident plugin's card in several places: the card says which, and what
/// it shows there; uDeck's events say which place they are about.
@Suite("A resident card's places")
struct ResidentPlacesTests {
    @Test("a card names its place, what it keeps there and its name; one without names none")
    func cardPlace() {
        let line = #"{"card":{"title":"Agents","rows":[]},"view":"B5E1","keep":"{\"id\":\"x\"}","name":"Fix it"}"#
        guard case .card(let card, let place) = ResidentMessage(line: line) else {
            Issue.record("not a card")
            return
        }
        #expect(card.title == "Agents")
        #expect(place == CardPlace(view: "B5E1", keep: #"{"id":"x"}"#, name: "Fix it"))
        #expect(place.speaksOfPlaces)
        guard case .card(_, let none) = ResidentMessage(line: #"{"card":{"rows":[]}}"#) else {
            Issue.record("not a card")
            return
        }
        #expect(none == CardPlace())
        #expect(!none.speaksOfPlaces, "a plugin from before places is told of one")
    }

    @Test("a keep or a name too long for uDeck to hold is not held, and the card is still drawn")
    func limits() {
        let keep = String(repeating: "k", count: ResidentMessage.keepLimit + 1)
        let name = String(repeating: "n", count: ResidentMessage.nameLimit + 1)
        let line = #"{"card":{"rows":[]},"view":"v","keep":"\#(keep)","name":"\#(name)"}"#
        guard case .card(_, let place) = ResidentMessage(line: line) else {
            Issue.record("not a card")
            return
        }
        #expect(place == CardPlace(view: "v"))
        guard case .card(_, let empty) = ResidentMessage(line: #"{"card":{"rows":[]},"view":""}"#) else { return }
        #expect(empty.view == nil, "an empty name names no place")
    }

    @Test("a plugin asks for one of its places to be brought forward")
    func show() {
        #expect(ResidentMessage(line: #"{"show":{"view":"W"}}"#) == .show(view: "W"))
        #expect(ResidentMessage(line: #"{"show":{}}"#) == .unknown(#"{"show":{}}"#))
    }

    @Test("events say which place they are about: hello and size where it is, hello and closed what it kept")
    func eventLines() {
        let about = ResidentEvent.About(view: "W", place: "window", keep: "k")
        #expect(ResidentEvent.hello(columns: 6, rows: 12, language: "ru").line(about: about)
            == #"{"event":"hello","keep":"k","language":"ru","place":"window","size":{"columns":6,"rows":12},"view":"W"}"#)
        #expect(ResidentEvent.size(columns: 4, rows: 3).line(about: .init(view: "M", place: "mini"))
            == #"{"event":"size","place":"mini","size":{"columns":4,"rows":3},"view":"M"}"#)
        #expect(ResidentEvent.closed(to: "B").line(about: .init(view: "W", keep: "k"))
            == #"{"event":"closed","keep":"k","to":"B","view":"W"}"#)
        #expect(ResidentEvent.closed(to: nil).line(about: .init(view: "W"))
            == #"{"event":"closed","view":"W"}"#)
        #expect(ResidentEvent.press(id: "stop").line(about: .init(view: "B"))
            == #"{"event":"press","id":"stop","view":"B"}"#)
        #expect(ResidentEvent.press(id: "stop").line == #"{"event":"press","id":"stop"}"#, "and none without a place")
    }
}
