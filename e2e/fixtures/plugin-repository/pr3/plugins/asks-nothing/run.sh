#!/bin/sh
# A lab fixture: a plugin that asks for no permission, added by pull request #3
# of the lab's repository. Code nobody verified, so uDeck asks before it runs it
# even so. Its card says how many times it has run, kept where the contract
# says a plugin keeps what it writes.
count_file="${UDECK_CACHE_DIR:-/tmp}/runs"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$count" > "$count_file"
printf '{ "title": "Asks nothing", "rows": [ { "text": "ran %s times" } ] }\n' "$count"
