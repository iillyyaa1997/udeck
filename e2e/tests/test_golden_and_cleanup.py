from udeck_e2e import config, golden
from udeck_e2e.cleanup import clean
from udeck_e2e.errors import LabError
from udeck_e2e.preflight import VM

GUEST = config.GUESTS["27"]


def test_a_golden_image_is_fit_only_with_a_record_matching_the_pins(tmp_path):
    names = [GUEST.golden_vm]
    assert "no golden image" in golden.problem(GUEST, [], tmp_path).what
    assert "no record" in golden.problem(GUEST, names, tmp_path).what
    golden.write(GUEST, "26A5416b", tmp_path)
    assert golden.problem(GUEST, names, tmp_path) is None
    record = golden.read(GUEST, tmp_path)
    assert record["guest_build"] == "26A5416b" and record["display"] == config.GOLDEN_DISPLAY


def test_an_older_bake_is_refused(tmp_path, monkeypatch):
    golden.write(GUEST, "26A5416b", tmp_path)
    # golden.problem reads config.BAKE_VERSION when called, so this reaches it.
    monkeypatch.setattr(config, "BAKE_VERSION", config.BAKE_VERSION + 1)
    assert "Bake it again" in golden.problem(GUEST, [GUEST.golden_vm], tmp_path).todo


class FakeTart:
    def __init__(self, vms, fails=()):
        self.vms = vms
        self.fails = set(fails)
        self.deleted = []

    def list(self):
        return self.vms

    def delete(self, name):
        if name in self.fails:
            raise LabError(f"deleting {name}", "busy")
        self.deleted.append(name)


VMS = [
    VM("udeck-lab", False),
    VM(GUEST.golden_vm, False),
    VM("udeck-e2e-kept-20260916-120000Z-panel.push", False),
    VM("udeck-e2e-20260916-120000Z-panel.dwell", False),
    VM("udeck-e2e-20260916-130000Z-panel.dwell", True),
]


def test_cleanup_removes_lab_clones_but_not_golden_images_running_machines_or_others(tmp_path):
    tart, said = FakeTart(VMS), []
    code = clean(tart, said.append, include_golden=False, state_dir=tmp_path)
    assert tart.deleted == ["udeck-e2e-kept-20260916-120000Z-panel.push", "udeck-e2e-20260916-120000Z-panel.dwell"]
    assert code == 2 and any("is running" in s for s in said)


def test_cleanup_removes_golden_images_only_when_asked_and_forgets_them(tmp_path):
    golden.write(GUEST, "26A5416b", tmp_path)
    tart = FakeTart([VM(GUEST.golden_vm, False)])
    assert clean(tart, print, include_golden=False, state_dir=tmp_path) == 0 and tart.deleted == []
    assert golden.read(GUEST, tmp_path) is not None
    assert clean(tart, print, include_golden=True, state_dir=tmp_path) == 0 and tart.deleted == [GUEST.golden_vm]
    assert golden.read(GUEST, tmp_path) is None


def test_a_clone_that_will_not_delete_makes_cleanup_exit_2(tmp_path):
    tart = FakeTart([VM("udeck-e2e-x", False)], fails={"udeck-e2e-x"})
    assert clean(tart, print, include_golden=False, state_dir=tmp_path) == 2


def test_cleanup_list_says_what_would_go_and_deletes_nothing(tmp_path):
    tart, said = FakeTart(VMS[:4]), []
    assert clean(tart, said.append, include_golden=True, dry_run=True, state_dir=tmp_path) == 0
    assert tart.deleted == []
    assert sum("would delete" in s for s in said) == 3


def test_cleanup_golden_for_one_guest_leaves_the_other_guests_golden_image(tmp_path):
    other = config.GUESTS["26"]
    tart = FakeTart([VM(GUEST.golden_vm, False), VM(other.golden_vm, False)])
    clean(tart, print, include_golden=True, guests=[other], state_dir=tmp_path)
    assert tart.deleted == [other.golden_vm]
