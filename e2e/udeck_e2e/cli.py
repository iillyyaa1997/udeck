"""`e2e/run.sh`'s command line."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pytest

from udeck_e2e import cleanup, config, interrupts, preflight
from udeck_e2e.ledger import RunLock, host_lock_path
from udeck_e2e.errors import LabError
from udeck_e2e.outcomes import EXIT_FAILED, EXIT_NOT_CHECKED
from udeck_e2e.plugin import VM_SCOPES, LabPlugin
from udeck_e2e.tart import Tart

E2E_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = E2E_DIR.parent

# The lab's own work goes through the same machinery as the checks: the same
# lock, pre-flight, ledger and outcomes. Each is a directory of check files.
COMMAND_DIRS = {"bake": E2E_DIR / "bake", "selfcheck": E2E_DIR / "selfcheck"}
INI = E2E_DIR / "checks" / "pytest.ini"


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="e2e/run.sh",
        description=(
            "Run uDeck's end-to-end checks in throwaway macOS virtual machines. "
            "Exits 0 when every check passed, 1 when any check failed, and 2 when "
            "the lab could not check something — or checked nothing."
        ),
        epilog=(
            "Commands instead of checks: 'bake' makes the golden image a guest's machines "
            "are cloned from (once per guest); 'selfcheck' checks the lab itself; "
            "'cleanup' removes clones the lab kept or left behind (--golden removes the "
            "golden images too)."
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
        default=None,
        help=f"which macOS runs the checks (default {config.DEFAULT_GUEST}); with cleanup --golden, whose golden image",
    )
    p.add_argument(
        "--vm",
        choices=list(VM_SCOPES),
        default=None,
        help="a fresh machine for every check (default), for every group, or one for the whole run",
    )
    p.add_argument(
        "--jobs",
        type=int,
        choices=[1, 2],
        default=None,
        help="how many machines are alive at once (default 1); 2 boots the next check's machine "
             "while the current one is still in use — the checks themselves still run one at a time",
    )
    p.add_argument(
        "--keep-on-failure",
        action="store_true",
        help="keep the machine of a check that did not pass, stopped and renamed udeck-e2e-kept-…",
    )
    p.add_argument("--golden", action="store_true", help="with cleanup: remove golden images too")
    # For the lab's own tests: run checks from somewhere else.
    p.add_argument("--checks-dir", type=Path, default=E2E_DIR / "checks", help=argparse.SUPPRESS)
    return p


def pytest_args(target_dir: Path, listing: bool) -> list[str]:
    # The bake and the self-check share the checks' settings.
    own = target_dir / "pytest.ini"
    args = [
        str(target_dir),
        "-c",
        str(own if own.exists() else INI),
        "--rootdir",
        str(target_dir),
        # One voice in the console: the plugin's.
        "-p",
        "no:terminal",
        # And it has to reach the console while a check runs: with pytest's
        # capturing on, everything the lab says during a check — a retry, a
        # download, a machine kept for inspection — vanished until the end.
        "--capture=no",
        # Nothing written into the source tree.
        "-p",
        "no:cacheprovider",
    ]
    if listing:
        args.append("--collect-only")
    return args


# Which options each command takes. An option a command would ignore is refused:
# `cleanup --list` once deleted the kept clones it was asked to list.
ALLOWED = {
    "checks": {"list", "guest", "vm", "keep_on_failure", "jobs"},
    "selfcheck": {"list", "guest", "vm", "keep_on_failure", "jobs"},
    "bake": {"list", "guest"},
    "cleanup": {"list", "guest", "golden"},
}


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    command = args.names[0] if args.names and args.names[0] in (*COMMAND_DIRS, "cleanup") else None
    mode = command or "checks"
    if command and len(args.names) > 1:
        print(f"'{command}' takes no check names.", file=sys.stderr)
        return EXIT_NOT_CHECKED
    given = {
        name
        for name, value in (
            ("list", args.list), ("guest", args.guest), ("vm", args.vm),
            ("keep_on_failure", args.keep_on_failure), ("golden", args.golden),
            ("jobs", args.jobs),
        )
        if value not in (None, False)
    }  # fmt: skip
    refused = sorted(given - ALLOWED[mode])
    if refused:
        flags = ", ".join("--" + name.replace("_", "-") for name in refused)
        print(f"{flags} does nothing with {'checks' if mode == 'checks' else repr(mode)}.", file=sys.stderr)
        return EXIT_NOT_CHECKED

    # `--jobs 2` boots the machine the *next* check will use. With one machine for the
    # whole run there is no next machine, so the option would quietly do nothing — and an
    # option that does nothing is refused here rather than ignored.
    if args.jobs == 2 and args.vm == "per-run":
        print("--jobs 2 does nothing with --vm per-run: there is only ever one machine.", file=sys.stderr)
        return EXIT_NOT_CHECKED

    # Closing the terminal or `kill` stops the lab the way Ctrl-C does, cleanup included.
    interrupts.stop_on_hangup_and_terminate()

    if command == "cleanup":
        guests = [config.GUESTS[args.guest]] if args.guest else list(config.GUESTS.values())
        return run_cleanup(args.golden, guests, dry_run=args.list)

    target = COMMAND_DIRS[command] if command else args.checks_dir.resolve()
    plugin = LabPlugin(
        wanted=[] if command else args.names,
        listing=args.list,
        guest=config.GUESTS[args.guest or config.DEFAULT_GUEST],
        mode=mode,
        vm_mode=args.vm or "per-check",
        jobs=args.jobs or 1,
        keep_on_failure=args.keep_on_failure,
        repo_root=REPO_ROOT,
        checks_dir=target,
        runs_root=REPO_ROOT / ".build" / "e2e",
    )
    return run_pytest(plugin, pytest_args(target, args.list))


def run_pytest(plugin: LabPlugin, args: list[str]) -> int:
    """pytest.main, with every way it can end mapped onto the lab's exit codes.

    An exception that escapes pytest — a second Ctrl-C during cleanup, a bug in
    the lab — would otherwise make Python exit 1, which the lab reserves for
    "uDeck failed". It exits 1 only if a check really did fail before that.
    """
    try:
        status = pytest.main(args, plugins=[plugin])
    except BaseException as error:  # noqa: BLE001 — reported, and mapped to an exit code
        print(f"The lab stopped unexpectedly: {type(error).__name__}: {error}", file=sys.stderr)
        return EXIT_FAILED if plugin.saw_failure else EXIT_NOT_CHECKED
    if status in (pytest.ExitCode.INTERNAL_ERROR, pytest.ExitCode.USAGE_ERROR):
        print(f"pytest could not run the checks ({pytest.ExitCode(status).name}).", file=sys.stderr)
        return EXIT_FAILED if plugin.saw_failure else EXIT_NOT_CHECKED
    return plugin.exit_code


def run_cleanup(include_golden: bool, guests: list[config.Guest], dry_run: bool) -> int:
    lock = RunLock(host_lock_path())
    holder = lock.acquire()
    if holder is not None:
        print(f"A lab run is in progress (pid {holder}); cleanup waits for it to finish.")
        return EXIT_NOT_CHECKED
    try:
        binary = preflight.find_tart()
        if binary is None:
            print("Tart was not found, so there is nothing the lab could clean up.")
            return EXIT_NOT_CHECKED
        return cleanup.clean(Tart(binary, print), print, include_golden, guests=guests, dry_run=dry_run)
    except LabError as error:
        print(f"Cleanup stopped: {error}")
        return EXIT_NOT_CHECKED
    finally:
        lock.release()


if __name__ == "__main__":
    sys.exit(main())
