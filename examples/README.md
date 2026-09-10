# Example plugins

Four plugins, and they are also uDeck's own test fixtures — the ones shipped as
documentation are the ones the tests run, so an example that stops working stops
CI.

| | What it is for | Read it when |
|---|---|---|
| [`hello-card`](hello-card) | Every row type, no permissions, twenty lines of `sh` | You want to see what a producer has to do |
| [`disk-space`](disk-space) | A real plugin: four setting types, permissions, two languages, its own 115 tests | You are writing one properly |
| [`slow-plugin`](slow-plugin) | Hangs on purpose and ignores `SIGTERM` | You want to see what a deadline looks like from the operator's side |
| [`broken-card`](broken-card) | Prints something that is not a card | Same, for a mistake in the output |

Each has a README saying what it demonstrates and what you should see when you
add it to a tab. Every one carries a `manifest.ru.json`, because a plugin that
speaks one language is a plugin that has not exercised the half of the contract
that translates it.

## Install any of them

```sh
cp -R examples/hello-card ~/.udeck/plugins/
```

The folder is watched: it appears in the panel by itself, with nothing to press.

## Write your own

```sh
Scripts/new-plugin.sh my-first-plugin
```

Then follow [Writing a plugin](../docs/writing-a-plugin.md).
