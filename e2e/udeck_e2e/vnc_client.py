"""One VNC action on a machine's screen, in a process of its own.

    python -m udeck_e2e.vnc_client move X Y
    python -m udeck_e2e.vnc_client capture PATH

Started by `udeck_e2e.vnc`, never by a person: the server, the password and the
deadline arrive in the environment. A capture prints what it saved as one JSON
object — width, height, and whether every pixel is the same colour. Exit 0 when
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

USAGE = "usage: python -m udeck_e2e.vnc_client move X Y | capture PATH (run by the lab)"


def frame_of(path: Path) -> dict[str, object]:
    from PIL import Image

    with Image.open(path) as image:
        extrema = image.convert("RGB").getextrema()
        return {
            "width": image.width,
            "height": image.height,
            "blank": all(low == high for low, high in extrema),
        }


def parse_action(args: list[str]) -> tuple[str, list[str]] | None:
    if len(args) == 3 and args[0] == "move" and all(a.isdigit() for a in args[1:]):
        return "move", args[1:]
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
    try:
        client = api.connect(server, password=password, timeout=seconds)
        try:
            if kind == "move":
                client.mouseMove(int(values[0]), int(values[1]))
            else:
                # The one full frame this connection gets; see udeck_e2e.vnc.
                client.captureScreen(values[0])
                print(json.dumps(frame_of(Path(values[0]))))
        finally:
            # Only a connection that was made: vncdotool's disconnect otherwise
            # waits out the whole deadline for one that never will be.
            if client.protocol is not None:
                client.disconnect()
    except Exception as error:  # noqa: BLE001 — the reason is the output
        text = str(error).strip().replace("\n", " ") or "no details"
        print(f"{type(error).__name__}: {text}", file=sys.stderr)
        return 1
    finally:
        api.shutdown()
    return 0


if __name__ == "__main__":
    code = main()
    sys.stdout.flush()
    sys.stderr.flush()
    # Straight out: nothing left in Twisted's threads may keep the process — and
    # so the lab's deadline — waiting.
    os._exit(code)
