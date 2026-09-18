"""uDeck in the guest: installed, launched, ended — and never the wrong copy.

The fakes here answer SSH the way a machine does, including the difference
between the two calls: `run(check=False)` hands back an exit code, `ask` raises
when the connection itself failed. A check that reads a pid with the first would
call a dropped connection "uDeck is not running", which is a verdict — so the
difference has to be in the fake, or nothing tests it.
"""

import pytest
from fakes import Dropped, Machine as FakeMachine

from udeck_e2e import app, config
from udeck_e2e.builds import Build
from udeck_e2e.errors import LabError


def a_build(tmp_path, version="0.4.2", number="7", size=4105315):
    zip_path = tmp_path / f"uDeck-{version}.zip"
    zip_path.write_bytes(b"x" * size)
    return Build(version, number, zip_path)


# --- Installing -------------------------------------------------------------------------


def test_installing_puts_the_build_in_applications_owned_by_the_person_using_the_guest(tmp_path):
    machine = FakeMachine({"stat -f %Su": config.GUEST_USER})
    archive = a_build(tmp_path, version="0.4.1", size=10).zip
    app.install(machine, archive, note=lambda text: None)
    assert machine.ssh.copied == [(archive.name, f"/tmp/{archive.name}")]
    unpack = [c for c in machine.ssh.commands if "ditto -x -k" in c]
    assert unpack and app.GUEST_APPLICATIONS in unpack[0]
    # The copy already there goes first: ditto would otherwise merge into it and
    # leave files of the old version inside the new bundle.
    assert f"rm -rf {app.GUEST_APPLICATIONS}/{app.APP}" in unpack[0]
    assert any("xattr -p com.apple.quarantine" in c for c in machine.ssh.commands)


def test_a_build_that_landed_wrong_in_the_guest_is_a_lab_error(tmp_path):
    archive = a_build(tmp_path, version="0.4.1", size=10).zip
    with pytest.raises(LabError, match="belongs to root"):
        app.install(FakeMachine({"stat -f %Su": "root"}), archive, note=lambda text: None)

    quarantined = FakeMachine({"stat -f %Su": config.GUEST_USER, "xattr -p com.apple.quarantine": "0083;68c9…"})
    with pytest.raises(LabError, match="quarantine"):
        app.install(quarantined, archive, note=lambda text: None)


def test_the_version_on_disk_is_read_from_the_bundle_in_the_guest():
    machine = FakeMachine({"defaults read": "0.4.1\n6\n"})
    assert app.installed_version(machine) == ("0.4.1", "6")
    # One line instead of two: one of the two reads answered with nothing.
    with pytest.raises(LabError, match="unexpected answer"):
        app.installed_version(FakeMachine({"defaults read": "0.4.1\n"}))


# --- What is running in the guest ------------------------------------------------------


def test_the_pids_uDeck_has_are_read_in_a_way_a_dropped_connection_cannot_answer():
    """`ask`, not `run(check=False)`: SSH failing must not read as "it is not running"."""
    machine = FakeMachine({"pgrep -x uDeck": "101\n202\n"})
    assert app.running_pids(machine) == {"101", "202"}

    dropped = FakeMachine({"pgrep -x uDeck": Dropped})
    with pytest.raises(LabError, match="SSH to 192.168.64.2 failed"):
        app.running_pids(dropped)


def test_a_running_uDeck_is_asked_to_quit_before_its_bundle_is_replaced():
    """A copy left by the previous check keeps running from the bundle ditto deletes.

    `open -a` then only brings that one forward, and the check drives an
    application that is not the one it installed.
    """
    machine = FakeMachine({"pgrep -x uDeck": ["909", "909", ""]})
    app.quit_app(machine, "quitting uDeck")
    asked = [c for c in machine.ssh.commands if "to quit" in c]
    assert asked and "System Events" in asked[0], "a bare quit resolves the bundle that is going"
    assert not any("pkill" in c for c in machine.ssh.commands), "it went when it was asked"


def test_a_uDeck_that_will_not_quit_is_killed_and_then_given_up_on():
    killed = FakeMachine({"pgrep -x uDeck": ["909"] * 20 + [""]})
    app.quit_app(killed, "quitting uDeck")
    assert any("pkill -x uDeck" in c for c in killed.ssh.commands)
    assert killed.now >= config.QUIT_SECONDS / 2

    stuck = FakeMachine({"pgrep -x uDeck": "909"})
    with pytest.raises(LabError, match="still running in the guest as"):
        app.quit_app(stuck, "quitting uDeck")
    assert stuck.now >= config.QUIT_SECONDS


def test_nothing_is_asked_to_quit_when_nothing_is_running():
    machine = FakeMachine()
    app.quit_app(machine, "quitting uDeck")
    assert not any("quit" in c or "pkill" in c for c in machine.ssh.commands)


def test_installing_ends_what_is_running_before_it_replaces_the_bundle(tmp_path):
    machine = FakeMachine({"pgrep -x uDeck": ["909", ""], "stat -f %Su": config.GUEST_USER})
    app.install(machine, a_build(tmp_path, version="0.4.1", size=10).zip, note=lambda text: None)
    quit_at = next(i for i, c in enumerate(machine.ssh.commands) if "to quit" in c)
    ditto_at = next(i for i, c in enumerate(machine.ssh.commands) if "ditto -x -k" in c)
    assert quit_at < ditto_at


# --- Launching --------------------------------------------------------------------------


def test_launching_answers_with_the_one_pid_uDeck_is_running_as():
    machine = FakeMachine({"pgrep -x uDeck": ["", "404"]})
    assert app.launch(machine) == {"404"}
    assert any("open -a" in c and app.APP in c for c in machine.ssh.commands)


def test_a_second_copy_of_uDeck_is_a_lab_problem():
    """`open -a` activates what is already running instead of starting a copy.

    Two pids mean the check is about to drive an application it did not install
    — on a shared machine, the previous check's (--vm per-group, per-run).
    """
    machine = FakeMachine({"pgrep -x uDeck": "101\n202"})
    with pytest.raises(LabError, match="2 copies of uDeck are running"):
        app.launch(machine)


def test_a_uDeck_that_never_starts_is_a_lab_problem():
    machine = FakeMachine({"pgrep -x uDeck": ""})
    with pytest.raises(LabError, match="uDeck was not running within"):
        app.launch(machine)
    assert machine.now >= config.LAUNCH_SECONDS


def test_a_blip_while_it_starts_is_not_a_uDeck_that_never_started():
    machine = FakeMachine({"pgrep -x uDeck": ["", Dropped, "", "505"]})
    assert app.wait_until_running(machine) == {"505"}
