# Open questions

Things nobody has settled. They are not known bugs — they are places where the
code does something on a reasonable assumption that has not been checked, and
where the way to check it is written down so the next person does not have to
work it out.

Kept because an unexamined assumption that everyone has forgotten about is
indistinguishable from a bug that has not happened yet.

---

## Settled

**Where does the cursor sit when it is pushed against the top of the screen?**
On `frame.maxY` exactly — not on `maxY - 1`, which three places in the code
assumed. Measured: `CGWarpMouseCursorPosition` to the top of the display leaves
`NSEvent.mouseLocation` reporting `1440.0` on a 1440-point-tall screen, and the
running app logged `idle: outsideStrip` there while opening normally one point
below. The trigger strip and the keep-alive region are flush with that edge, so
both now use `PanelGeometry.containsPointer`, which includes the top row.
Whether a *physical* mouse can also reach that row was never established — two
45-second recordings caught no sample near the top — but it no longer has a
consequence, because both rows now behave the same.

**Does a focused SwiftUI text field still reach the panel as `NSText`?**
Yes, on macOS 26.6. The rule that Escape must give up a field before it gives up
the panel is implemented through `panel.firstResponder as? NSText`, and SwiftUI
has been migrating text to its own implementation — if that cast ever fails, the
rule inverts and Escape starts discarding typed text instead of protecting it.
Verified live: with text in a field, the panel logged
`escape(isEditingText: true) ignored in open` and stayed open; the next Escape
closed it. The cast is also logged when it fails, and the first-responder type
is in the diagnostics, so a future regression says so rather than going quiet.

**Can a producer's end-of-file count go wrong across two pipes?** No longer
possible: end of file is recorded per pipe rather than counted down.

---

## Open

**Does macOS still let uDeck restore the previously frontmost application?**
When the panel has taken the keyboard by activating uDeck, closing it calls
`activate()` on whatever was in front before. Cooperative activation on recent
macOS may refuse that from an application that is no longer frontmost — in which
case the restore path has never actually run and the behaviour around it is
untested rather than correct. On this machine the panel takes the keyboard
*without* activating, so the path is not reached at all.
*To settle:* open the panel from a terminal, click in it, ⌘-Tab to another
application, and watch what comes forward.

**Is the pointer calibration being fed matched pairs?** The position comes from
`NSEvent.mouseLocation` read now, while the delta comes from the event being
handled. Under load or event coalescing those describe different movements, and
the calibration would be learning from a mismatch. Implausible ratios are
rejected, so the effect is absorbed rather than acted on — but absorbing a lot
of garbage is not the same as not being fed any.
*To settle:* count rejections in the field. A high rate means the pairing is
wrong and the filter is merely hiding it.

**Can a run that did not overrun be reported as one?** The watchdog records a
timeout before killing, and cancelling it cannot stop a body already past its
cancellation check — so a producer finishing within a millisecond of its
deadline could be labelled as having overrun. Lower stakes since a timed-out run
now returns its card as well, but still there.
*To settle:* `-sanitize=thread`, with a producer exiting right on its deadline,
a few thousand times.

**Does `DistributedNotificationCenter` honour the queue it is given?** The
menu-tracking observers assume delivery on the main queue, and
`MainActor.assumeIsolated` traps if that is wrong. It would fire only when a
system menu opens.
*To settle:* assert `Thread.isMainThread` in that observer and open a menu.

**Is the fullscreen gate ever reached on this machine?** Not so far. It was
assumed to be why the gesture stopped responding at one point, and that was
wrong: measured while Warp was frontmost, its window is
`(244, 0, 2316x1410)` against a screen frame of `(0, 0, 2560x1440)`. That is a
maximised window, and `FullscreenDetector` correctly declines to call it
fullscreen — the test is an exact match against the whole screen frame. The gate
is real and still worth having, but nothing here has exercised it.
*To settle:* put an application into true fullscreen and read the log.

**Has any of the geometry run against real hardware in anger?** The screen
geometry is tested against fabricated snapshots of two real displays, and the
panel has been driven by a second process on those two displays. Nothing has
been tried against a display waking from sleep, a monitor being unplugged while
the panel is open, or a third display — and the README names this as the area
most likely to break with a macOS release.
*To settle:* use it for a week, undocked and docked.
