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

**Can the islands on non-active screens stop being dimmed?** AppKit dims a
system material in a window that is not key, and only one window of an
application can be key at a time — there is one island per screen. The panel's
own island is fine, because the panel window takes key status; the others are
separate windows and cannot all have it.

The route previously planned for this does not exist. `NSGlassEffectView` has a
private `_subduedState`, and a previous session concluded it was what AppKit set
on a key change. Logged from inside the running application it reads 0 at every
call, including while the island is visibly dimmed, and re-asserting it — with
or without forcing a redraw afterwards — moved nothing measurable. A later
session extended that to the other two private integers the class carries,
`_scrimState` and `_interactionState`, and to the whole layer tree: all three
read 0 in both states, and the layers are identical — same opacities, no
filters, no compositing filter, every superview at alpha 1. Dimming
tracks key state and nothing else: 194.8/255 with it, 184.2 without, measured
over the desktop with Finder frontmost, alternating builds twice each.

**This has probably been answered since, as a side effect.** The idea below —
stop using the system material and draw the island ourselves — has been
implemented, for a different reason: the panel used to take the key window back
on every application switch to stay bright, and that made uDeck reach for focus
the operator had not given it. An inactive uDeck now draws
`SteadyGlassBackground` (`NSVisualEffectView` pinned to `state = .active`),
which does not dim, and the material follows *application* activation rather
than window key state — so an island on a screen the panel is not on should no
longer be a special case at all. Nobody has looked at a second screen since.

Also worth recording, because it changes what the paragraph above assumes:
`isKeyWindow` stays **true** with another application verifiably frontmost. The
panel is non-activating and does not hide on deactivate, and key status is per
application. The signal that tracks the dimming is `NSApp.isActive`.

The idea that had not been tried, and now has: stop using the system material
for those islands and draw them ourselves, matched to the undimmed appearance.
An island is 185×32 points with one indicator bar on it, so there may be nothing
in it a hand-drawn fill cannot carry.

*To settle:* measure the real gap first. Put a striped backdrop on the second
display, another application frontmost, and compare an island there against the
one on the active screen. If the difference is small, this is not worth code; if
it is the ~11 points the panel used to show, draw those islands directly and
compare again. The operator's own reading is that it does not currently bother
him, so the bar for changing shared drawing code here is high — that path is the
one this session watched two confident changes fail in.


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

Half of it was measured on 2026-09-27, in the lab, with a build that logged
every movement it handled near the top of the screen
(`.build/e2e/kept/20260927-154333Z`): the position read now and the event's own
location were the same in 39 movements of 39, so reading it now is not where a
mismatch comes from there. One comes from somewhere else. macOS hands some
reports to uDeck twice — through its global monitor and through its local one —
with the movement halved between the two copies and both placed where the whole
report left the pointer. Read against `PointerDeltaCalibration.observe` — not
measured as learning — the first copy pairs a whole report's change of position
with half its delta, a scale twice the true one, which is inside the accepted
range and so learned from; the second changes no position and is ignored. The gesture itself reads the two copies as one report
(`HoverGestureRecognizer.wasPinned`); the calibration does not yet.
*To settle:* count rejections in the field. A high rate means the pairing is
wrong and the filter is merely hiding it. And count the reports that come in two
copies: pairing a report's change of position with the sum of its copies is the
fix, if they turn out to be common on a real mouse.

**Where was the pointer when the click the news is about went down?** When the
workspace says another application came forward, uDeck decides whether that was
a click past the panel partly from where the pointer is *now*
(`PanelController.pointerIsPastThePanel`), because the news carries no click and
no place. With the time window gone the news can come late — 2 to 232 ms after
the button in the runs kept so far — and a pointer that crossed the edge of the
region that keeps the panel in that time is read on the wrong side of it. Moved
back onto the panel, a click past it reads as a switch and the panel comes back
whole; moved past it after a click in the margin that brought another
application forward, the margin click reads as a dismissal and the work is
thrown away. The global monitor, which does have the click, now decides from the
click's own location; the two were the same in all six clicks past uDeck logged
on 2026-09-27, with the pointer standing still. Not measured with a pointer in
motion. The position at the click is not simple to have at the news: the
movement uDeck is handed arrives by the same road as the click, which is the
road that loses the race.
*To settle:* a probe that clicks and moves on within a few milliseconds, many
times, logging where the pointer was at the click and at the news.

**Should a click on uDeck's own item in the menu bar put a held panel away?** It
does, and by the rule as written: the item is past the panel, the global monitor
hears the click (it is delivered to another process), and the workspace says
another application came forward 2 to 3 ms after it — the Finder, the one time
the build logged the name — so the panel closes as
dismissed before the menu has opened, 2 times of 2 on 2026-09-27
(.build/e2e/kept/20260927-193950Z and -194310Z, probe.status-menu-1 and -2). The
operator reaching for uDeck's own menu may not mean "put it away".
*To settle:* ask him.

**Does a picker in the settings window let go the way a context menu does?**
uDeck counts a click inside any of its menus as heard when the menu lets go on
it (`NSMenu.didEndTrackingNotification`), and that was measured for a tab's
context menu only — four choices, each letting go on the choosing click. A
picker is an `NSPopUpButton` over the same `NSMenu`, and the settings window
closes the panel when it opens, so the case needs the panel revealed again
over the window. Not measured.
*To settle:* reveal the panel with the settings window open, choose in a
picker, switch with no click, and read the verdict line.

**Can a report handled late read the pointer ahead of itself, as a timer did?**
The gesture's samples take their position from `NSEvent.mouseLocation` when
they are handled, the reports' as much as the timers'. A timer asking in the gap
between the window server moving the pointer and uDeck being handed the report
was measured, and fixed (`HoverGestureRecognizer.notePinned`): 20 pushes in 120
arrivals, all 20 behind such a question. A report handled after the *next* one
has already moved the pointer would read that position with a movement of its
own, and nothing stops it being taken as "already pinned". On an idle guest the
position read and the event's own location were the same in 39 movements of 39
(.build/e2e/kept/20260927-154333Z). Not measured under load.
*To settle:* log each report's own location beside `NSEvent.mouseLocation` in a
whole lab run at `--jobs 2`, and count the reports near the top where they differ.

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
wrong: measured with a maximised terminal window frontmost, its frame is
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
