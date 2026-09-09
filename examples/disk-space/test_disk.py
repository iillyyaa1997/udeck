#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests for the disk-space uDeck plugin.

Nothing here reads the machine the suite runs on.  ``df`` is replaced with
canned output — including the end-to-end tests, which put a fake ``df`` on
PATH — so the suite says the same thing on a Mac with one disk and on a build
runner with none.

    python3 -m unittest discover -s examples/disk-space -p 'test_*.py'
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import disk  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "disk.py")
MANIFEST = os.path.join(HERE, "manifest.json")
TRANSLATION = os.path.join(HERE, "manifest.ru.json")

EN = disk.PHRASES["en"]
RU = disk.PHRASES["ru"]


def read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


# --------------------------------------------------------------------------
# Card validator — an independent reading of the schema in the plugin brief.
# --------------------------------------------------------------------------

ICON_VOCABULARY = {"ok", "warn", "crit", "wait", "run",
                   "idle", "done", "pause", "info", "dot"}
TINTS = {"ok", "warn", "crit", "unknown"}
ROW_KEYS = {"text", "kv", "meter", "list", "spark", "table", "log"}


# --------------------------------------------------------------------------
# Card validator — an independent reading of the schema in the plugin brief.
# --------------------------------------------------------------------------

def validate_card(card):
    """Return a list of schema violations; empty means the card is valid."""
    problems = []

    def bad(message):
        problems.append(message)

    if not isinstance(card, dict):
        return ["card is %s, not an object" % type(card).__name__]

    allowed_top = {"state", "title", "chip", "rows", "actions", "ttl"}
    for key in card:
        if key not in allowed_top:
            bad("unknown top-level key %r" % key)

    if card.get("state") not in TINTS:
        bad("state %r is not one of %s" % (card.get("state"), sorted(TINTS)))
    for key in ("title", "chip"):
        if key in card and not isinstance(card[key], str):
            bad("%s must be a string" % key)
    if "ttl" in card:
        ttl = card["ttl"]
        if isinstance(ttl, bool) or not isinstance(ttl, (int, float)) or ttl <= 0:
            bad("ttl must be a positive number, got %r" % (ttl,))

    rows = card.get("rows", [])
    if not isinstance(rows, list):
        bad("rows must be a list")
        rows = []
    for index, row in enumerate(rows):
        where = "row %d" % index
        if not isinstance(row, dict):
            bad("%s is %s, not an object" % (where, type(row).__name__))
            continue
        present = [key for key in row if key in ROW_KEYS]
        unknown = [key for key in row if key not in ROW_KEYS]
        if unknown:
            bad("%s has unknown key(s) %s" % (where, unknown))
        if len(present) != 1:
            bad("%s must have exactly one row-type key, has %s" % (where, present))
            continue
        _validate_row(row, present[0], where, bad)

    actions = card.get("actions", [])
    if not isinstance(actions, list):
        bad("actions must be a list")
        actions = []
    for index, action in enumerate(actions):
        where = "action %d" % index
        if not isinstance(action, dict):
            bad("%s is not an object" % where)
            continue
        for key in action:
            if key not in {"label", "run", "confirm"}:
                bad("%s has unknown key %r" % (where, key))
        if not isinstance(action.get("label"), str) or not action.get("label"):
            bad("%s needs a non-empty label" % where)
        run = action.get("run")
        if not isinstance(run, list) or not run or \
                not all(isinstance(part, str) for part in run):
            bad("%s run must be a non-empty list of strings" % where)
        if "confirm" in action and not isinstance(action["confirm"], str):
            bad("%s confirm must be a string" % where)
    return problems


def _validate_row(row, kind, where, bad):
    value = row[kind]
    if kind == "text":
        if not isinstance(value, str):
            bad("%s text must be a string" % where)
    elif kind == "kv":
        if not isinstance(value, list) or len(value) not in (2, 3):
            bad("%s kv must be a 2- or 3-element list" % where)
            return
        if not all(isinstance(part, str) for part in value[:2]):
            bad("%s kv label and value must be strings" % where)
        if len(value) == 3 and value[2] not in TINTS:
            bad("%s kv tint %r is not a state" % (where, value[2]))
    elif kind == "meter":
        if not isinstance(value, dict):
            bad("%s meter must be an object" % where)
            return
        number = value.get("value")
        if isinstance(number, bool) or not isinstance(number, (int, float)) \
                or not 0.0 <= number <= 1.0:
            bad("%s meter value must be between 0 and 1" % where)
        for key in ("label", "caption"):
            if key in value and not isinstance(value[key], str):
                bad("%s meter %s must be a string" % (where, key))
        if "state" in value and value["state"] not in TINTS:
            bad("%s meter state %r is not a state" % (where, value["state"]))
    elif kind == "list":
        if not isinstance(value, list):
            bad("%s list must be a list" % where)
            return
        for index, item in enumerate(value):
            spot = "%s item %d" % (where, index)
            if not isinstance(item, dict):
                bad("%s is not an object" % spot)
                continue
            for key in item:
                if key not in {"text", "note", "icon", "state"}:
                    bad("%s has unknown key %r" % (spot, key))
            if not isinstance(item.get("text"), str):
                bad("%s needs a text string" % spot)
            if "note" in item and not isinstance(item["note"], str):
                bad("%s note must be a string" % spot)
            if "icon" in item and item["icon"] not in ICON_VOCABULARY:
                bad("%s icon %r is outside the vocabulary" % (spot, item["icon"]))
            if "state" in item and item["state"] not in TINTS:
                bad("%s state %r is not a state" % (spot, item["state"]))
    elif kind == "spark":
        values = value.get("values") if isinstance(value, dict) else value
        if not isinstance(values, list) or \
                not all(isinstance(v, (int, float)) and not isinstance(v, bool)
                        for v in values):
            bad("%s spark needs a list of numbers" % where)
        if isinstance(value, dict):
            for key in value:
                if key not in {"values", "caption"}:
                    bad("%s spark has unknown key %r" % (where, key))
    elif kind == "table":
        if not isinstance(value, dict):
            bad("%s table must be an object" % where)
            return
        columns = value.get("columns")
        if not isinstance(columns, list) or not columns:
            bad("%s table needs columns" % where)
            columns = []
        for column in columns:
            if not isinstance(column, dict) or not isinstance(column.get("title"), str):
                bad("%s table column needs a title" % where)
            elif column.get("align") not in (None, "left", "right", "center"):
                bad("%s table column align %r is invalid" % (where, column.get("align")))
        table_rows = value.get("rows")
        if not isinstance(table_rows, list):
            bad("%s table needs rows" % where)
        else:
            for table_row in table_rows:
                if not isinstance(table_row, list) or \
                        not all(isinstance(cell, str) for cell in table_row):
                    bad("%s table row must be a list of strings" % where)
                elif columns and len(table_row) != len(columns):
                    bad("%s table row width does not match the columns" % where)
    elif kind == "log":
        if not isinstance(value, list) or \
                not all(isinstance(line, str) for line in value):
            bad("%s log must be a list of strings" % where)


# --------------------------------------------------------------------------
# Canned df output
# --------------------------------------------------------------------------

HEADER = "Filesystem     1024-blocks      Used Available Capacity  Mounted on"

# An Apple silicon Mac: one 1 TB APFS container holding five volumes that share
# 657 GB of free space, plus the half-gigabyte container the secure enclave
# keeps to itself, plus two pseudo-filesystems.
APPLE_SILICON = "\n".join([
    HEADER,
    "/dev/disk3s1s1   971298980  12342964 657237268     2%    /",
    "devfs                  239       239         0   100%    /dev",
    "/dev/disk3s6     971298980   3145748 657237268     1%    /System/Volumes/VM",
    "/dev/disk3s2     971298980   8859848 657237268     2%    /System/Volumes/Preboot",
    "/dev/disk3s4     971298980      4012 657237268     1%    /System/Volumes/Update",
    "/dev/disk1s2        563200      6164    542660     2%    /System/Volumes/xarts",
    "/dev/disk1s1        563200      6032    542660     2%    /System/Volumes/iSCPreboot",
    "/dev/disk1s3        563200      3440    542660     1%    /System/Volumes/Hardware",
    "/dev/disk3s5     971298980 287905764 657237268    31%    /System/Volumes/Data",
    "map auto_home            0         0         0   100%    /System/Volumes/Data/home",
]) + "\n"

# The same machine with an external drive that is nearly full, mounted under a
# name containing a space.
EXTERNAL_LINE = \
    "/dev/disk4s1     488281250 468281250  20000000    96%    /Volumes/Time Machine"
WITH_EXTERNAL = APPLE_SILICON + EXTERNAL_LINE + "\n"


def canned(text):
    """A df reader that answers with fixed output."""
    def reader(timeout=None):
        return text
    return reader


def failing(exc):
    def reader(timeout=None):
        raise exc
    return reader


def settings(**overrides):
    base = {key: default for key, _kind, default, _lo, _hi in disk.SETTING_SPECS}
    base.update(overrides)
    return base


def card_for(text=APPLE_SILICON, words=EN, **overrides):
    return disk.gather(settings(**overrides), words, df_reader=canned(text))


def meters(card):
    return [row["meter"] for row in card["rows"] if "meter" in row]


def texts(card):
    return [row["text"] for row in card["rows"] if "text" in row]


# --------------------------------------------------------------------------
# Parsing df
# --------------------------------------------------------------------------

class DfParsingTests(unittest.TestCase):

    def parse(self, text):
        problems = disk.Problems()
        return disk.parse_df(text, problems), problems

    def test_header_is_not_a_volume(self):
        volumes, problems = self.parse(HEADER + "\n")
        self.assertEqual([], volumes)
        self.assertEqual(0, problems.line_errors)

    def test_apple_silicon_yields_only_real_devices(self):
        volumes, problems = self.parse(APPLE_SILICON)
        self.assertEqual(8, len(volumes))
        self.assertTrue(all(v.device.startswith("/dev/") for v in volumes))
        self.assertEqual(0, problems.line_errors)

    def test_pseudo_filesystems_are_dropped(self):
        volumes, _ = self.parse(APPLE_SILICON)
        mounts = [v.mount for v in volumes]
        self.assertNotIn("/dev", mounts)
        self.assertNotIn("/System/Volumes/Data/home", mounts)

    def test_a_filesystem_name_with_a_space_does_not_shift_the_columns(self):
        # "map auto_home" is dropped for not being a device, but it must be
        # dropped for that reason and not because the parser miscounted.
        volumes, problems = self.parse(
            HEADER + "\nmap auto_home            0         0         0   100%    /net\n")
        self.assertEqual([], volumes)
        self.assertEqual(0, problems.line_errors)

    def test_a_mount_point_with_a_space_survives_whole(self):
        volumes, _ = self.parse(HEADER + "\n" + EXTERNAL_LINE + "\n")
        self.assertEqual(["/Volumes/Time Machine"], [v.mount for v in volumes])

    def test_numbers_are_read_as_kib_blocks(self):
        volumes, _ = self.parse(HEADER + "\n" + EXTERNAL_LINE + "\n")
        volume = volumes[0]
        self.assertEqual(488281250, volume.blocks)
        self.assertEqual(468281250, volume.used)
        self.assertEqual(20000000, volume.avail)

    def test_a_zero_block_device_is_not_a_disk(self):
        volumes, _ = self.parse(
            HEADER + "\n/dev/disk9s1            0         0         0   100%    /empty\n")
        self.assertEqual([], volumes)

    def test_an_unparsable_line_is_counted_not_fatal(self):
        volumes, problems = self.parse(
            APPLE_SILICON + "this line is not df output at all\n")
        self.assertEqual(8, len(volumes))
        self.assertEqual(1, problems.line_errors)

    def test_blank_lines_are_ignored(self):
        volumes, problems = self.parse("\n" + APPLE_SILICON + "\n\n")
        self.assertEqual(8, len(volumes))
        self.assertEqual(0, problems.line_errors)

    def test_trailing_whitespace_is_not_part_of_the_mount(self):
        volumes, _ = self.parse(
            HEADER + "\n/dev/disk4s1     488281250 468281250  20000000    96%    /Volumes/Backup   \n")
        self.assertEqual(["/Volumes/Backup"], [v.mount for v in volumes])


class ContainerTests(unittest.TestCase):

    def volume(self, device, mount="/x"):
        return disk.Volume(device=device, mount=mount, blocks=10, used=1, avail=9)

    def test_apfs_volumes_share_a_container(self):
        self.assertEqual("disk3", self.volume("/dev/disk3s1s1").container)
        self.assertEqual("disk3", self.volume("/dev/disk3s5").container)

    def test_two_disks_are_two_containers(self):
        self.assertNotEqual(self.volume("/dev/disk3s5").container,
                            self.volume("/dev/disk4s1").container)

    def test_a_whole_device_is_its_own_container(self):
        self.assertEqual("disk4", self.volume("/dev/disk4").container)

    def test_an_unrecognised_device_falls_back_to_itself(self):
        self.assertEqual("/dev/weird", self.volume("/dev/weird").container)

    def test_system_volumes_are_recognised(self):
        self.assertTrue(self.volume("/dev/disk3s2", "/System/Volumes/Preboot").is_system)
        self.assertFalse(self.volume("/dev/disk3s1s1", "/").is_system)

    def test_the_data_volume_is_not_a_system_volume(self):
        # It is where the operator's files live; hiding it would hide the disk.
        self.assertFalse(self.volume("/dev/disk3s5", "/System/Volumes/Data").is_system)


# --------------------------------------------------------------------------
# Volumes to disks
# --------------------------------------------------------------------------

class GroupingTests(unittest.TestCase):

    def disks(self, text=APPLE_SILICON, words=EN, hide_system=True):
        volumes = disk.parse_df(text, disk.Problems())
        return disk.group_into_disks(volumes, words, hide_system)

    def test_five_volumes_become_one_disk(self):
        disks = self.disks()
        self.assertEqual(1, len(disks))
        self.assertEqual(5, len(disks[0].members))

    def test_used_space_is_summed_across_the_container(self):
        got = self.disks()[0]
        self.assertEqual(12342964 + 3145748 + 8859848 + 4012 + 287905764, got.used)

    def test_free_space_is_taken_once_not_five_times(self):
        got = self.disks()[0]
        self.assertEqual(657237268, got.avail)

    def test_the_secure_enclave_container_is_dropped(self):
        self.assertEqual(["disk3"], [d.key for d in self.disks()])

    def test_keeping_system_volumes_keeps_that_container(self):
        self.assertEqual(["disk3", "disk1"],
                         [d.key for d in self.disks(hide_system=False)])

    def test_an_external_disk_is_its_own_row(self):
        disks = self.disks(WITH_EXTERNAL)
        self.assertEqual(["disk3", "disk4"], [d.key for d in disks])

    def test_the_startup_disk_gets_a_written_name(self):
        self.assertEqual(EN["startup"], self.disks()[0].name)

    def test_the_startup_disk_is_named_in_the_panel_s_language(self):
        self.assertEqual(RU["startup"], self.disks(words=RU)[0].name)

    def test_an_external_disk_is_named_after_its_mount(self):
        disks = self.disks(WITH_EXTERNAL)
        self.assertEqual("Time Machine", disks[1].name)

    def test_the_open_action_targets_the_data_volume_not_the_sealed_root(self):
        self.assertEqual(disk.DATA_MOUNT, self.disks()[0].mount)

    def test_capacity_is_what_is_used_plus_what_is_free(self):
        got = self.disks()[0]
        self.assertEqual(got.used + got.avail, got.capacity)
        self.assertNotEqual(got.total, got.capacity)

    def test_percent_used_is_measured_against_capacity(self):
        got = self.disks()[0]
        self.assertEqual(int(round(100.0 * got.used / (got.used + got.avail))),
                         got.percent_used)

    def test_percent_of_an_empty_disk_is_zero_not_a_crash(self):
        empty = disk.Disk(key="d", name="d", used=0, avail=0, total=0,
                          mount="/d", members=[])
        self.assertEqual(0, empty.percent_used)


class MountViewTests(unittest.TestCase):

    def disks(self, hide_system=True):
        volumes = disk.parse_df(APPLE_SILICON, disk.Problems())
        return disk.volumes_as_disks(volumes, EN, hide_system)

    def test_hiding_system_volumes_leaves_the_two_that_matter(self):
        self.assertEqual(["/", disk.DATA_MOUNT], [d.key for d in self.disks()])

    def test_showing_them_lists_every_volume(self):
        self.assertEqual(8, len(self.disks(hide_system=False)))

    def test_each_volume_keeps_its_own_numbers(self):
        root = self.disks()[0]
        self.assertEqual(12342964, root.used)
        self.assertEqual(657237268, root.avail)

    def test_the_root_volume_is_named_rather_than_shown_as_a_slash(self):
        self.assertEqual(EN["startup"], self.disks()[0].name)

    def test_a_volume_under_system_volumes_keeps_its_basename(self):
        names = [d.name for d in self.disks(hide_system=False)]
        self.assertIn("Preboot", names)


class OwningDiskTests(unittest.TestCase):

    def setUp(self):
        volumes = disk.parse_df(WITH_EXTERNAL, disk.Problems())
        self.disks = disk.group_into_disks(volumes, EN, True)

    def test_the_longest_matching_mount_wins(self):
        got = disk.owning_disk(self.disks, "/Volumes/Time Machine/backups")
        self.assertEqual("disk4", got.key)

    def test_a_path_on_no_special_volume_lands_on_the_startup_disk(self):
        self.assertEqual("disk3", disk.owning_disk(self.disks, "/Users/someone").key)

    def test_the_mount_point_itself_matches(self):
        self.assertEqual("disk4", disk.owning_disk(self.disks, "/Volumes/Time Machine").key)

    def test_a_sibling_with_a_shared_prefix_does_not_match(self):
        # "/Volumes/Time Machine 2" starts with the same characters but is a
        # different volume; matching on the raw prefix would claim it.
        self.assertEqual("disk3", disk.owning_disk(self.disks, "/Volumes/Time Machine 2").key)

    def test_an_empty_path_asks_for_nothing(self):
        self.assertIsNone(disk.owning_disk(self.disks, ""))

    def test_a_tilde_is_expanded(self):
        self.assertIsNotNone(disk.owning_disk(self.disks, "~"))


# --------------------------------------------------------------------------
# Formatting
# --------------------------------------------------------------------------

class HumanBytesTests(unittest.TestCase):

    def test_kib_blocks_are_shown_in_the_decimal_units_the_finder_uses(self):
        self.assertEqual("673 GB", disk.human_bytes(657237268, EN["units"]))

    def test_a_small_volume_reads_in_megabytes(self):
        self.assertEqual("556 MB", disk.human_bytes(542660, EN["units"]))

    def test_units_follow_the_panel_s_language(self):
        self.assertEqual("673 ГБ", disk.human_bytes(657237268, RU["units"]))

    def test_zero_is_zero_bytes(self):
        self.assertEqual("0 B", disk.human_bytes(0, EN["units"]))

    def test_a_value_below_a_hundred_keeps_one_decimal(self):
        self.assertEqual("1.5 GB", disk.human_bytes(1465000, EN["units"]))

    def test_a_trailing_zero_decimal_is_dropped(self):
        self.assertEqual("1 kB", disk.human_bytes(1, EN["units"]))

    def test_terabytes_are_reached(self):
        self.assertTrue(disk.human_bytes(4 * 1000 ** 3, EN["units"]).endswith("TB"))

    def test_the_largest_unit_does_not_overflow_the_table(self):
        self.assertTrue(disk.human_bytes(10 ** 15, EN["units"]).endswith("PB"))


class LanguageTests(unittest.TestCase):

    def test_the_default_is_english(self):
        self.assertIs(EN, disk.phrases({}))

    def test_russian_is_selected_by_code(self):
        self.assertIs(RU, disk.phrases({"UDECK_LANG": "ru"}))

    def test_a_region_is_reduced_to_its_base_language(self):
        self.assertIs(RU, disk.phrases({"UDECK_LANG": "ru-RU"}))
        self.assertIs(RU, disk.phrases({"UDECK_LANG": "ru_RU"}))

    def test_a_language_the_plugin_does_not_speak_falls_back(self):
        self.assertIs(EN, disk.phrases({"UDECK_LANG": "ja"}))

    def test_an_empty_value_falls_back(self):
        self.assertIs(EN, disk.phrases({"UDECK_LANG": ""}))

    def test_case_and_padding_do_not_matter(self):
        self.assertIs(RU, disk.phrases({"UDECK_LANG": " RU "}))

    def test_every_language_declares_every_phrase(self):
        for code, table in disk.PHRASES.items():
            self.assertEqual(set(EN), set(table), "%s is missing phrases" % code)


# --------------------------------------------------------------------------
# The card
# --------------------------------------------------------------------------

class CardTests(unittest.TestCase):

    def test_a_healthy_machine_is_one_ok_meter(self):
        card = card_for()
        self.assertEqual("ok", card["state"])
        self.assertEqual(1, len(meters(card)))
        self.assertEqual([], validate_card(card))

    def test_the_chip_leads_with_free_space_when_all_is_well(self):
        self.assertEqual("673 GB free", card_for()["chip"])

    def test_the_meter_says_free_of_capacity(self):
        self.assertEqual("673 GB free of 993 GB", meters(card_for())[0]["caption"])

    def test_a_full_disk_turns_the_card_amber(self):
        card = card_for(WITH_EXTERNAL, warn_percent=90, crit_percent=99)
        self.assertEqual("warn", card["state"])

    def test_a_full_disk_turns_the_card_red_past_the_second_threshold(self):
        card = card_for(WITH_EXTERNAL)
        self.assertEqual("crit", card["state"])

    def test_the_chip_names_the_disk_that_went_amber(self):
        card = card_for(WITH_EXTERNAL)
        self.assertIn("Time Machine", card["chip"])
        self.assertIn("96", card["chip"])

    def test_one_bad_disk_does_not_recolour_the_others(self):
        states = [meter["state"] for meter in meters(card_for(WITH_EXTERNAL))]
        self.assertEqual(["ok", "crit"], states)

    def test_the_action_opens_the_headline_disk(self):
        card = card_for()
        self.assertEqual([{"label": "Open " + EN["startup"],
                           "run": ["open", disk.DATA_MOUNT]}],
                         card["actions"])

    def test_the_watched_path_is_listed_first(self):
        card = card_for(WITH_EXTERNAL, watch_path="/Volumes/Time Machine/x")
        self.assertEqual("Time Machine", meters(card)[0]["label"])
        self.assertIn("Time Machine", card["actions"][0]["label"])

    def test_a_watched_path_on_no_disk_changes_nothing(self):
        card = card_for(WITH_EXTERNAL, watch_path="/nowhere/at/all")
        self.assertEqual(EN["startup"], meters(card)[0]["label"])

    def test_the_mount_view_lists_volumes_and_says_what_it_hid(self):
        card = card_for(volumes="mounts")
        self.assertEqual(2, len(meters(card)))
        self.assertIn(EN["hidden"] % 6, texts(card))

    def test_the_startup_view_is_one_disk_even_with_an_external_attached(self):
        card = card_for(WITH_EXTERNAL, volumes="startup")
        self.assertEqual([EN["startup"]], [meter["label"] for meter in meters(card)])

    def test_the_card_speaks_the_panel_s_language(self):
        card = card_for(words=RU)
        self.assertEqual("673 ГБ свободно", card["chip"])
        self.assertTrue(card["actions"][0]["label"].startswith("Открыть"))

    def test_unreadable_lines_are_reported_without_spoiling_the_numbers(self):
        card = card_for(APPLE_SILICON + "rubbish\n")
        self.assertEqual("ok", card["state"])
        self.assertIn({"kv": [EN["unreadable_lines"], "1", "warn"]}, card["rows"])

    def test_the_meter_value_is_a_fraction(self):
        value = meters(card_for())[0]["value"]
        self.assertTrue(0.0 <= value <= 1.0)
        self.assertAlmostEqual(0.322, value, places=3)

    def test_the_card_declares_a_ttl_of_four_intervals(self):
        manifest = read_json(MANIFEST)
        self.assertEqual(card_for()["ttl"], manifest["interval"] * 4)


class ManyDisksTests(unittest.TestCase):

    def machine(self, count):
        lines = [HEADER]
        for index in range(count):
            lines.append(
                "/dev/disk%ds1     100000000  10000000  90000000    10%%    /Volumes/D%d"
                % (index + 10, index))
        return "\n".join(lines) + "\n"

    def test_the_card_caps_the_meters_it_draws(self):
        card = card_for(self.machine(9))
        self.assertEqual(disk.MAX_METER_ROWS, len(meters(card)))
        self.assertIn(EN["more"] % (9 - disk.MAX_METER_ROWS), texts(card))

    def test_no_overflow_row_when_everything_fits(self):
        card = card_for(self.machine(disk.MAX_METER_ROWS))
        self.assertEqual([], [t for t in texts(card) if t.startswith("+")])

    def test_a_disk_past_the_cap_still_colours_the_card(self):
        crowded = self.machine(disk.MAX_METER_ROWS) + \
            "/dev/disk99s1    100000000  99000000   1000000    99%    /Volumes/Last\n"
        card = card_for(crowded)
        self.assertEqual("crit", card["state"])
        self.assertIn("Last", card["chip"])


# --------------------------------------------------------------------------
# When df will not answer
# --------------------------------------------------------------------------

class FailureTests(unittest.TestCase):

    def gather(self, reader, words=EN):
        return disk.gather(settings(), words, df_reader=reader)

    def test_a_timeout_is_an_unknown_card_not_an_empty_one(self):
        card = self.gather(failing(subprocess.TimeoutExpired(cmd="df", timeout=2.0)))
        self.assertEqual("unknown", card["state"])
        self.assertEqual(EN["df_failed"], card["chip"])
        self.assertEqual([], validate_card(card))

    def test_a_nonzero_exit_is_unknown(self):
        self.assertEqual("unknown", self.gather(failing(OSError("df exited 1")))["state"])

    def test_a_missing_df_is_unknown(self):
        self.assertEqual("unknown",
                         self.gather(failing(FileNotFoundError("df")))["state"])

    def test_an_empty_answer_is_unknown_rather_than_a_machine_with_no_disks(self):
        card = self.gather(canned(HEADER + "\n"))
        self.assertEqual("unknown", card["state"])
        self.assertEqual([EN["no_disks"]], texts(card))

    def test_output_with_nothing_parsable_says_so_differently(self):
        card = self.gather(canned(HEADER + "\nnot a df line\n"))
        self.assertEqual("unknown", card["state"])
        self.assertEqual([], validate_card(card))

    def test_the_failure_card_is_still_a_valid_card(self):
        for reader in (failing(OSError("boom")), canned(""), canned("garbage")):
            self.assertEqual([], validate_card(self.gather(reader)))

    def test_failure_speaks_the_panel_s_language(self):
        card = self.gather(failing(OSError("boom")), words=RU)
        self.assertEqual(RU["df_failed"], card["chip"])


# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------

class SettingsTests(unittest.TestCase):

    def load(self, **env):
        warnings = []
        got = disk.load_settings(env=env, warn=warnings.append)
        return got, warnings

    def test_an_empty_environment_gives_the_manifest_defaults(self):
        got, warnings = self.load()
        self.assertEqual(settings(), got)
        self.assertEqual([], warnings)

    def test_an_int_is_read(self):
        got, _ = self.load(UDECK_SETTING_WARN_PERCENT="70")
        self.assertEqual(70, got["warn_percent"])

    def test_an_int_out_of_range_is_clamped_and_reported(self):
        got, warnings = self.load(UDECK_SETTING_WARN_PERCENT="5")
        self.assertEqual(50, got["warn_percent"])
        self.assertEqual(1, len(warnings))

    def test_a_bool_where_an_int_belongs_is_a_host_bug(self):
        got, warnings = self.load(UDECK_SETTING_WARN_PERCENT="true")
        self.assertEqual(85, got["warn_percent"])
        self.assertEqual(1, len(warnings))

    def test_a_bool_is_read(self):
        got, _ = self.load(UDECK_SETTING_HIDE_SYSTEM="false")
        self.assertFalse(got["hide_system"])

    def test_an_enum_member_is_read(self):
        got, _ = self.load(UDECK_SETTING_VOLUMES='"mounts"')
        self.assertEqual("mounts", got["volumes"])

    def test_an_unknown_enum_member_falls_back(self):
        got, warnings = self.load(UDECK_SETTING_VOLUMES='"everything"')
        self.assertEqual("physical", got["volumes"])
        self.assertEqual(1, len(warnings))

    def test_a_bare_string_is_accepted_for_string_settings(self):
        got, warnings = self.load(UDECK_SETTING_WATCH_PATH="/Volumes/Backup")
        self.assertEqual("/Volumes/Backup", got["watch_path"])
        self.assertEqual([], warnings)

    def test_a_bare_string_is_accepted_for_enums(self):
        got, warnings = self.load(UDECK_SETTING_VOLUMES="startup")
        self.assertEqual("startup", got["volumes"])
        self.assertEqual([], warnings)

    def test_unparsable_json_for_a_number_falls_back(self):
        got, warnings = self.load(UDECK_SETTING_CRIT_PERCENT="ninety")
        self.assertEqual(95, got["crit_percent"])
        self.assertEqual(1, len(warnings))

    def test_a_number_where_a_string_belongs_falls_back(self):
        got, warnings = self.load(UDECK_SETTING_WATCH_PATH="12")
        self.assertEqual("", got["watch_path"])
        self.assertEqual(1, len(warnings))

    def test_crit_below_warn_is_raised_to_meet_it(self):
        got, warnings = self.load(UDECK_SETTING_WARN_PERCENT="90",
                                  UDECK_SETTING_CRIT_PERCENT="60")
        self.assertEqual(90, got["crit_percent"])
        self.assertEqual(1, len(warnings))

    def test_thresholds_that_do_not_cross_are_left_alone(self):
        got, warnings = self.load(UDECK_SETTING_WARN_PERCENT="60",
                                  UDECK_SETTING_CRIT_PERCENT="90")
        self.assertEqual((60, 90), (got["warn_percent"], got["crit_percent"]))
        self.assertEqual([], warnings)


class ThresholdTests(unittest.TestCase):

    def disk_at(self, percent):
        return disk.Disk(key="d", name="d", used=percent, avail=100 - percent,
                         total=100, mount="/d", members=[])

    def test_below_the_warning_threshold_is_ok(self):
        self.assertEqual("ok", disk.state_of(self.disk_at(84), settings()))

    def test_the_warning_threshold_is_inclusive(self):
        self.assertEqual("warn", disk.state_of(self.disk_at(85), settings()))

    def test_the_critical_threshold_is_inclusive(self):
        self.assertEqual("crit", disk.state_of(self.disk_at(95), settings()))

    def test_a_full_disk_is_critical(self):
        self.assertEqual("crit", disk.state_of(self.disk_at(100), settings()))


# --------------------------------------------------------------------------
# The manifest, and the translation beside it
# --------------------------------------------------------------------------

class ManifestTests(unittest.TestCase):

    def setUp(self):
        self.manifest = read_json(MANIFEST)
        self.translation = read_json(TRANSLATION)

    def test_the_script_runs_what_the_manifest_declares(self):
        self.assertEqual(["./disk.py"], self.manifest["run"])
        self.assertTrue(os.access(SCRIPT, os.X_OK), "disk.py is not executable")

    def test_every_setting_in_the_manifest_is_in_the_code(self):
        declared = [item["key"] for item in self.manifest["settings"]]
        self.assertEqual(declared, [spec[0] for spec in disk.SETTING_SPECS])

    def test_defaults_agree_with_the_code(self):
        for item in self.manifest["settings"]:
            spec = [s for s in disk.SETTING_SPECS if s[0] == item["key"]][0]
            self.assertEqual(item["default"], spec[2], item["key"])

    def test_ranges_agree_with_the_code(self):
        for item in self.manifest["settings"]:
            if item["type"] != "int":
                continue
            spec = [s for s in disk.SETTING_SPECS if s[0] == item["key"]][0]
            self.assertEqual((item["min"], item["max"]), (spec[3], spec[4]), item["key"])

    def test_enum_options_agree_with_the_code(self):
        for item in self.manifest["settings"]:
            if item["type"] != "enum":
                continue
            spec = [s for s in disk.SETTING_SPECS if s[0] == item["key"]][0]
            self.assertEqual(tuple(o["value"] for o in item["options"]), spec[4])

    def test_the_permissions_are_the_two_commands_it_runs(self):
        self.assertEqual({"exec": ["df", "open"]}, self.manifest["permissions"])

    def test_the_translation_cannot_change_what_the_plugin_does(self):
        for forbidden in ("run", "permissions", "id", "interval", "timeout"):
            self.assertNotIn(forbidden, self.translation)

    def test_the_translation_renames_settings_it_did_not_invent(self):
        declared = {item["key"] for item in self.manifest["settings"]}
        self.assertTrue(set(self.translation["settings"]) <= declared)

    def test_the_translation_covers_every_setting(self):
        declared = {item["key"] for item in self.manifest["settings"]}
        self.assertEqual(declared, set(self.translation["settings"]))

    def test_translated_enum_options_match_by_value(self):
        for item in self.manifest["settings"]:
            if item["type"] != "enum":
                continue
            translated = self.translation["settings"][item["key"]]["options"]
            self.assertEqual({o["value"] for o in item["options"]}, set(translated))


# --------------------------------------------------------------------------
# End to end, against a df that is not this machine's
# --------------------------------------------------------------------------

class EndToEndTests(unittest.TestCase):

    def run_plugin(self, df_output="", exit_code=0, **env):
        """Run disk.py as the host would, with a fake df first on PATH."""
        with tempfile.TemporaryDirectory() as fake_bin:
            path = os.path.join(fake_bin, "df")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("#!/bin/sh\ncat <<'DF_EOF'\n%s\nDF_EOF\nexit %d\n"
                             % (df_output.rstrip("\n"), exit_code))
            os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)

            environment = dict(os.environ)
            environment["PATH"] = fake_bin + os.pathsep + environment.get("PATH", "")
            for key in list(environment):
                if key.startswith("UDECK_"):
                    del environment[key]
            environment.update(env)

            completed = subprocess.run(
                [sys.executable, SCRIPT],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=environment, timeout=20, check=False)
        return completed

    def test_the_plugin_prints_one_valid_card_and_exits_zero(self):
        completed = self.run_plugin(APPLE_SILICON)
        self.assertEqual(0, completed.returncode, completed.stderr)
        card = json.loads(completed.stdout.decode("utf-8"))
        self.assertEqual([], validate_card(card))
        self.assertEqual("ok", card["state"])

    def test_stdout_carries_the_card_and_nothing_else(self):
        completed = self.run_plugin(APPLE_SILICON)
        self.assertEqual(1, len(completed.stdout.decode("utf-8").strip().splitlines()))

    def test_settings_arrive_through_the_environment(self):
        completed = self.run_plugin(APPLE_SILICON, UDECK_SETTING_VOLUMES='"mounts"')
        card = json.loads(completed.stdout.decode("utf-8"))
        self.assertEqual(2, len(meters(card)))

    def test_the_language_arrives_through_the_environment(self):
        completed = self.run_plugin(APPLE_SILICON, UDECK_LANG="ru")
        card = json.loads(completed.stdout.decode("utf-8"))
        self.assertIn("свободно", card["chip"])

    def test_a_broken_setting_is_a_diagnostic_not_a_failure(self):
        completed = self.run_plugin(APPLE_SILICON, UDECK_SETTING_WARN_PERCENT="{{{")
        self.assertEqual(0, completed.returncode)
        card = json.loads(completed.stdout.decode("utf-8"))
        self.assertEqual([], validate_card(card))
        self.assertIn(b"warn_percent", completed.stderr)

    def test_a_df_that_fails_still_produces_a_card(self):
        completed = self.run_plugin("df: unavailable", exit_code=1)
        self.assertEqual(0, completed.returncode)
        card = json.loads(completed.stdout.decode("utf-8"))
        self.assertEqual("unknown", card["state"])
        self.assertEqual([], validate_card(card))

    def test_the_card_is_utf8_and_not_escaped(self):
        completed = self.run_plugin(APPLE_SILICON, UDECK_LANG="ru")
        self.assertIn("свободно", completed.stdout.decode("utf-8"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
