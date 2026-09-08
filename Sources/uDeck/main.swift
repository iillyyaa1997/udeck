import AppKit

// An accessory application: present, but not in the Dock and not in the window
// cycler. The panel is a floating panel rather than a window, so there is
// nothing here for either to show.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
