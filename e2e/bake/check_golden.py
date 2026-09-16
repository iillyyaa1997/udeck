"""`e2e/run.sh bake`: make the golden image every check's machine is cloned from.

Run once per guest, and again when the pinned base image or the bake itself
changes. It goes through the lab like a check does — the same lock, pre-flight,
ledger and cleanup — and anything that goes wrong is "could not check": a bake
says nothing about uDeck.
"""

from udeck_e2e import config, golden, probes
from udeck_e2e.errors import LabError


def check_bake(lab):
    guest = lab.guest
    lab.note(f"Downloading {guest.base_image} if it is not here yet…")
    lab.tart.pull(guest.base_image)

    machine = lab.new_machine("bake", source=guest.base_image, display=config.GOLDEN_DISPLAY)
    try:
        machine.create()
        machine.boot()

        # Spotlight: Cirrus Labs turns it off. With it off, LaunchServices does
        # not discover applications the way it does on a person's Mac.
        machine.ssh.run("sudo -n mdutil -a -i on", "turning Spotlight on")

        # Notifications: a "Background Items Added" banner lands at the top of
        # the screen, exactly where the panel check points.
        machine.ssh.run(
            "launchctl disable gui/$(id -u)/com.apple.notificationcenterui.agent && "
            "{ launchctl bootout gui/$(id -u)/com.apple.notificationcenterui.agent || true; }",
            "silencing notifications",
        )

        # English, so that nothing in a check depends on translated words.
        machine.ssh.run(
            "defaults write -g AppleLanguages -array en && defaults write -g AppleLocale en_US",
            "setting the language to English",
        )

        # Everything above must survive a restart, which is also what the checks
        # will do to every clone.
        machine.reboot()
        probes.verify_golden(machine)
        build = probes.guest_build(machine)

        problem = machine.shut_down()
        if problem:
            raise LabError("shutting the bake down", f"{problem} — a power-off can lose settings")

        if lab.tart.exists(guest.golden_vm):
            lab.note(f"Replacing the previous {guest.golden_vm}.")
            golden.forget(guest, lab.state_dir)
            lab.tart.delete(guest.golden_vm)
        lab.tart.rename(machine.name, guest.golden_vm)
        machine.created = False
        golden.write(guest, build, lab.state_dir)
        lab.note(f"Baked {guest.golden_vm} from macOS {build}.")
    finally:
        if machine.created:
            for problem in machine.close(keep=False):
                lab.note(f"   ⚠️ {problem}")

