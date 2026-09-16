"""`e2e/run.sh`'s command line."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pytest

from udeck_e2e import config
from udeck_e2e.outcomes import EXIT_NOT_CHECKED
from udeck_e2e.plugin import LabPlugin

E2E_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = E2E_DIR.parent


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="e2e/run.sh",
        description=(
            "Run uDeck's end-to-end checks in throwaway macOS virtual machines. "
            "Exits 0 when every check passed, 1 when any check failed, and 2 when "
            "the lab could not check something — or checked nothing."
        ),
    )
    p.add_argument(
        "names",
        nargs="*",
        metavar="CHECK-OR-GROUP",
        help="a check (updates.wrong-key) or a group (updates); nothing means all",
    )
    p.add_argument("--list", action="store_true", help="print the checks there are and exit")
    p.add_argument(
        "--guest",
        choices=sorted(config.GUESTS),
        default=config.DEFAULT_GUEST,
        help=f"which macOS runs the checks (default {config.DEFAULT_GUEST})",
    )
    # For the lab's own tests: run checks from somewhere else.
    p.add_argument("--checks-dir", type=Path, default=E2E_DIR / "checks", help=argparse.SUPPRESS)
    return p


def pytest_args(checks_dir: Path, listing: bool) -> list[str]:
    args = [
        str(checks_dir),
        "-c",
        str(checks_dir / "pytest.ini"),
        "--rootdir",
        str(checks_dir),
        # One voice in the console: the plugin's.
        "-p",
        "no:terminal",
        # Nothing written into the source tree.
        "-p",
        "no:cacheprovider",
    ]
    if listing:
        args.append("--collect-only")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    checks_dir: Path = args.checks_dir.resolve()

    plugin = LabPlugin(
        wanted=args.names,
        listing=args.list,
        guest=config.GUESTS[args.guest],
        repo_root=REPO_ROOT,
        checks_dir=checks_dir,
        runs_root=REPO_ROOT / ".build" / "e2e",
    )
    status = pytest.main(pytest_args(checks_dir, args.list), plugins=[plugin])
    if status in (pytest.ExitCode.INTERNAL_ERROR, pytest.ExitCode.USAGE_ERROR):
        print(f"pytest could not run the checks ({pytest.ExitCode(status).name}).", file=sys.stderr)
        return EXIT_NOT_CHECKED
    return plugin.exit_code


if __name__ == "__main__":
    sys.exit(main())
