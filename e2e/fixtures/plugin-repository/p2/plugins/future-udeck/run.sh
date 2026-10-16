#!/bin/sh
# A lab fixture: never installed, so never run. It exists because a manifest
# whose run[0] is missing would be refused for that instead of for what the
# fixture is about.
printf '{ "rows": [ { "text": "a lab fixture" } ] }\n'
