#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""uDeck poll plugin: how much room is left on this machine's disks.

One external call, ``df -P -k -l``, and the whole of the plugin is what you
have to do to that output before a number on it means anything.

**A df line is not a disk.**  A modern Mac splits its startup disk into an
APFS container holding five or six volumes — the sealed system volume mounted
at ``/``, the Data volume at ``/System/Volumes/Data``, and Preboot, Recovery,
VM and friends.  They share one pool of free space and every one of them
reports that whole pool as its own ``Available``.  Listing them as five rows
shows the same 657 GB five times; summing their ``Available`` claims three
terabytes on a one-terabyte disk.  So the default view groups volumes by the
container their device belongs to (``/dev/disk3s5`` -> ``disk3``), sums the
*used* space, which really is per-volume, and takes the *smallest* reported
free space, which is the only figure in the group that cannot be an overstatement.

**Fullness is measured against what the disk can still hold.**  The percentage
is ``used / (used + free)`` and not ``used / total``: on APFS the container's
total is inflated by accounting the operator will never see as usable, and a
card that says "68 % full" while the Finder says "657 GB available" has told
them nothing they can act on.

**Network volumes are deliberately not listed.**  ``df`` on a dead network
mount blocks until the mount times out, which may be never, and the plugin
contract is explicit about not calling anything that can hang.  ``-l`` keeps
the call local, and the README says so where somebody looking for their NAS
will find it.

Output: exactly one JSON object on stdout.  Everything else goes to stderr.
Target runtime: macOS system python3 (3.9) and newer, standard library only.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import traceback

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------
DF_TIMEOUT_SECS = 2.0     # bounds the one external call; see run_df()
DF_MAX_BYTES = 262144     # df output is a few kB; a runaway one is not read
CARD_TTL_SECS = 120       # four poll intervals, as the manifest's interval is 30
MAX_METER_ROWS = 6        # beyond this the card says "+N more" instead
MAX_NAME_CHARS = 40       # clamp, not a display choice: the host truncates too

# ``df -P`` output, POSIX format.  Both the filesystem name and the mount point
# may contain spaces ("map auto_home", "/Volumes/Time Machine"), so the four
# numeric columns and the percent sign are what the line is anchored on rather
# than a field count.
RE_DF_LINE = re.compile(
    r"^(?P<fs>.*?)\s+(?P<blocks>\d+)\s+(?P<used>\d+)\s+(?P<avail>\d+)\s+"
    r"(?P<capacity>\d+)%\s+(?P<mount>.+?)\s*$"
)

RE_DF_HEADER = re.compile(r"^\s*Filesystem\s")

# /dev/disk3s1s1 and /dev/disk3s5 are two volumes of one container, disk3.
# A whole-device node (/dev/disk4) is its own container.
RE_DEVICE = re.compile(r"^/dev/(disk\d+)")

# The volumes macOS keeps for itself.  Real, and never anything the operator
# can act on.  /System/Volumes/Data is the exception: that is where their files
# actually live.
SYSTEM_MOUNT_PREFIX = "/System/Volumes/"
DATA_MOUNT = "/System/Volumes/Data"

KIB = 1024


# --------------------------------------------------------------------------
# Language
# --------------------------------------------------------------------------

# UDECK_LANG is the language the panel is speaking, and it is the variable to
# read: LANG and LC_ALL are pinned to a UTF-8 locale so that printing non-Latin
# text works at all, and they do not follow the setting.  A plugin that ignores
# it is perfectly correct, just monolingual.
PHRASES = {
    "en": {
        "startup": "Startup disk",
        "free": "%s free",
        "full": "%s %d %% full",
        "of": "%s free of %s",
        "more": "+%d more",
        "hidden": "%d system volume(s) hidden",
        "no_disks": "No local disks were reported.",
        "df_failed": "df is not answering",
        "df_unreadable": "df answered, but nothing in it parsed as a disk",
        "unreadable_lines": "unreadable lines",
        "open": "Open %s",
        "plugin_error": "plugin error",
        "plugin_error_body": "The plugin failed to read its sources.",
        "units": ("B", "kB", "MB", "GB", "TB", "PB"),
    },
    "ru": {
        "startup": "Системный диск",
        "free": "%s свободно",
        "full": "%s занят на %d %%",
        "of": "%s свободно из %s",
        "more": "ещё %d",
        "hidden": "служебных томов скрыто: %d",
        "no_disks": "Локальных дисков не найдено.",
        "df_failed": "df не отвечает",
        "df_unreadable": "df ответил, но диском ничего из ответа не оказалось",
        "unreadable_lines": "нечитаемых строк",
        "open": "Открыть %s",
        "plugin_error": "ошибка плагина",
        "plugin_error_body": "Плагин не смог прочитать свои источники.",
        "units": ("Б", "кБ", "МБ", "ГБ", "ТБ", "ПБ"),
    },
}


def phrases(env=None):
    """The phrase table for the language the panel is speaking.

    An unknown or absent code falls back to English rather than failing: a
    plugin that will not run because it does not speak Japanese is worse than
    one that answers in English.
    """
    if env is None:
        env = os.environ
    code = (env.get("UDECK_LANG") or "en").strip().lower()
    # "pt-BR" and "pt_BR" both mean the base language as far as this plugin is
    # concerned; it has no regional variants to choose between.
    base = re.split(r"[-_]", code)[0]
    return PHRASES.get(base, PHRASES["en"])


def human_bytes(kib, words):
    """Format a count of 1024-byte blocks the way the Finder would show it.

    ``df -k`` counts in KiB; the operator's disk is sold and displayed in
    decimal gigabytes.  Reporting 611 GiB for the disk their Mac calls 657 GB
    would be defensible and useless — the number has to match the one they can
    check.
    """
    value = float(kib) * KIB
    for index, unit in enumerate(words):
        if value < 1000 or index == len(words) - 1:
            if index == 0 or value >= 100:
                return "%d %s" % (round(value), unit)
            return ("%.1f %s" % (value, unit)).replace(".0 ", " ")
        value /= 1000.0
    return "%d %s" % (round(value), words[-1])


# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------

# Mirrors manifest.json.  Kept here as the single runtime source of truth so a
# missing or malformed environment variable falls back to the documented
# default instead of crashing.  Order is the manifest order.
SETTING_SPECS = (
    ("warn_percent", "int", 85, 50, 99),
    ("crit_percent", "int", 95, 51, 100),
    ("volumes", "enum", "physical", None, ("physical", "mounts", "startup")),
    ("hide_system", "bool", True, None, None),
    ("watch_path", "string", "", None, None),
)


def load_settings(env=None, warn=None):
    """Read UDECK_SETTING_* out of the environment into a plain dict.

    Every value arrives JSON-serialised.  A missing variable, a value that is
    not JSON, a value of the wrong type, an out-of-range int or an unknown enum
    member all fall back to the manifest default and are reported through
    ``warn`` — never raised.
    """
    if env is None:
        env = os.environ
    if warn is None:
        def warn(_message):
            return None

    out = {}
    for key, kind, default, lo, hi in SETTING_SPECS:
        out[key] = default
        raw = env.get("UDECK_SETTING_" + key.upper())
        if raw is None:
            continue

        try:
            value = json.loads(raw)
        except (ValueError, TypeError):
            # A host that forwards a bare string rather than a JSON string is
            # still unambiguous for string/enum settings; anything else is not.
            if kind in ("string", "enum"):
                value = raw
            else:
                warn("setting %s: %r is not JSON, using default %r" % (key, raw, default))
                continue

        if kind == "bool":
            if isinstance(value, bool):
                out[key] = value
            else:
                warn("setting %s: expected a bool, got %r; using %r" % (key, value, default))
        elif kind == "int":
            # bool is a subclass of int; a bool here is a host bug, not an int.
            if isinstance(value, int) and not isinstance(value, bool):
                clamped = min(hi, max(lo, value))
                if clamped != value:
                    warn("setting %s: %d out of range [%d, %d], clamped to %d"
                         % (key, value, lo, hi, clamped))
                out[key] = clamped
            else:
                warn("setting %s: expected an int, got %r; using %r" % (key, value, default))
        elif kind == "enum":
            if isinstance(value, str) and value in hi:
                out[key] = value
            else:
                warn("setting %s: %r is not one of %s; using %r"
                     % (key, value, ", ".join(hi), default))
        else:  # string
            if isinstance(value, str):
                out[key] = value
            else:
                warn("setting %s: expected a string, got %r; using %r"
                     % (key, value, default))

    # Two thresholds that cross each other are a setting mistake, not a state
    # the card can render: red below amber would mean a disk goes critical on
    # its way to being merely full.
    if out["crit_percent"] < out["warn_percent"]:
        warn("crit_percent %d is below warn_percent %d; raising it to match"
             % (out["crit_percent"], out["warn_percent"]))
        out["crit_percent"] = out["warn_percent"]
    return out


# --------------------------------------------------------------------------
# Problems
# --------------------------------------------------------------------------

class Problems:
    """Accumulates why the card is less complete than it should be.

    Losing ``df`` altogether is fatal — the card goes ``unknown`` rather than
    reporting a number it cannot stand behind.  A single line of its output
    that will not parse is not: it is counted, mentioned, and the rest of the
    card stands.
    """

    def __init__(self):
        self.fatal = []        # human-readable reasons the numbers are unusable
        self.line_errors = 0   # df lines that did not parse
        self.notes = []        # degradations that do not invalidate the numbers

    def add_fatal(self, reason):
        if reason not in self.fatal:
            self.fatal.append(reason)

    def add_note(self, note):
        if note not in self.notes:
            self.notes.append(note)


# --------------------------------------------------------------------------
# Reading df
# --------------------------------------------------------------------------

def run_df(timeout=DF_TIMEOUT_SECS):
    """Return df's stdout, or raise.

    ``-P`` asks for the POSIX output format, which is the only one whose column
    order is promised.  ``-k`` fixes the block size at 1024 bytes so the numbers
    do not follow BLOCKSIZE out of the operator's shell profile.  ``-l`` keeps
    the call to local filesystems: a network mount whose server has gone away
    makes df block until the mount times out, and this runs every thirty
    seconds.

    The timeout is the point.  uDeck kills a producer that overruns its own
    deadline, but a producer that leaves a wedged df behind on every run is
    fighting the runtime rather than using it.
    """
    completed = subprocess.run(
        ["df", "-P", "-k", "-l"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip().splitlines()
        raise OSError("df exited %d%s" % (
            completed.returncode, (": " + detail[0]) if detail else ""))
    return completed.stdout[:DF_MAX_BYTES].decode("utf-8", "replace")


class Volume(object):
    """One line of df: one mounted filesystem."""

    __slots__ = ("device", "mount", "blocks", "used", "avail")

    def __init__(self, device, mount, blocks, used, avail):
        self.device = device
        self.mount = mount
        self.blocks = blocks
        self.used = used
        self.avail = avail

    @property
    def container(self):
        """The disk this volume lives on, or the device itself when unknown."""
        match = RE_DEVICE.match(self.device)
        return match.group(1) if match else self.device

    @property
    def is_system(self):
        return self.mount.startswith(SYSTEM_MOUNT_PREFIX) and self.mount != DATA_MOUNT


def parse_df(text, problems):
    """Turn df output into volumes, skipping what is not a disk.

    Pseudo-filesystems — ``devfs``, ``map auto_home`` — are mounted, are listed
    by df, and hold nothing.  They are dropped rather than counted as disks
    with no space left, which is what a naive reading of ``100 %`` would make
    of them.
    """
    volumes = []
    for line in text.splitlines():
        if not line.strip():
            continue
        if RE_DF_HEADER.match(line):
            # Recognised by its content rather than by being the first line: a
            # blank line ahead of it would otherwise push it into the count of
            # output that did not parse, and report a healthy machine as one
            # whose df is half unreadable.
            continue
        match = RE_DF_LINE.match(line)
        if not match:
            problems.line_errors += 1
            continue
        device = match.group("fs").strip()
        if not device.startswith("/dev/"):
            continue
        blocks = int(match.group("blocks"))
        if blocks <= 0:
            continue
        volumes.append(Volume(
            device=device,
            mount=match.group("mount"),
            blocks=blocks,
            used=int(match.group("used")),
            avail=int(match.group("avail")),
        ))
    return volumes


# --------------------------------------------------------------------------
# From volumes to disks
# --------------------------------------------------------------------------

class Disk(object):
    """A container's worth of volumes, added up the way they can be added up."""

    __slots__ = ("key", "name", "used", "avail", "total", "mount", "members")

    def __init__(self, key, name, used, avail, total, mount, members):
        self.key = key
        self.name = name
        self.used = used
        self.avail = avail
        self.total = total
        self.mount = mount
        self.members = members

    @property
    def capacity(self):
        """What the disk can hold from here: what is on it plus what is left.

        Not ``total``.  On APFS the container's block count is shared by every
        volume in it and exceeds what the operator will ever be able to use, so
        a percentage taken against it reads lower than the truth by however
        much of the disk is spoken for and invisible.
        """
        return self.used + self.avail

    @property
    def percent_used(self):
        if self.capacity <= 0:
            return 0
        return int(round(100.0 * self.used / self.capacity))


def disk_name(mounts, words):
    """Name a disk after the friendliest of its mount points.

    Preference order: a mount that is neither ``/`` nor one of the system's own
    volumes (an external disk at ``/Volumes/Backup`` is called Backup), then
    ``/`` itself, which gets a written name because "/" tells the operator
    nothing about which disk it is.
    """
    ordinary = [m for m in mounts
                if m != "/" and not m.startswith(SYSTEM_MOUNT_PREFIX)]
    if ordinary:
        shortest = sorted(ordinary, key=lambda m: (len(m), m))[0]
        return (os.path.basename(shortest.rstrip("/")) or shortest)[:MAX_NAME_CHARS]
    if "/" in mounts:
        return words["startup"]
    shortest = sorted(mounts, key=lambda m: (len(m), m))[0]
    return (os.path.basename(shortest.rstrip("/")) or shortest)[:MAX_NAME_CHARS]


def group_into_disks(volumes, words, hide_system=True):
    """Collapse volumes onto the disks they share.

    ``used`` is summed: every volume's own usage is genuinely its own.
    ``avail`` is the *minimum* across the group, because every volume in an
    APFS container reports the container's whole free pool and taking any other
    figure would mean claiming free space that is not there twice over.

    A container holding nothing *but* system volumes is dropped when they are
    hidden.  A Mac with a T2 or Apple silicon has a second, half-gigabyte
    container carrying iSCPreboot, xarts and Hardware and nothing else; it is
    separate storage, so dropping it loses none of the operator's space, and
    keeping it puts a row called "xarts" on the card that no answer to "what is
    that?" makes useful.  A container that also holds their files still counts
    its system volumes, because those take real space on the disk being
    measured.
    """
    order = []
    groups = {}
    for volume in volumes:
        key = volume.container
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(volume)

    disks = []
    for key in order:
        members = groups[key]
        if hide_system and all(member.is_system for member in members):
            continue
        mounts = [member.mount for member in members]
        disks.append(Disk(
            key=key,
            name=disk_name(mounts, words),
            used=sum(member.used for member in members),
            avail=min(member.avail for member in members),
            total=max(member.blocks for member in members),
            mount=preferred_mount(mounts),
            members=members,
        ))
    return disks


def preferred_mount(mounts):
    """The mount point to hand to the Open action.

    The same preference as the name, for the same reason: opening
    ``/System/Volumes/Preboot`` because it sorted first would be a button that
    technically works and answers nobody's question.
    """
    ordinary = [m for m in mounts
                if m != "/" and not m.startswith(SYSTEM_MOUNT_PREFIX)]
    if ordinary:
        return sorted(ordinary, key=lambda m: (len(m), m))[0]
    if DATA_MOUNT in mounts:
        # The startup disk's files live on the Data volume; "/" is the sealed
        # system volume and opening it shows a read-only skeleton.
        return DATA_MOUNT
    return sorted(mounts, key=lambda m: (len(m), m))[0]


def volumes_as_disks(volumes, words, hide_system):
    """One row per mounted volume, for the operator who asked for that."""
    disks = []
    for volume in volumes:
        if hide_system and volume.is_system:
            continue
        name = os.path.basename(volume.mount.rstrip("/")) or (
            words["startup"] if volume.mount == "/" else volume.mount)
        disks.append(Disk(
            key=volume.mount,
            name=name[:MAX_NAME_CHARS],
            used=volume.used,
            avail=volume.avail,
            total=volume.blocks,
            mount=volume.mount,
            members=[volume],
        ))
    return disks


def owning_disk(disks, path):
    """The disk whose mount point is the longest prefix of ``path``.

    Longest wins: ``/`` is a prefix of every path on the machine, so the first
    match would always be the startup disk and an external drive could never be
    watched.
    """
    if not path:
        return None
    target = os.path.abspath(os.path.expanduser(os.path.expandvars(path)))
    best = None
    for disk in disks:
        for member in disk.members:
            mount = member.mount
            if target == mount or target.startswith(mount.rstrip("/") + "/"):
                if best is None or len(mount) > best[0]:
                    best = (len(mount), disk)
    return best[1] if best else None


def state_of(disk, settings):
    if disk.percent_used >= settings["crit_percent"]:
        return "crit"
    if disk.percent_used >= settings["warn_percent"]:
        return "warn"
    return "ok"


WORST = {"ok": 0, "warn": 1, "crit": 2, "unknown": 3}


# --------------------------------------------------------------------------
# The card
# --------------------------------------------------------------------------

def build_card(settings, volumes, problems, words):
    if problems.fatal:
        rows = [{"text": reason} for reason in problems.fatal[:2]]
        return {
            "state": "unknown",
            "chip": words["df_failed"],
            "rows": rows,
            "ttl": CARD_TTL_SECS,
        }

    if settings["volumes"] == "mounts":
        disks = volumes_as_disks(volumes, words, settings["hide_system"])
        hidden = sum(1 for volume in volumes
                     if settings["hide_system"] and volume.is_system)
    else:
        disks = group_into_disks(volumes, words, settings["hide_system"])
        hidden = 0
        if settings["volumes"] == "startup":
            startup = owning_disk(disks, "/")
            disks = [startup] if startup else []

    watched = owning_disk(disks, settings["watch_path"])
    if watched is not None:
        disks = [watched] + [disk for disk in disks if disk is not watched]

    if not disks:
        return {
            "state": "unknown",
            "chip": words["df_unreadable"] if volumes else words["df_failed"],
            "rows": [{"text": words["no_disks"]}],
            "ttl": CARD_TTL_SECS,
        }

    state = "ok"
    rows = []
    for disk in disks[:MAX_METER_ROWS]:
        disk_state = state_of(disk, settings)
        if WORST[disk_state] > WORST[state]:
            state = disk_state
        rows.append({"meter": {
            "value": min(1.0, max(0.0, disk.used / float(disk.capacity or 1))),
            "label": disk.name,
            "caption": words["of"] % (human_bytes(disk.avail, words["units"]),
                                      human_bytes(disk.capacity, words["units"])),
            "state": disk_state,
        }})
    # A disk past the cap still decides the card's colour: hiding a full disk
    # because it sorted seventh would be the one failure this card exists to
    # prevent.
    for disk in disks[MAX_METER_ROWS:]:
        disk_state = state_of(disk, settings)
        if WORST[disk_state] > WORST[state]:
            state = disk_state
    if len(disks) > MAX_METER_ROWS:
        rows.append({"text": words["more"] % (len(disks) - MAX_METER_ROWS)})

    if hidden:
        rows.append({"text": words["hidden"] % hidden})
    if problems.line_errors:
        rows.append({"kv": [words["unreadable_lines"],
                            str(problems.line_errors), "warn"]})
    for note in problems.notes[:2]:
        rows.append({"text": note})

    headline = disks[0]
    if state == "ok":
        chip = words["free"] % human_bytes(headline.avail, words["units"])
    else:
        # Amber and red are about a specific disk, so the chip names it: "85 %
        # full" without a name is unreadable on a machine with three disks.
        fullest = max(disks, key=lambda disk: disk.percent_used)
        chip = words["full"] % (fullest.name, fullest.percent_used)

    card = {"state": state, "chip": chip, "rows": rows, "ttl": CARD_TTL_SECS}
    card["actions"] = [{
        "label": words["open"] % headline.name,
        "run": ["open", headline.mount],
    }]
    return card


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def log(message):
    """Diagnostics go to stderr; stdout carries the card and nothing else."""
    sys.stderr.write("disk-space: %s\n" % message)


def gather(settings, words, df_reader=run_df):
    problems = Problems()
    volumes = []
    try:
        volumes = parse_df(df_reader(), problems)
    except subprocess.TimeoutExpired:
        log("df timed out after %.1fs" % DF_TIMEOUT_SECS)
        problems.add_fatal(words["df_failed"])
    except (OSError, subprocess.SubprocessError) as exc:
        log("df failed: %s" % exc)
        problems.add_fatal(words["df_failed"])
    return build_card(settings, volumes, problems, words)


def main():
    words = phrases()
    warnings = []
    try:
        settings = load_settings(warn=warnings.append)
        for warning in warnings:
            log(warning)
        card = gather(settings, words)
    except Exception as exc:  # noqa: BLE001 - last resort; the host needs a card
        traceback.print_exc(file=sys.stderr)
        card = {
            "state": "unknown",
            "chip": words["plugin_error"],
            "rows": [
                {"text": words["plugin_error_body"]},
                {"text": "%s: %s" % (type(exc).__name__, exc)},
            ],
            "ttl": CARD_TTL_SECS,
        }

    try:
        sys.stdout.reconfigure(encoding="utf-8")
        text = json.dumps(card, ensure_ascii=False)
    except Exception:  # noqa: BLE001 - fall back to a pure-ASCII payload
        text = json.dumps(card, ensure_ascii=True)
    sys.stdout.write(text)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
