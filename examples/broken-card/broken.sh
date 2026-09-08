#!/bin/sh
# Prints a row with two type keys, which has no correct interpretation, and
# writes a note to stderr the way a real producer should.
echo "this is what a producer's diagnostics look like" >&2
cat <<'JSON'
{ "state": "ok", "rows": [ { "text": "one", "kv": ["two", "three"] } ] }
JSON
