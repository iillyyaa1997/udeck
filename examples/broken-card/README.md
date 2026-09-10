# Deliberately broken plugin

Prints something that is not a card.

```sh
cp -R examples/broken-card ~/.udeck/plugins/
```

## Why it exists

A producer's mistakes should be reported, not swallowed. The failure mode this
guards against is the quiet one: a card that shows nothing, or last hour's
values, with nothing anywhere saying why.

So this plugin prints a row carrying two row-type keys at once — `text` and
`kv` — which has no correct interpretation. uDeck says so, and names the row.

It also writes a line to standard error, because that is what a real producer
does with its diagnostics. Look at the plugin in the settings screen and you
will find it kept there, next to the plugin that wrote it.

## What you should see

| | |
|---|---|
| On the card | the parse error, naming the field that would not parse |
| In the plugin's diagnostics | `this is what a producer's diagnostics look like` |

Stdout carries the card and nothing else. Everything you want to say to a human
goes to stderr — it is where a producer explains itself, and using it costs
nothing.
