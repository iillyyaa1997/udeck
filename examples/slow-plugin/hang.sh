#!/bin/sh
# Never answers. There is no `timeout` binary on a stock macOS, so a producer
# genuinely cannot police itself — the host has to. This plugin exists so that
# claim stays tested rather than assumed.
#
# It also ignores SIGTERM, to prove the host escalates to SIGKILL rather than
# leaving a wedged producer holding its slot forever.
trap '' TERM
while true; do sleep 3600; done
