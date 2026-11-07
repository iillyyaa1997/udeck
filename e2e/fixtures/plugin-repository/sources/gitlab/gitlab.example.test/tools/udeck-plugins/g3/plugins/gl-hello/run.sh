#!/bin/sh
# A lab fixture: gl-hello 1.1.0 from the lab's GitLab project tools/udeck-plugins. Its card says how many times it ran
# since it was installed, kept where the contract says a plugin keeps what it writes, its version, and where it
# came from.
count_file="${UDECK_CACHE_DIR:-/tmp}/runs"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$count" > "$count_file"
printf '{ "rows": [ { "kv": ["runs since install", "%s"] }, { "kv": ["version", "1.1.0"] }, { "kv": ["from", "tools/udeck-plugins"] } ] }\n' "$count"
