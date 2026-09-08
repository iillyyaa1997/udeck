#!/bin/sh
# The smallest useful uDeck plugin: it prints one card and exits.
#
# A plugin needs no permissions to exist. This one reads nothing and runs
# nothing, so its manifest declares no permissions and uDeck never asks the
# operator about it.
#
# Settings arrive as environment variables holding JSON. `greeting` is a string,
# so its value arrives quoted — strip the quotes rather than assuming.

greeting=$(printf '%s' "${UDECK_SETTING_GREETING:-\"Hello\"}" | sed 's/^"//; s/"$//')
show_table=${UDECK_SETTING_SHOW_TABLE:-true}

table_row=''
if [ "$show_table" = "true" ]; then
  table_row=',
    { "table": { "columns": [ {"title": "row type"}, {"title": "count", "align": "trailing"} ],
                 "rows": [ ["declared", "8"], ["drawn here", "7"] ] } }'
fi

cat <<JSON
{
  "state": "ok",
  "chip": "example",
  "rows": [
    { "text": "$greeting from a shell script." },
    { "kv": ["appearance", "${UDECK_APPEARANCE:-unknown}"] },
    { "kv": ["refreshed because", "${UDECK_REFRESH_REASON:-unknown}", "ok"] },
    { "meter": { "value": 0.42, "label": "an example meter", "caption": "42%" } },
    { "list": [
        { "text": "a list row", "note": "with a note", "icon": "ok" },
        { "text": "another", "note": "warn tint", "icon": "warn", "state": "warn" }
      ] },
    { "spark": [3, 7, 4, 9, 6, 11, 8] },
    { "log": ["a log row", "and an older one"] }$table_row
  ],
  "ttl": 30
}
JSON
