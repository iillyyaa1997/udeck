#!/bin/sh
# Makes a plugin that works, in the place uDeck looks for one.
#
# The point is not to save typing — a manifest is twenty lines. It is that the
# first plugin somebody writes should *run* before they change anything, so that
# when it stops working they know which of their own edits did it.
#
# Usage: Scripts/new-plugin.sh <id> [directory]
#
#   id         lowercase letters, digits and - _ . — and the folder is named
#              after it, because uDeck requires the two to match
#   directory  where to put it; defaults to ~/.udeck/plugins, or $UDECK_HOME/plugins

set -eu

id=${1:-}
if [ -z "$id" ]; then
    echo "usage: $0 <id> [directory]" >&2
    echo "  e.g. $0 my-first-plugin" >&2
    exit 2
fi

# The same rule the host applies, so a name it would refuse is refused here
# rather than three steps later with a message about a folder.
case "$id" in
    *[!a-z0-9._-]*)
        echo "$0: an id may hold lowercase letters, digits and - _ . — got '$id'" >&2
        exit 2
        ;;
esac

home=${UDECK_HOME:-$HOME/.udeck}
root=${2:-$home/plugins}
directory="$root/$id"

if [ -e "$directory" ]; then
    echo "$0: $directory already exists — pick another id, or delete it first" >&2
    exit 1
fi

mkdir -p "$directory"

cat > "$directory/manifest.json" <<JSON
{
  "id": "$id",
  "name": "$id",
  "version": "0.1.0",
  "api": 1,
  "kind": "poll",
  "description": "Says hello. Replace this with what your plugin actually does.",
  "author": "$(id -F 2>/dev/null || whoami)",
  "run": ["./run.sh"],
  "interval": 5,
  "timeout": 2,
  "settings": [
    {
      "key": "greeting",
      "type": "string",
      "default": "Hello",
      "label": "Greeting",
      "help": "The word the card opens with."
    }
  ],
  "window": { "defaultWidth": 4, "defaultHeight": 3, "minWidth": 3, "minHeight": 2 }
}
JSON

cat > "$directory/run.sh" <<'SCRIPT'
#!/bin/sh
# A uDeck producer: print one JSON object on stdout and exit.
#
# Everything else you print — diagnostics, warnings, the reason a source could
# not be read — goes to stderr, where uDeck keeps it and shows it next to your
# plugin. Use it freely: it is where a producer explains itself.

# Settings arrive as environment variables holding JSON, so a string arrives
# quoted. Strip the quotes rather than assuming they are not there.
greeting=$(printf '%s' "${UDECK_SETTING_GREETING:-\"Hello\"}" | sed 's/^"//; s/"$//')

# UDECK_LANG is the language the panel is speaking. Answer in it if you can and
# fall back to what you write in if you cannot. Not LANG: that is pinned to a
# UTF-8 locale so printing non-Latin text works at all, and does not follow the
# setting.
case "${UDECK_LANG:-en}" in
    ru) subject="мир" ;;
    *)  subject="world" ;;
esac

cat <<JSON
{
  "state": "ok",
  "chip": "example",
  "rows": [
    { "text": "$greeting, $subject." },
    { "kv": ["refreshed because", "${UDECK_REFRESH_REASON:-unknown}"] }
  ],
  "ttl": 30
}
JSON
SCRIPT

chmod +x "$directory/run.sh"

cat > "$directory/README.md" <<MARKDOWN
# $id

What this plugin answers, in one sentence.

## Try it

    $directory/run.sh | python3 -m json.tool

## What it reads

Nothing yet. When it starts reading something, say what — and declare it under
\`permissions\` in the manifest, because uDeck will not run a plugin whose
manifest does not ask for what it uses.
MARKDOWN

printf 'made %s\n\n' "$directory"
printf 'run it the way uDeck will:\n\n    %s/run.sh | python3 -m json.tool\n\n' "$directory"
printf 'then open the panel and add it to a tab. uDeck watches this folder, so\n'
printf 'it is already in the list — nothing to press.\n'
