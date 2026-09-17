"""One VNC action on a machine's screen, in a process of its own.

    python -m udeck_e2e.vnc_client move X Y
    python -m udeck_e2e.vnc_client click X Y
    python -m udeck_e2e.vnc_client capture PATH

Started by `udeck_e2e.vnc`, never by a person: the server, the password and the
deadline arrive in the environment. A capture prints what it saved as one JSON
object — width, height, and how much of the frame one colour covers. Exit 0 when
the action was done, 1 when it could not be, with the reason as the last line
on stderr, and 2 when the client was started wrongly.
"""

from __future__ import annotations

import json
import os
import sys
import warnings
from pathlib import Path

from udeck_e2e.vnc import PASSWORD_VARIABLE, SECONDS_VARIABLE, SERVER_VARIABLE

USAGE = "usage: python -m udeck_e2e.vnc_client move X Y | click X Y | capture PATH (run by the lab)"

# A frame is measured on a small copy of itself: the question is only whether
# anything is drawn, and 640×360 answers it in milliseconds.
SAMPLE = (640, 360)

# A disconnect waits on its own; it must not double the client's deadline.
DISCONNECT_SECONDS = 5.0


def frame_of(path: Path) -> dict[str, object]:
    from PIL import Image

    with Image.open(path) as image:
        small = image.convert("RGB").resize(SAMPLE)
        pixels = SAMPLE[0] * SAMPLE[1]
        colours = small.getcolors(maxcolors=pixels) or [(pixels, (0, 0, 0))]
        return {
            "width": image.width,
            "height": image.height,
            "uniform": round(max(count for count, _ in colours) / pixels, 4),
        }


def parse_action(args: list[str]) -> tuple[str, list[str]] | None:
    if len(args) == 3 and args[0] in ("move", "click") and all(a.isdigit() for a in args[1:]):
        return args[0], args[1:]
    if len(args) == 2 and args[0] == "capture" and args[1]:
        return "capture", args[1:]
    return None


def main(argv: list[str] | None = None) -> int:
    action = parse_action(sys.argv[1:] if argv is None else argv)
    server = os.environ.get(SERVER_VARIABLE)
    password = os.environ.get(PASSWORD_VARIABLE)
    try:
        seconds = float(os.environ.get(SECONDS_VARIABLE, "20"))
    except ValueError:
        seconds = -1.0
    if action is None or not server or password is None or seconds <= 0:
        print(USAGE, file=sys.stderr)
        return 2

    # vncdotool reaches for a cipher `cryptography` marks deprecated. That
    # warning would become the last line of stderr, where the lab looks for a reason.
    warnings.filterwarnings("ignore", module=r"vncdotool(\.|$)")
    from vncdotool import api

    kind, values = action
    client = None
    code = 0
    try:
        client = api.connect(server, password=password, timeout=seconds)
        if kind == "move":
            client.mouseMove(int(values[0]), int(values[1]))
        elif kind == "click":
            # Where a person would click: the pointer goes there, then the button
            # goes down and up through the machine's own pointing device.
            client.mouseMove(int(values[0]), int(values[1]))
            client.mousePress(1)
        else:
            # The one full frame this connection gets; see udeck_e2e.vnc.
            client.captureScreen(values[0])
            print(json.dumps(frame_of(Path(values[0]))))
    except Exception as error:  # noqa: BLE001 — the reason is the output
        text = str(error).strip().replace("\n", " ") or "no details"
        print(f"{type(error).__name__}: {text}", file=sys.stderr)
        code = 1
    finally:
        # The reason goes out before anything else waits: an action that used up
        # the client's deadline leaves none for a disconnect to wait as well, and
        # the lab would kill the client with nothing said.
        sys.stdout.flush()
        sys.stderr.flush()
        # Only a connection that was made: vncdotool's disconnect otherwise waits
        # out the whole deadline for one that never will be.
        if client is not None and client.protocol is not None:
            client.timeout = min(DISCONNECT_SECONDS, seconds)
            try:
                client.disconnect()
            except Exception:  # noqa: BLE001 — the action's outcome is what matters
                pass
        api.shutdown()
    return code


if __name__ == "__main__":
    code = main()
    sys.stdout.flush()
    sys.stderr.flush()
    # Straight out: nothing left in Twisted's threads may keep the process — and
    # so the lab's deadline — waiting.
    os._exit(code)
