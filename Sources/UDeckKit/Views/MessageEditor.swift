import AppKit
import SwiftUI

/// The text of a card's input row: an AppKit text view in a scroll view.
///
/// A SwiftUI field grew to its last allowed line and then went no further —
/// a longer message could not be scrolled to (11-26). This one grows from one
/// line to `maxLines` and then scrolls inside, keeping the caret in view. A
/// paste of files is the paste itself, from the Edit menu's ⌘V whatever the
/// keyboard layout; Return sends and Shift-Return starts a new line; Escape is
/// Stop. And what is typed while the panel has the keyboard but no field does
/// — after a click on an answer in the feed — goes into the field it belongs
/// to (`TypingIntoTheField`), as a chat's field takes it.
struct MessageEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var textColor: NSColor
    var placeholderColor: NSColor
    var enabled: Bool
    var maxLines: Int
    var identifier: String
    var onSubmit: () -> Void
    var onEscape: (() -> Void)?
    /// A paste the row takes as files: true when it did.
    var onPasteFiles: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        let view = EditorTextView()
        view.coordinator = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        scroll.documentView = view
        context.coordinator.view = view
        apply(to: view)
        view.string = text
        TypingIntoTheField.shared.register(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? EditorTextView else { return }
        apply(to: view)
        // Put back by the plugin, a draft restored, sent and emptied: the text
        // from outside replaces what is shown, the caret at its end.
        // Not while an input method composes a word: that text is not ours yet.
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            view.scrollRangeToVisible(view.selectedRange())
        }
        view.needsDisplay = true
    }

    private func apply(to view: EditorTextView) {
        view.font = font
        view.textColor = textColor
        view.insertionPointColor = textColor
        view.typingAttributes = [.font: font, .foregroundColor: textColor]
        view.isEditable = enabled
        view.isSelectable = true
        view.placeholder = placeholder
        view.placeholderColor = placeholderColor
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityPlaceholderValue(placeholder)
    }

    /// One line to `maxLines` tall, by what the text takes at the width given.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? NSTextView, let layout = view.layoutManager,
              let container = view.textContainer else { return nil }
        let width = proposal.width ?? scroll.frame.width
        guard width.isFinite, width > 0 else { return nil }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: font)
        let used = max(line, layout.usedRect(for: container).height)
        return CGSize(width: width, height: min(used, line * CGFloat(max(1, maxLines))).rounded(.up))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageEditor
        weak var view: EditorTextView?

        init(_ parent: MessageEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
            view.scrollRangeToVisible(view.selectedRange())
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift-Return, and Option-Return, a new line; Return sends.
                let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                // A word being composed (an input method's marked text) is
                // the input method's Return, not a send.
                if textView.hasMarkedText() { return false }
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard let escape = parent.onEscape else { return false }
                escape()
                return true
            default:
                return false
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            if let view { TypingIntoTheField.shared.focused(view) }
        }
    }
}

/// The text view of a `MessageEditor`: a paste of files goes to its row, and
/// an empty one shows its placeholder.
final class EditorTextView: NSTextView {
    weak var coordinator: MessageEditor.Coordinator?
    var placeholder = ""
    var placeholderColor = NSColor.placeholderTextColor

    override func paste(_ sender: Any?) {
        if coordinator?.parent.onPasteFiles() == true { return }
        pasteAsPlainText(sender)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { TypingIntoTheField.shared.focused(self) }
        return became
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: placeholderColor]
        let inset = textContainerInset
        let padding = textContainer?.lineFragmentPadding ?? 0
        NSString(string: placeholder).draw(
            with: NSRect(x: inset.width + padding, y: inset.height, width: bounds.width - padding * 2,
                         height: bounds.height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// What is typed while a panel has the keyboard but no field does goes into
/// a card's field: the one whose card is under what has the keyboard — an
/// answer clicked in the feed — or else the one typed in last. The operator,
/// 11-26: «когда я нажимаю на твой ответ … текст в поле ввода не печатается, а
/// хотелось бы чтобы печаталось сразу, раз я в активном окне».
///
/// Only characters: ⌘ and ⌃ shortcuts (⌘C to copy what was selected), arrows,
/// Return, Tab and Escape are left to whatever has the keyboard.
@MainActor
final class TypingIntoTheField {
    static let shared = TypingIntoTheField()

    private final class Weak { weak var view: EditorTextView?; init(_ view: EditorTextView) { self.view = view } }
    private var editors: [Weak] = []
    private weak var last: EditorTextView?
    private var monitor: Any?

    func register(_ view: EditorTextView) {
        editors.removeAll { $0.view == nil }
        editors.append(Weak(view))
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            TypingIntoTheField.shared.redirect(event)
        }
    }

    func focused(_ view: EditorTextView) { last = view }

    private func redirect(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, window.isKeyWindow, Self.types(event) else { return event }
        if let editing = window.firstResponder as? NSTextView, editing.isEditable { return event }
        guard let target = target(in: window) else { return event }
        guard window.makeFirstResponder(target) else { return event }
        target.setSelectedRange(NSRange(location: (target.string as NSString).length, length: 0))
        target.keyDown(with: event)
        return nil
    }

    /// A key that types: characters, with no ⌘ or ⌃.
    static func types(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .function]) else { return false }
        guard let characters = event.characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    /// The field of the card under what has the keyboard: the editor whose
    /// column holds it, the nearest below it; else the one typed in last.
    private func target(in window: NSWindow) -> EditorTextView? {
        let live = editors.compactMap(\.view).filter { $0.window == window && $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
        guard !live.isEmpty else { return nil }
        if let responder = window.firstResponder as? NSView, responder !== window.contentView {
            let point = responder.convert(NSPoint(x: responder.bounds.midX, y: responder.bounds.midY), to: nil)
            let column = live.filter { editor in
                let frame = editor.convert(editor.bounds, to: nil)
                return frame.minX <= point.x && point.x <= frame.maxX
            }
            // Window coordinates grow upwards: the field under the answer is lower.
            if let below = column.filter({ $0.convert($0.bounds, to: nil).maxY <= point.y })
                .max(by: { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY }) {
                return below
            }
        }
        if let last, live.contains(last) { return last }
        return live.count == 1 ? live.first : nil
    }
}
