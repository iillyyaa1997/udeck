#!/bin/sh
# The lab's Hold, as the official uptime has one: a card action that runs until it is ended.
trap 'exit 0' TERM INT
while :; do sleep 1; done
