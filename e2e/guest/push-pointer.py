#!/usr/bin/env python3
"""Push the pointer upward from inside the guest, the way a hand pushes a mouse.

This runs *in the machine*, not on this Mac, and it exists because the other
half of uDeck's hover gesture is not a position.

uDeck's two paths are driven by different input. The dwell only needs the
pointer to be inside the strip at the top of the screen and to stay there, which
a VNC client can do by putting it there. The push needs *movement reported while
the pointer is already pinned against the edge* — and at the edge the position
stops changing, so nothing that names a position can say it.

Posting the movement as a `CGEvent` delta does not work, and the reason is worth
keeping: the window server tells applications the movement that actually
happened, which against the edge is nothing (measured 2026-09-18, fifteen shapes
of push on four machines — five events carrying ±30 points at y=400 left the
pointer at exactly (1280, 400)).

So the movement is posted one layer lower, through `IOHIDPostEvent` on
`IOHIDSystem`'s parameter connection — the same entry point a mouse driver
posts through. macOS moves the pointer itself and tells applications the
movement, exactly as it does for a real mouse: against the edge the position
clamps and the delta keeps coming, which is the signal this path is made of.

Two things about that call, both measured in a clone on 2026-09-19:

* **It must not be run under `sudo`.** The refusal the lab recorded in September
  as "refused even as root" was *caused* by root:
  `IOHIDParamUserClient::extPostEvent` asks
  `clientHasPrivilege(current_task(), kIOClientPrivilegeLocalUser)`, which XNU
  answers with `CopyConsoleUser(euid)`, and root holds no console session. As
  the logged-in user it returns `KERN_SUCCESS` and the pointer moves; under
  `sudo` it returns `kIOReturnNotPrivileged` and nothing moves.
* **`options` is 0.** `kIOHIDPostHIDManagerEvent` (0x8) aims at a branch that
  drives the kernel's own virtual mouse, but with it the pointer moved exactly as
  it did with 0 and `ioreg` named no "Virtual Mouse", so the flag did not reach
  that branch. What is used is the relative pointer path, which is enough: it is
  what a real device drives.

The throw and the push are one run, milliseconds apart, and that is not an
implementation detail: the dwell fires a fraction of a second after the pointer
stops in the strip, so a pointer left at the edge while an SSH command is sent
would open the panel by the path this is not about.

No PyObjC: the guest has the system's Python 3.9, which has none, so the calls
are made through ctypes.

    push-pointer.py <throw-steps> <throw-delta> <throw-pause> <steps> <delta> <pause>

A negative delta is upward. `throw-steps` may be 0, which is what the control in
the middle of the screen uses: it pushes where the pointer already is, and a
throw would carry it somewhere else.
"""

import ctypes
import json
import sys
import time

IOKIT = "/System/Library/Frameworks/IOKit.framework/IOKit"

# IOKit/hidsystem/IOLLEvent.h
NX_MOUSEMOVED = 5
NX_EVENT_DATA_VERSION = 2
# IOKit/hidsystem/IOHIDShared.h: the connection that takes posted events.
KIO_HID_PARAM_CONNECT_TYPE = 1
# NXEventData is smaller than this. A zeroed over-allocation is safe to hand
# over: IOHIDPostEvent copies sizeof(NXEventData) out of it and never reads past
# that, and writing the size in here would be guessing at a private layout.
NX_EVENT_DATA_BYTES = 256

# IOKit/IOReturn.h, where iokit_common_err(x) is 0xE0000000 | x. Only the ones a
# run can actually end on are named; anything else is printed as its number,
# which is more useful than a wrong name.
RETURNS = {
    0x00000000: "KERN_SUCCESS",
    0xE00002BC: "kIOReturnError",
    0xE00002C0: "kIOReturnNoDevice",
    0xE00002C1: "kIOReturnNotPrivileged",
    0xE00002C2: "kIOReturnBadArgument",
    0xE00002C7: "kIOReturnUnsupported",
    0xE00002CD: "kIOReturnNotOpen",
    0xE00002E2: "kIOReturnNotPermitted",
}


class IOGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_int16), ("y", ctypes.c_int16)]


def named(code):
    """What the kernel answered, by name where there is one."""
    code &= 0xFFFFFFFF
    return RETURNS.get(code, "0x%08x" % code)


def iokit():
    """IOKit, with every call this uses given its exact shape.

    ctypes guesses otherwise, and a guessed argument list on a call that takes a
    struct by value goes wrong silently rather than loudly.
    """
    library = ctypes.CDLL(IOKIT)
    library.IOServiceMatching.argtypes = [ctypes.c_char_p]
    library.IOServiceMatching.restype = ctypes.c_void_p
    library.IOServiceGetMatchingService.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    library.IOServiceGetMatchingService.restype = ctypes.c_uint32
    library.IOServiceOpen.argtypes = [
        ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)
    ]
    library.IOServiceOpen.restype = ctypes.c_int32
    library.IOServiceClose.argtypes = [ctypes.c_uint32]
    library.IOServiceClose.restype = ctypes.c_int32
    library.IOObjectRelease.argtypes = [ctypes.c_uint32]
    library.IOObjectRelease.restype = ctypes.c_int32
    library.IOHIDPostEvent.argtypes = [
        ctypes.c_uint32,   # io_connect_t  connect
        ctypes.c_uint32,   # UInt32        eventType
        IOGPoint,          # IOGPoint      location, by value
        ctypes.c_void_p,   # const NXEventData *
        ctypes.c_uint32,   # UInt32        eventDataVersion
        ctypes.c_uint32,   # IOOptionBits  eventFlags
        ctypes.c_uint32,   # IOOptionBits  options
    ]
    library.IOHIDPostEvent.restype = ctypes.c_int32
    return library


def post(library, connect, delta):
    """One report of relative movement: nothing sideways, `delta` vertically.

    The location is not used by this path — the movement is what is being
    reported, and macOS decides where that leaves the pointer, including
    refusing to move it past an edge. `dx` and `dy` are the first two `SInt32`
    fields of the `mouseMove` arm of `NXEventData` (IOLLEvent.h).
    """
    data = (ctypes.c_uint8 * NX_EVENT_DATA_BYTES)()
    ctypes.memset(data, 0, NX_EVENT_DATA_BYTES)
    movement = ctypes.cast(data, ctypes.POINTER(ctypes.c_int32))
    movement[0] = 0
    movement[1] = delta
    return library.IOHIDPostEvent(
        connect,
        NX_MOUSEMOVED,
        IOGPoint(0, 0),
        ctypes.cast(data, ctypes.c_void_p),
        NX_EVENT_DATA_VERSION,
        0,
        0,
    )


def main(argv):
    if len(argv) != 7:
        print(usage(), file=sys.stderr)
        return 2
    throw_steps, throw_delta, throw_pause = int(argv[1]), whole(argv[2]), float(argv[3])
    steps, delta, pause = int(argv[4]), whole(argv[5]), float(argv[6])

    library = iokit()
    system = ctypes.CDLL(None)
    said = {"uid": system.getuid(), "euid": system.geteuid(), "throw": [], "push": []}
    if said["euid"] == 0:
        # Said rather than refused: the run is the measurement, and a refusal
        # here would hide the kernel's own answer from whoever reads the report.
        said["warning"] = "running as root, which has no console session; the kernel refuses these"

    service = library.IOServiceGetMatchingService(0, library.IOServiceMatching(b"IOHIDSystem"))
    if not service:
        said["error"] = "there is no IOHIDSystem in this machine to post through"
        print(json.dumps(said))
        return 1
    connect = ctypes.c_uint32(0)
    # mach_task_self() is a macro over this, and ctypes has no macros.
    task = ctypes.c_uint.in_dll(system, "mach_task_self_").value
    opened = library.IOServiceOpen(service, task, KIO_HID_PARAM_CONNECT_TYPE, ctypes.byref(connect))
    library.IOObjectRelease(service)
    said["open"] = named(opened)
    if opened != 0:
        print(json.dumps(said))
        return 1

    try:
        # The throw: enough upward movement to cross the screen and be held at the
        # top. uDeck does not count the movement that *arrives* at the edge — the
        # throw is not a push, and counting it would fire the gesture on any fast
        # flick at the menu bar — so the throw ends where the push begins.
        for _ in range(throw_steps):
            said["throw"].append(named(post(library, connect.value, throw_delta)))
            time.sleep(throw_pause)
        # The push: movement reported while the pointer can go no higher.
        for _ in range(steps):
            said["push"].append(named(post(library, connect.value, delta)))
            time.sleep(pause)
    finally:
        library.IOServiceClose(connect.value)

    # One line per distinct answer, not per report: fifteen identical successes
    # say nothing more than one, and a single refusal among them must not be lost
    # in the noise.
    said["throw"] = sorted(set(said["throw"]))
    said["push"] = sorted(set(said["push"]))
    print(json.dumps(said))
    return 0 if said["push"] == ["KERN_SUCCESS"] else 1


def usage():
    """The one line of the docstring that says how this is called.

    Found rather than counted from the end: the paragraphs around it are
    edited, and a line number into a docstring goes wrong silently.
    """
    return next(line.strip() for line in __doc__.splitlines() if line.strip().startswith("push-pointer.py"))


def whole(text):
    """A delta as a whole number of points: a HID report carries no fractions."""
    return int(round(float(text)))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
