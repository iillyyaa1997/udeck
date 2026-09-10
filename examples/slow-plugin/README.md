# Deliberately slow plugin

Hangs on purpose, and ignores `SIGTERM` while doing it.

```sh
cp -R examples/slow-plugin ~/.udeck/plugins/
```

## Why it exists

A stock macOS has neither `timeout` nor `gtimeout`, so a shell producer
genuinely cannot police its own deadline. The host has to — and a claim like
that decays into an assumption unless something keeps testing it.

So this plugin never answers. Add it to a tab and watch what happens: after one
second the card says the producer did not answer and was stopped, and it keeps
saying so on every interval rather than freezing on a stale value with no
explanation.

It also traps `SIGTERM` and does nothing about it, which proves the second half:
the host escalates to `SIGKILL` rather than leaving a wedged producer holding
its slot. Since every run gets a process group of its own, the escalation
reaches whatever the producer started as well.

## What you should see

| | |
|---|---|
| After ~1 s | `the producer did not answer within 1s and was stopped` |
| After a few failures | the interval stretches — doubling, capped at a minute |
| Press ⟳ | it runs immediately; the backoff does not apply to a manual refresh |

If you see anything else, that is a bug in uDeck and this plugin has just done
its job.
