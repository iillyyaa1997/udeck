"""The golden image: what the lab remembers about it, and whether it is fit.

A golden image is a Cirrus Labs base image with the lab's settings baked in
once, so that every clone starts the same. It lives in Tart's own store, shared
by every checkout on this Mac, and a small JSON file beside the run lock says
what it was baked from. A golden image baked from another base image, or by an
older bake, is refused rather than silently used.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from udeck_e2e import config
from udeck_e2e.config import Guest
from udeck_e2e.preflight import Problem


def metadata_path(guest: Guest, state_dir: Path = config.STATE_DIR) -> Path:
    return state_dir / f"golden-{guest.key}.json"


def read(guest: Guest, state_dir: Path = config.STATE_DIR) -> dict[str, Any] | None:
    try:
        return json.loads(metadata_path(guest, state_dir).read_text())
    except (OSError, ValueError):
        return None


def write(guest: Guest, guest_build: str, state_dir: Path = config.STATE_DIR) -> None:
    path = metadata_path(guest, state_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "vm": guest.golden_vm,
        "base_image": guest.base_image,
        "bake_version": config.BAKE_VERSION,
        "display": config.GOLDEN_DISPLAY,
        "guest_build": guest_build,
        "baked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(record, indent=2) + "\n")
    temporary.replace(path)


def forget(guest: Guest, state_dir: Path = config.STATE_DIR) -> None:
    metadata_path(guest, state_dir).unlink(missing_ok=True)


def problem(guest: Guest, vm_names: list[str], state_dir: Path = config.STATE_DIR) -> Problem | None:
    bake = f"e2e/run.sh bake --guest {guest.key}"
    if guest.golden_vm not in vm_names:
        return Problem(
            f"There is no golden image for macOS {guest.key} yet.",
            f"Bake it once with '{bake}'. The first bake downloads the base image, about 33 GB.",
        )
    meta = read(guest, state_dir)
    if meta is None:
        return Problem(
            f"The golden image for macOS {guest.key} exists, but the lab has no record of "
            "how it was baked.",
            f"Bake it again with '{bake}'.",
        )
    if meta.get("base_image") != guest.base_image or meta.get("bake_version") != config.BAKE_VERSION:
        return Problem(
            f"The golden image for macOS {guest.key} was baked from "
            f"{meta.get('base_image')} by bake version {meta.get('bake_version')}; the lab now "
            f"pins {guest.base_image} and bake version {config.BAKE_VERSION}.",
            f"Bake it again with '{bake}'.",
        )
    return None
