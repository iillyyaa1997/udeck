// The lab's accessibility helper: uDeck's windows read the way System Events
// reads them, in one process and a fraction of a second.
//
// It runs *where uDeck runs*: inside the Tart guest, copied there when a machine
// boots, or on the GitHub runner that is its own guest (`--target here`) —
// never on the Mac that runs the lab against a guest. It is one file and no
// package: the lab compiles it with `xcrun swiftc -O`, keeps the binary under
// .build/e2e/ by this file's sha256, and reads what it prints in
// `udeck_e2e/ax.py`.
//
// Why it exists. The lab walked uDeck's windows with System Events AppleScript
// over SSH, one Apple event per attribute per element. On Settings → Plugins a
// walk took 40 to 76 s, sometimes more than the 180 s the lab allows, and left
// checks without a verdict. On a GitHub runner on 2026-10-12 (run 38210256960)
// the same three panes took System Events 7.9, 15.7 and 22.8 s and this helper
// 0.05 to 0.09 s.
//
// **It reads what System Events reads, and no more.** Same elements
// (`AXChildren`, in their own order), same attributes, values turned into text
// the way AppleScript turns them. One difference was measured and is copied on
// purpose: System Events answers only the attributes an element *lists* in
// `AXAttributeNames`. A SwiftUI button lists `AXAttributedDescription` and not
// `AXDescription`, so System Events read its description as "" while asking
// the accessibility API for `AXDescription` directly answers "Link a folder…"
// (run 38210592133: with only the listed attributes read, three panes walked
// both ways came out identical but for the digits of one slider's value). The
// checks were written against System Events' answers, so this helper gives
// those answers. `e2e/selfcheck/check_ax.py` holds the two walks against each
// other in a guest.
//
// What it prints is one JSON object on standard output. A refusal is a line on
// standard error and exit 1 (2 for a command line it cannot read), as osascript
// refused.
//
// Commands:
//
//   trusted                          {"trusted": AXIsProcessTrusted()}
//   windows PROCESS                  each window's title, subrole and frame
//   walk PROCESS WINDOW DEPTH        every element of a window, preorder (below)
//   menu PROCESS                     the titles in menu 1 of menu bar item 1 of menu bar 1
//   press-menu-item PROCESS TITLE    AXPress on that menu's item called TITLE
//   place PROCESS WINDOW X Y W H     a window moved and sized, and where it ended up
//   move-window PROCESS X Y          window 1 moved, and where it ended up
//   text PROCESS                     the value of text area 1 of scroll area 1 of window 1
//   focused PROCESS                  the titles of its focused and main windows
//   screen                           the main display, in points and pixels
//   set-mode WIDTH HEIGHT            the main display switched, for the login session, to a mode that size
//   pointer                          where the pointer is
//   move X Y | click X Y | right-click X Y | key NAME | scroll X Y DY
//
// PROCESS is a process name as `pgrep -x` matches it, and this user's own.
// WINDOW is `title=<the window's title>` or `panel`, the window whose subrole is
// AXSystemDialog — the panel, which has no title to find it by.
//
// `walk` lists the window at depth 0 and an element's children while its depth
// is below DEPTH: the shape of the AppleScript walks it replaces. Each element
// carries `shown`, whether its middle is inside the window, inside every scroll
// area around it and on the display — where a click at it lands on it.
//
// The pointer, key and scroll commands post events through the window server
// (CGEvent at the HID tap), for `--target here`: the machine running the lab
// *is* the guest there, and there is no VNC server to move a pointer through.
// In a Tart guest the pointer and the keyboard stay VNC's.

import AppKit
import ApplicationServices
import Darwin

// MARK: - Output

func emit(_ object: Any) -> Never {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        refuse("could not write the answer as JSON: \(error)")
    }
    exit(0)
}

func refuse(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("ax: \(message)\n".utf8))
    exit(code)
}

// MARK: - Processes

/// The pids of this user's processes called `name`, oldest first.
///
/// By the kernel's own process name, the one `pgrep -x` matches, and not
/// through LaunchServices: a command started over SSH is outside the login
/// session, and LaunchServices has nothing to say to it.
func pids(named name: String) -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var all = [pid_t](repeating: 0, count: Int(count) + 64)
    let filled = proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size))
    let me = getuid()
    var found: [(pid: pid_t, started: UInt64)] = []
    for pid in all.prefix(Int(max(filled, 0))) where pid > 0 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == me else { continue }
        guard processName(pid) == name else { continue }
        found.append((pid, info.pbi_start_tvsec))
    }
    return found.sorted { $0.started < $1.started }.map(\.pid)
}

func processName(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
    guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// The application element of the process called `name`, as System Events'
/// `process NAME` finds it.
func application(_ name: String) -> AXUIElement {
    guard let pid = pids(named: name).first else { refuse("no process called \(name) is running") }
    let app = AXUIElementCreateApplication(pid)
    // The system's own default, said here so that an application that stops
    // answering costs a known time per question.
    AXUIElementSetMessagingTimeout(app, 6)
    return app
}

// MARK: - Attributes, as AppleScript turned them into text

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// The attributes an element lists — the only ones System Events answers.
func listedNames(_ element: AXUIElement) -> Set<String> {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success, let list = names as? [String] else { return [] }
    return Set(list)
}

/// AppleScript's `x as text` for a real: `148.0` for a whole number, twelve
/// significant digits otherwise (`0.136363636364`, measured beside this).
func realText(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e4 { return String(format: "%.1f", value) }
    return String(format: "%.12g", value)
}

/// A value as `(value as text)` gave it in the old walks; a list as each item
/// followed by `;`, which is how `AXPosition` read `790;198;` there.
func text(_ value: AnyObject?) -> String {
    guard let value else { return "" }
    let type = CFGetTypeID(value)
    if type == CFStringGetTypeID() { return value as! String }
    if type == CFAttributedStringGetTypeID() { return (value as! NSAttributedString).string }
    if type == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) ? "true" : "false" }
    if type == CFNumberGetTypeID() {
        let number = value as! NSNumber
        return CFNumberIsFloatType(number) ? realText(number.doubleValue) : String(number.int64Value)
    }
    if type == CFArrayGetTypeID() { return (value as! [AnyObject]).map { text($0) + ";" }.joined() }
    if type == AXValueGetTypeID() {
        let ax = value as! AXValue
        switch AXValueGetType(ax) {
        case .cgPoint:
            var point = CGPoint.zero
            AXValueGetValue(ax, .cgPoint, &point)
            return "\(Int(point.x));\(Int(point.y));"
        case .cgSize:
            var size = CGSize.zero
            AXValueGetValue(ax, .cgSize, &size)
            return "\(Int(size.width));\(Int(size.height));"
        default:
            return "?"
        }
    }
    if type == CFURLGetTypeID() { return (value as! URL).absoluteString }
    // A reference to another element, or anything else AppleScript could not
    // make text of, read "?" in the old walks.
    return "?"
}

func rect(_ position: AnyObject?, _ size: AnyObject?) -> CGRect? {
    guard let position, let size,
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
    return CGRect(origin: point, size: extent)
}

func json(_ rect: CGRect?) -> Any {
    guard let rect else { return NSNull() }
    return [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
}

let walkedAttributes = [
    "AXRole", "AXSubrole", "AXIdentifier", "AXTitle", "AXValue", "AXDescription", "AXPosition", "AXSize", "AXEnabled",
]

struct Described {
    let record: [String: Any]
    let role: String
    let frame: CGRect?
}

/// One element: every attribute in one round trip, then only those it lists.
func describe(_ element: AXUIElement, depth: Int, clip: CGRect) -> Described {
    var values: CFArray?
    var got: [AnyObject?] = Array(repeating: nil, count: walkedAttributes.count)
    let error = AXUIElementCopyMultipleAttributeValues(
        element, walkedAttributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values
    )
    if error == .success, let list = values as? [AnyObject], list.count == walkedAttributes.count {
        for (index, item) in list.enumerated() {
            // An attribute the element does not have comes back as an AXValue holding the error.
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { continue }
            got[index] = item
        }
    } else {
        for (index, name) in walkedAttributes.enumerated() { got[index] = attribute(element, name) }
    }
    let listed = listedNames(element)
    for (index, name) in walkedAttributes.enumerated() where !listed.contains(name) { got[index] = nil }

    let frame = rect(got[6], got[7])
    var record: [String: Any] = [
        "depth": depth,
        "role": text(got[0]),
        "subrole": text(got[1]),
        "identifier": text(got[2]),
        "title": text(got[3]),
        "value": text(got[4]),
        "description": text(got[5]),
        "frame": json(frame),
    ]
    if let enabled = got[8], CFGetTypeID(enabled) == CFBooleanGetTypeID() {
        record["enabled"] = CFBooleanGetValue((enabled as! CFBoolean))
    } else {
        record["enabled"] = NSNull()
    }
    if let frame {
        record["shown"] = clip.contains(CGPoint(x: frame.midX, y: frame.midY))
    } else {
        record["shown"] = false
    }
    return Described(record: record, role: record["role"] as! String, frame: frame)
}

func elements(_ value: AnyObject?) -> [AXUIElement] {
    guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
    return (value as! [AnyObject]).compactMap { item in
        CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
    }
}

func children(_ element: AXUIElement) -> [AXUIElement] { elements(attribute(element, kAXChildrenAttribute)) }

func displayBounds() -> CGRect { CGDisplayBounds(CGMainDisplayID()) }

/// Every element from `root` down, preorder, `root` at depth 0, an element's
/// children listed while its depth is below `maxDepth` (`ui._TREE`'s shape).
/// What a click can reach narrows at the window and at every scroll area.
func walk(_ root: AXUIElement, maxDepth: Int) -> [[String: Any]] {
    var out: [[String: Any]] = []
    func visit(_ element: AXUIElement, _ depth: Int, _ clip: CGRect) {
        let described = describe(element, depth: depth, clip: clip)
        out.append(described.record)
        guard depth < maxDepth else { return }
        var inner = clip
        if let frame = described.frame, depth == 0 || described.role == "AXScrollArea" {
            inner = clip.intersection(frame)
        }
        for child in children(element) { visit(child, depth + 1, inner) }
    }
    visit(root, 0, displayBounds())
    return out
}

// MARK: - Windows and menus

func role(_ element: AXUIElement) -> String { text(attribute(element, kAXRoleAttribute)) }

func windows(of app: AXUIElement) -> [AXUIElement] { elements(attribute(app, kAXWindowsAttribute)) }

func titles(_ windows: [AXUIElement]) -> String {
    let names = windows.map { "'\(text(attribute($0, kAXTitleAttribute)))'" }
    return names.isEmpty ? "none" : names.joined(separator: ", ")
}

/// `first window whose name is TITLE`, or the panel: `first window whose subrole is "AXSystemDialog"`.
func window(_ app: AXUIElement, _ spec: String, process: String) -> AXUIElement {
    let all = windows(of: app)
    if spec == "panel" {
        if let found = all.first(where: { text(attribute($0, kAXSubroleAttribute)) == "AXSystemDialog" }) { return found }
        refuse("\(process) has no window whose subrole is AXSystemDialog (the panel); its windows: \(titles(all))")
    }
    guard spec.hasPrefix("title=") else { refuse("a window is title=<its title> or panel, not \(spec)", code: 2) }
    let title = String(spec.dropFirst("title=".count))
    if let found = all.first(where: { text(attribute($0, kAXTitleAttribute)) == title }) { return found }
    refuse("\(process) has no window called \(title); its windows: \(titles(all))")
}

/// `menu 1 of menu bar item 1 of menu bar 1`: the first child of each kind.
func firstMenu(_ app: AXUIElement, process: String) -> AXUIElement {
    guard let bar = children(app).first(where: { role($0) == "AXMenuBar" }) else { refuse("\(process) has no menu bar") }
    guard let item = children(bar).first(where: { role($0) == "AXMenuBarItem" }) else {
        refuse("\(process)'s menu bar has no item")
    }
    guard let menu = children(item).first(where: { role($0) == "AXMenu" }) else {
        refuse("\(process)'s first menu bar item has no menu")
    }
    return menu
}

func menuItems(_ menu: AXUIElement) -> [AXUIElement] { children(menu).filter { role($0) == "AXMenuItem" } }

func setFrame(_ element: AXUIElement, position: CGPoint?, size: CGSize?) {
    if var point = position {
        let error = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
        guard error == .success else { refuse("moving the window failed: AXError \(error.rawValue)") }
    }
    if var extent = size {
        let error = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &extent)!)
        guard error == .success else { refuse("sizing the window failed: AXError \(error.rawValue)") }
    }
}

func frameOf(_ element: AXUIElement) -> CGRect? { rect(attribute(element, kAXPositionAttribute), attribute(element, kAXSizeAttribute)) }

// MARK: - The display, and events through the window server

/// The main display in points and pixels, and — where the login session can be
/// asked, which a command over SSH cannot — how tall the menu bar is and where
/// the part of the screen windows may use ends above the Dock, from the top.
func mainDisplay() -> [String: Any] {
    let display = CGMainDisplayID()
    let bounds = CGDisplayBounds(display)
    var record: [String: Any] = [
        "points": [Double(bounds.width), Double(bounds.height)],
        "pixels": [CGDisplayPixelsWide(display), CGDisplayPixelsHigh(display)],
    ]
    if let screen = NSScreen.screens.first {
        let frame = screen.frame
        let visible = screen.visibleFrame
        record["menuBar"] = Double(frame.maxY - visible.maxY)
        record["visibleBottom"] = Double(frame.maxY - visible.minY)
    }
    return record
}

func number(_ text: String, _ what: String) -> Double {
    guard let value = Double(text), value.isFinite else { refuse("\(what) is not a number: \(text)", code: 2) }
    return value
}

let source = CGEventSource(stateID: .hidSystemState)

func pause(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }

func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clicks: Int64 = 0) {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
        refuse("the window server would not make a mouse event")
    }
    if clicks > 0 { event.setIntegerValueField(.mouseEventClickState, value: clicks) }
    event.post(tap: .cghidEventTap)
}

func pointerLocation() -> CGPoint {
    guard let event = CGEvent(source: nil) else { refuse("the window server would not say where the pointer is") }
    return event.location
}

func isDown(_ button: CGMouseButton) -> Bool {
    CGEventSource.buttonState(.hidSystemState, button: button) || CGEventSource.buttonState(.combinedSessionState, button: button)
}

/// Every button the system still takes for held down, let go of — and which.
///
/// Measured on a runner (run 38227384436): after one click the system went on
/// taking the left button for held, and uDeck's gesture said `idle: buttonDown`
/// to every move after it, in every check that came next. No check of the lab
/// ever holds a button, so one held before an action is a release that went
/// missing, and it is made here, said in the answer.
func releaseHeldButtons() -> [String] {
    var released: [String] = []
    for (button, up, name) in [(CGMouseButton.left, CGEventType.leftMouseUp, "left"), (.right, .rightMouseUp, "right")]
    where isDown(button) {
        post(up, at: pointerLocation(), button: button, clicks: 1)
        pause(0.05)
        released.append(name)
    }
    return released
}

/// A click, and its release made sure of: an up the system did not take is posted again.
func click(at point: CGPoint, right: Bool) -> Int {
    let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
        right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
    post(.mouseMoved, at: point, button: button)
    pause(0.05)
    post(down, at: point, button: button, clicks: 1)
    pause(0.05)
    post(up, at: point, button: button, clicks: 1)
    var again = 0
    while again < 3 {
        pause(0.05)
        guard isDown(button) else { break }
        post(up, at: point, button: button, clicks: 1)
        again += 1
    }
    return again
}

/// Virtual key codes of the US layout, by the names vncdotool gives keys —
/// the names `Machine.key` is called with in the checks.
let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
    "n": 45, "m": 46, "return": 36, "enter": 36, "tab": 48, "space": 49, "bsp": 51, "esc": 53,
    "del": 117, "left": 123, "right": 124, "down": 125, "up": 126,
]

/// The modifiers the system takes for held, by name.
func heldModifiers() -> [String] {
    let flags = CGEventSource.flagsState(.hidSystemState).union(CGEventSource.flagsState(.combinedSessionState))
    let names: [(CGEventFlags, String)] = [
        (.maskControl, "control"), (.maskAlternate, "option"), (.maskShift, "shift"), (.maskCommand, "command"),
    ]
    return names.filter { flags.contains($0.0) }.map(\.1)
}

/// One key, down and up, and nothing held with it.
///
/// The key a VNC client sends is that key and no other: so is this one. An
/// event made from the system's own state carries whatever modifiers the
/// system takes for held, and a key pressed with Control still held from a
/// chord before it is a different key — `a` arrives as ⌃A, which types nothing
/// (a key into TextEdit that left it empty, on a runner, runs 38215534337 to
/// 38231377880). So the event comes from a source of its own and says outright
/// that no modifier is held.
func press(key name: String) {
    guard let code = keyCodes[name] else { refuse("no key called \(name)", code: 2) }
    let own = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: own, virtualKey: code, keyDown: down) else {
            refuse("the window server would not make a key event")
        }
        event.flags = []
        event.post(tap: .cghidEventTap)
        pause(0.03)
    }
}

// MARK: - Commands

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { refuse("usage: ax <command> …; the commands are at the top of ax.swift", code: 2) }
arguments.removeFirst()

func argument(_ index: Int, _ what: String) -> String {
    guard index < arguments.count else { refuse("\(command) needs \(what)", code: 2) }
    return arguments[index]
}

func point(from index: Int) -> CGPoint {
    CGPoint(x: number(argument(index, "x"), "x"), y: number(argument(index + 1, "y"), "y"))
}

let started = Date()
func took() -> Double { (Date().timeIntervalSince(started) * 1000).rounded() / 1000 }

switch command {
case "trusted":
    emit(["trusted": AXIsProcessTrusted()])

case "windows":
    let process = argument(0, "a process name")
    let found = windows(of: application(process)).map { window -> [String: Any] in
        [
            "title": text(attribute(window, kAXTitleAttribute)),
            "subrole": text(attribute(window, kAXSubroleAttribute)),
            "frame": json(frameOf(window)),
        ]
    }
    emit(["windows": found, "seconds": took()])

case "walk":
    let process = argument(0, "a process name")
    let spec = argument(1, "a window: title=<its title> or panel")
    let depth = Int(number(argument(2, "a depth"), "the depth"))
    let root = window(application(process), spec, process: process)
    emit(["elements": walk(root, maxDepth: depth), "seconds": took()])

case "menu":
    let process = argument(0, "a process name")
    let menu = firstMenu(application(process), process: process)
    emit(["titles": menuItems(menu).map { text(attribute($0, kAXTitleAttribute)) }, "seconds": took()])

case "press-menu-item":
    let process = argument(0, "a process name")
    let title = argument(1, "the item's title")
    let items = menuItems(firstMenu(application(process), process: process))
    guard let item = items.first(where: { text(attribute($0, kAXTitleAttribute)) == title }) else {
        refuse("\(process)'s menu has no item called \(title); it has \(items.map { text(attribute($0, kAXTitleAttribute)) })")
    }
    // An accessibility action, as System Events' `click menu item` was: the
    // menu's item is what uDeck offers and has no place on the screen to point at.
    let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
    guard error == .success else { refuse("pressing \(title) failed: AXError \(error.rawValue)") }
    emit(["pressed": title, "seconds": took()])

case "place":
    let process = argument(0, "a process name")
    let spec = argument(1, "a window: title=<its title> or panel")
    let numbers = (2...5).map { number(argument($0, "x, y, width and height"), "the frame") }
    let target = window(application(process), spec, process: process)
    // Position, then size: the order the old AppleScript set them in.
    setFrame(target, position: CGPoint(x: numbers[0], y: numbers[1]), size: CGSize(width: numbers[2], height: numbers[3]))
    emit(["frame": json(frameOf(target)), "seconds": took()])

case "move-window":
    let process = argument(0, "a process name")
    let to = point(from: 1)
    guard let first = windows(of: application(process)).first else { refuse("\(process) has no window") }
    setFrame(first, position: to, size: nil)
    emit(["frame": json(frameOf(first)), "seconds": took()])

case "text":
    // `value of text area 1 of scroll area 1 of window 1`, the first of each kind.
    let process = argument(0, "a process name")
    guard let first = windows(of: application(process)).first else { refuse("\(process) has no window") }
    guard let scroll = children(first).first(where: { role($0) == "AXScrollArea" }) else {
        refuse("\(process)'s front window has no scroll area")
    }
    guard let area = children(scroll).first(where: { role($0) == "AXTextArea" }) else {
        refuse("\(process)'s front window has no text area")
    }
    emit(["text": text(attribute(area, kAXValueAttribute)), "seconds": took()])

case "focused":
    let app = application(argument(0, "a process name"))
    func title(_ value: AnyObject?) -> Any {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return NSNull() }
        return text(attribute(value as! AXUIElement, kAXTitleAttribute))
    }
    emit(["focused": title(attribute(app, kAXFocusedWindowAttribute)), "main": title(attribute(app, kAXMainWindowAttribute)),
          "frontmost": text(attribute(app, kAXFrontmostAttribute)), "seconds": took()])

case "screen":
    emit(mainDisplay())

case "set-mode":
    let width = Int(number(argument(0, "a width in pixels"), "the width"))
    let height = Int(number(argument(1, "a height in pixels"), "the height"))
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    let modes = (CGDisplayCopyAllDisplayModes(CGMainDisplayID(), options) as? [CGDisplayMode]) ?? []
    let fitting = modes.filter { $0.pixelWidth == width && $0.pixelHeight == height && $0.isUsableForDesktopGUI() }
    // At 1×, where points and pixels agree, as on the lab's own screen.
    guard let mode = fitting.first(where: { $0.width == width }) ?? fitting.first else {
        let sizes = modes.filter { $0.isUsableForDesktopGUI() }.map { "\($0.pixelWidth)×\($0.pixelHeight)" }
        refuse("the main display has no mode of \(width)×\(height) pixels; it has \(sizes.joined(separator: ", "))")
    }
    // For the login session, not for this process: a mode set with
    // CGDisplaySetDisplayMode went back the moment the process that set it
    // exited (measured on a runner, run 38209960064).
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else { refuse("the display would not be configured") }
    let error = CGConfigureDisplayWithDisplayMode(config, CGMainDisplayID(), mode, nil)
    guard error == .success else {
        CGCancelDisplayConfiguration(config)
        refuse("switching the display failed: CGError \(error.rawValue)")
    }
    let completed = CGCompleteDisplayConfiguration(config, .forSession)
    guard completed == .success else { refuse("switching the display failed: CGError \(completed.rawValue)") }
    pause(1)
    emit(mainDisplay())

case "pointer":
    let at = pointerLocation()
    emit(["x": Double(at.x), "y": Double(at.y), "held": ["left", "right"].filter { isDown($0 == "left" ? .left : .right) }])

case "move":
    let at = point(from: 0)
    let released = releaseHeldButtons()
    post(.mouseMoved, at: at, button: .left)
    emit(["moved": [Double(at.x), Double(at.y)], "released": released])

case "click", "right-click":
    let at = point(from: 0)
    let released = releaseHeldButtons()
    let again = click(at: at, right: command == "right-click")
    emit(["clicked": [Double(at.x), Double(at.y)], "button": command == "click" ? "left" : "right",
          "released": released, "released again": again])

case "key":
    let name = argument(0, "a key's name")
    let released = releaseHeldButtons()
    let held = heldModifiers()
    press(key: name)
    emit(["pressed": name, "released": released, "modifiers held": held])

case "scroll":
    // Pixels, as a trackpad scrolls: positive moves the content down, which is
    // scrolling up, the window server's own sign.
    let at = point(from: 0)
    let delta = Int32(number(argument(2, "how far"), "the distance"))
    let released = releaseHeldButtons()
    post(.mouseMoved, at: at, button: .left)
    pause(0.05)
    guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else {
        refuse("the window server would not make a scroll event")
    }
    event.location = at
    event.post(tap: .cghidEventTap)
    pause(0.3)
    emit(["scrolled": Int(delta), "at": [Double(at.x), Double(at.y)], "released": released])

default:
    refuse("no command called \(command); the commands are at the top of ax.swift", code: 2)
}
