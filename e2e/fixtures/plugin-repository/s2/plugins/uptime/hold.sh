#!/bin/sh
# The lab's card action, which the official plugin does not have: it holds on
# until it is ended, and writes down what it saw of its own folder meanwhile,
# so that a check can tell an update that ended it before swapping the folder
# from one that swapped the folder under it (plugins.an-update-ends-a-running-action).
#
# It runs in the guest only, and reads nothing but its own manifest.

log=/tmp/udeck-e2e-hold.log
manifest="$HOME/.udeck/plugins/uptime/manifest.json"
mine=$(cat "$manifest")
trap 'echo "ended $(date +%s)" >> "$log"; exit 0' TERM
echo "started $$ $(date +%s)" >> "$log"
while :; do
  if [ "$(cat "$manifest" 2>/dev/null)" != "$mine" ]; then
    echo "changed under it $(date +%s)" >> "$log"
  fi
  sleep 0.2
done
