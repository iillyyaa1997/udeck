#!/usr/bin/env python3
"""Push the pointer upward from inside the guest, the way a hand pushes a mouse.

This runs *in the machine*, not on this Mac, and it exists because the other
half of uDeck's hover gesture cannot be produced from outside it.

uDeck's two paths are driven by different input. The dwell only needs the
pointer to be inside the strip at the top of the screen and to stay there, which
a VNC client can do by putting it there. The push needs *movement reported while
the pointer is already pinned against the edge* — and at the edge the position
stops changing, so the only thing that still carries the movement is the event's
own delta field. A VNC client moves the pointer by naming where it should be, so
it cannot say "and it kept pushing": the push has to be posted as an event.

So: `kCGEventMouseMoved` at the place the pointer already is, carrying an
explicit `kCGMouseEventDeltaY`. AppKit reports that field flipped — a movement
that raises the pointer on screen comes through as a *negative* deltaY — which
is why an upward push is posted as a negative number. uDeck does not trust that
convention either (it measures the polarity from movements where the pointer was
free), so a run where this fires nothing is worth reading the polarity for
rather than flipping the sign here until it works.

No PyObjC: the guest has the system's own Python 3.9, which has none, so the
three calls are made through ctypes.

The arrival is posted here too, and that is not an implementation detail: the
dwell path fires a fraction of a second after the pointer stops in the strip, so
a pointer put at the edge from the other side of an SSH connection would have
opened the panel by the dwell long before a push could be sent. Arriving and
pushing in one run, milliseconds apart, is what makes this check about the push.

    push-pointer.py <x> <y> <steps> <delta> <pause-seconds>
"""

import ctypes
import sys
import time

# ApplicationServices carries CoreGraphics' event API; CoreFoundation has the
# release. Both are in the shared cache, so this costs nothing to load.
APPLICATION_SERVICES = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
CORE_FOUNDATION = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"

KCG_EVENT_MOUSE_MOVED = 5
KCG_MOUSE_EVENT_DELTA_X = 96
KCG_MOUSE_EVENT_DELTA_Y = 97
KCG_HID_EVENT_TAP = 0


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


def main(argv):
    if len(argv) != 6:
        print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
        return 2
    x, y = float(argv[1]), float(argv[2])
    steps, delta, pause = int(argv[3]), float(argv[4]), float(argv[5])

    services = ctypes.CDLL(APPLICATION_SERVICES)
    core = ctypes.CDLL(CORE_FOUNDATION)
    services.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
    services.CGEventCreateMouseEvent.restype = ctypes.c_void_p
    services.CGEventSetDoubleValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_double]
    services.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    core.CFRelease.argtypes = [ctypes.c_void_p]

    # The arrival carries no delta of its own. uDeck counts upward movement only
    # while the pointer was *already* against the edge — the throw that gets it
    # there is not a push, and would make the gesture fire on any fast flick at
    # a menu — so this event exists to put the pointer there and to be the
    # "already" the next ones are measured against.
    for step in range(steps + 1):
        event = services.CGEventCreateMouseEvent(None, KCG_EVENT_MOUSE_MOVED, CGPoint(x, y), 0)
        if not event:
            print("CGEventCreateMouseEvent returned nothing", file=sys.stderr)
            return 1
        # Where it is does not change — it is against the edge. What changed is
        # how far the device was pushed, and that is the whole signal.
        services.CGEventSetDoubleValueField(event, KCG_MOUSE_EVENT_DELTA_X, 0.0)
        services.CGEventSetDoubleValueField(event, KCG_MOUSE_EVENT_DELTA_Y, 0.0 if step == 0 else delta)
        services.CGEventPost(KCG_HID_EVENT_TAP, event)
        core.CFRelease(event)
        time.sleep(pause)
    print(f"arrived and pushed {steps}×{delta} at ({x:.0f}, {y:.0f})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
