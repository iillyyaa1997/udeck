#!/bin/sh
# A lab fixture: team-clock 9.0.0 from the lab's the repository at the old name, a repository of its own that is no fork of the
# official one. Its card says how many times it ran since it was installed, kept where the contract says a
# plugin keeps what it writes, its version, and where it came from.
count_file="${UDECK_CACHE_DIR:-/tmp}/runs"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$count" > "$count_file"
printf '{ "rows": [ { "kv": ["runs since install", "%s"] }, { "kv": ["version", "9.0.0"] }, { "kv": ["from", "the repository at the old name"] } ] }\n' "$count"
