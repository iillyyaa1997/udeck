#!/bin/bash
#
# The end-to-end lab, as one command.
#
# Usage:  e2e/run.sh [CHECK-OR-GROUP ...] [--list] [--guest 27|26]
#
# Everything the lab does — the pre-flight, the virtual machines, the checks and
# the report — lives in the Python package beside this file. This wrapper only
# finds uv and hands over, because the things a harness has to get right
# (deadlines on every call, cleanup on Ctrl-C, parallel machines) are exactly
# where bash 3.2, the bash every Mac ships, is weakest.

set -eu

# CDPATH cleared: with it exported, `cd` prints the directory it chose and ROOT
# would hold that line twice.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"

if ! command -v uv >/dev/null 2>&1; then
    echo "uv is not installed, and the lab runs its Python through it." >&2
    echo "Install it with 'brew install uv', or see https://docs.astral.sh/uv/." >&2
    exit 2
fi

# The lab's Python environment lives under .build/, which git already ignores,
# so running the lab adds nothing to the working tree.
export UV_PROJECT_ENVIRONMENT="$ROOT/.build/e2e/venv"
uv sync --quiet --frozen --project "$ROOT/e2e"

# The lab runs as this shell's own process, not under `uv run`. uv forwards
# Ctrl-C to its child, which then receives it twice — once from the terminal,
# once from uv — and the second one cut short the cleanup the first one had
# started, leaving a clone behind (measured).
exec "$UV_PROJECT_ENVIRONMENT/bin/udeck-e2e" "$@"
