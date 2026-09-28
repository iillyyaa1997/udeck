# Hello card

The smallest working plugin, and the one to read first: one card, every row
type, no permissions.

```sh
cp -R examples/hello-card ~/.udeck/plugins/
```

It is twenty lines of `sh`, so it is also the shortest answer to "what does a
producer actually have to do?" — print one JSON object on stdout and exit.

## What it shows

Every row type the contract defines, in one card, so you can see what each looks
like before deciding which one your data wants:

`text` · `kv` · `meter` · `list` · `spark` · `log` · `table`

Plus the three things the host tells a producer about itself:
`UDECK_APPEARANCE`, `UDECK_REFRESH_REASON`, and `UDECK_LANG` — which it reads,
so the card is in English or Russian depending on what the panel is speaking.

## Settings

| Key | Type | Default | What it does |
|---|---|---|---|
| `greeting` | string | `Hello` | The word the card opens with |
| `show_table` | bool | `true` | Whether the example table is drawn |

Both are declared in the manifest and rendered by uDeck; the plugin ships no
settings screen, because no plugin does.

Settings arrive as environment variables holding **JSON**, which is why the
script strips the quotes off `greeting` rather than assuming they are not there.

## Permissions

None. A plugin that reads nothing and runs nothing declares nothing, and uDeck
never asks the operator about it. That is worth seeing once: the permission
sheet is not a formality every plugin goes through, it is a question asked only
when there is something to ask about.
