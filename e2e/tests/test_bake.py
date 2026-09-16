"""The bake's last step: putting a new golden image in place without losing the old."""

import importlib.util
from types import SimpleNamespace

import pytest

from udeck_e2e import config, golden
from udeck_e2e.cli import E2E_DIR
from udeck_e2e.errors import LabError

spec = importlib.util.spec_from_file_location("check_golden", E2E_DIR / "bake" / "check_golden.py")
check_golden = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_golden)

GUEST = config.GUESTS["27"]


class Store:
    """Tart's store: names, and renames that can fail."""

    def __init__(self, names, rename_fails_for=None):
        self.names = set(names)
        self.rename_fails_for = rename_fails_for
        self.log = []

    def exists(self, name):
        return name in self.names

    def rename(self, name, new):
        self.log.append(("rename", name, new))
        if name == self.rename_fails_for:
            raise LabError(f"renaming {name}", "did not finish in 120s")
        self.names.remove(name)
        self.names.add(new)

    def delete(self, name):
        self.log.append(("delete", name))
        self.names.remove(name)


def lab_with(store, tmp_path):
    notes = []
    lab = SimpleNamespace(guest=GUEST, tart=store, state_dir=tmp_path, note=notes.append,
                          run_dir=tmp_path / "20260917-010000Z")
    return lab


def test_a_new_golden_image_replaces_the_old_one_only_once_it_holds_the_name(tmp_path):
    new = SimpleNamespace(name="udeck-e2e-20260917-010000Z-bake", created=True)
    store = Store({GUEST.golden_vm, new.name})
    golden.write(GUEST, "old-build", tmp_path)
    check_golden.replace_golden(lab_with(store, tmp_path), new, "26A5416b")
    assert store.names == {GUEST.golden_vm}
    assert golden.read(GUEST, tmp_path)["guest_build"] == "26A5416b"
    assert new.created is False
    kinds = [entry[0] for entry in store.log]
    assert kinds == ["rename", "rename", "delete"]  # aside, into place, then delete the old


def test_a_failed_rename_puts_the_old_golden_image_back(tmp_path):
    new = SimpleNamespace(name="udeck-e2e-20260917-010000Z-bake", created=True)
    store = Store({GUEST.golden_vm, new.name}, rename_fails_for=new.name)
    golden.write(GUEST, "old-build", tmp_path)
    with pytest.raises(LabError):
        check_golden.replace_golden(lab_with(store, tmp_path), new, "26A5416b")
    assert GUEST.golden_vm in store.names
    assert golden.read(GUEST, tmp_path)["guest_build"] == "old-build"
    assert new.created is True  # the caller's cleanup still deletes the new clone
