import Foundation
import Testing
@testable import UDeckPluginFormat

/// A resident plugin's notification with buttons and a field to reply in,
/// and the answer that comes back.
@Suite("A plugin's notification, answered where it shows")
struct PluginNoticeTests {
    @Test("buttons and a field are read; a notice without them reads as before")
    func read() {
        let line = #"{"notify":{"id":"c-1","title":"Waiting","body":"ls","actions":[{"id":"allow:r1","text":"Allow"},{"id":"deny:r1","text":"Deny"}],"reply":{"button":"Reply","placeholder":"Message"}}}"#
        guard case .notify(let notice) = ResidentMessage(line: line) else {
            Issue.record("not a notice")
            return
        }
        #expect(notice.actions == [.init(id: "allow:r1", text: "Allow"), .init(id: "deny:r1", text: "Deny")])
        #expect(notice.reply == .init(button: "Reply", placeholder: "Message"))
        #expect(notice.answers)
        guard case .notify(let plain) = ResidentMessage(line: #"{"notify":{"id":"c-1","title":"Done","body":"ok"}}"#) else {
            Issue.record("not a notice")
            return
        }
        #expect(plain == PluginNotice(id: "c-1", title: "Done", body: "ok"))
        #expect(!plain.answers)
        #expect(ResidentMessage(line: #"{"unnotify":{"id":"c-1"}}"#) == .unnotify(id: "c-1"))
    }

    @Test("at most three buttons, each with an id and a text of its own; long words cut")
    func limits() {
        let many = (0..<5).map { PluginNotice.Action(id: "a\($0)", text: "Button \($0)") }
        let notice = PluginNotice(id: "n", title: "t", body: "b",
                                  actions: [.init(id: "", text: "no id"), .init(id: "a0", text: "")] + many
                                      + [.init(id: "a1", text: "twice")],
                                  reply: .init(button: String(repeating: "r", count: 100)))
        #expect(notice.actions.map(\.id) == ["a0", "a1", "a2"])
        #expect(notice.actions[0].text == "Button 0", "the first a0 had no text: the one with text is kept")
        #expect(notice.reply?.button.count == PluginNotice.textLimit)
        #expect(PluginNotice(id: "n", title: "t", body: "b", reply: .init(button: "")).reply == nil)
        let long = PluginNotice(id: "n", title: "t", body: "b",
                                actions: [.init(id: String(repeating: "x", count: PluginNotice.idLimit + 1), text: "x")])
        #expect(long.actions.isEmpty)
    }

    @Test("the answer says which button, or what was written")
    func answer() {
        #expect(ResidentEvent.notification(id: "c-1").line == #"{"event":"notification","id":"c-1"}"#)
        #expect(ResidentEvent.notification(id: "c-1", action: "allow:r1").line
            == #"{"action":"allow:r1","event":"notification","id":"c-1"}"#)
        #expect(ResidentEvent.notification(id: "c-1", text: "Green").line
            == #"{"event":"notification","id":"c-1","text":"Green"}"#)
    }
}
