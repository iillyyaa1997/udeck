import AppKit
import SwiftUI

/// The panel's content view, which answers the first click.
///
/// By default a click on a window that is not key is spent making it key and
/// never reaches the view under the pointer. For an ordinary document window
/// that is right — you focus it, then you work in it. For a panel that appeared
/// because the cursor arrived at the top of the screen it is exactly wrong: the
/// operator moved to it and clicked in one motion, and the click they aimed at
/// a card went nowhere. They clicked again, and told me it takes two clicks to
/// open.
///
/// A peek never takes the keyboard — that is what makes it a glance rather than
/// a working panel — so it is never key when the first click lands.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
