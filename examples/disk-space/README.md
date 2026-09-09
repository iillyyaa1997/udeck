# Disk space

A uDeck poll plugin that answers one question — **how much room is left?** —
and spends almost all of its code on the reason that question is harder to
answer honestly than it looks.

```
┌──────────────────────────────────┐
│ Disk space            673 GB free│
│ ▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░  │
│ Startup disk   673 GB free of 993 GB │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░  │
│ Time Machine    20 GB free of 500 GB │
└──────────────────────────────────┘
```

## A df line is not a disk

`df` on a modern Mac lists eight or nine filesystems for what the operator
would call one disk:

```
/dev/disk3s1s1   971298980  12342964 657237268     2%    /
/dev/disk3s6     971298980   3145748 657237268     1%    /System/Volumes/VM
/dev/disk3s2     971298980   8859848 657237268     2%    /System/Volumes/Preboot
/dev/disk3s4     971298980      4012 657237268     1%    /System/Volumes/Update
/dev/disk3s5     971298980 287905764 657237268    31%    /System/Volumes/Data
```

Five volumes of one APFS container. They share one pool of free space, and
every one of them reports that whole pool as its own `Available`. Two things
follow, and both of them are the plugin:

* **Listing them separately shows the same 657 GB five times.** Anyone reading
  the card would have to know which of the five rows is the one that matters.
* **Summing their `Available` claims three terabytes on a one-terabyte disk.**
  Which is why the default view sums the *used* space, which really is
  per-volume, and takes the **smallest** reported free space in the group — the
  only figure in it that cannot be an overstatement.

The container is derived from the device node: `/dev/disk3s5` and
`/dev/disk3s1s1` are both `disk3`. A device that does not look like that is its
own container, which is the right answer for a plain partition or a mounted
disk image.

## Fullness is measured against what the disk can still hold

The percentage is `used / (used + free)`, not `used / total`. On APFS the
container's block count is shared by every volume in it and exceeds what the
operator will ever be able to use; a percentage taken against it reads lower
than the truth by however much of the disk is spoken for and invisible. A card
that says *68 % full* while the Finder says *657 GB available* has told them
nothing they can act on.

Sizes are printed in decimal units — 673 GB, not 611 GiB — because the number
has to match the one the operator can check in the Finder. `df -k` counts in
1024-byte blocks, so the conversion is deliberate and lives in one function.

## Network volumes are not listed

`df` is called with `-l`. A network mount whose server has gone away makes `df`
block until the mount times out, which may be never, and this card runs every
thirty seconds. The plugin contract is explicit about not calling anything that
can hang, and a NAS that is missing from the card is a smaller failure than a
card that stops updating and a producer that has to be killed on every poll.

So: **if you are looking for your NAS, it is not here, and that is on purpose.**

## The volumes macOS keeps for itself

Preboot, Recovery, VM, Update, xarts, iSCPreboot, Hardware. They are real, they
take real space, and none of them is ever something to act on.

* In the **per-disk** view they are counted — they are part of what fills the
  disk — but they never get a row of their own.
* A container holding **nothing but** system volumes disappears. Every Apple
  silicon Mac has a second, half-gigabyte container carrying iSCPreboot, xarts
  and Hardware and nothing else. It is separate storage, so dropping it loses
  none of the operator's space, and keeping it puts a row labelled `xarts` on
  the card that no answer to "what is that?" makes useful.
* In the **per-volume** view they are hidden by `hide_system`, and the card
  says how many it hid rather than quietly shortening itself.

`/System/Volumes/Data` is the exception to all of this: it is not a system
volume in any sense the operator cares about, it is where their files live.

## Install

```sh
mkdir -p ~/.udeck/plugins/disk-space
cp manifest.json manifest.ru.json disk.py ~/.udeck/plugins/disk-space/
chmod +x ~/.udeck/plugins/disk-space/disk.py
```

Then add the plugin from uDeck. It polls every 30 s with a 3 s deadline, and
asks for `exec` on `df` and `open`.

Requirements: macOS and Python 3.9+ (the system `python3` is enough — the
script is standard library only and installs nothing).

## Settings

| Key | Type | Default | What it does |
|---|---|---|---|
| `warn_percent` | int | `85` | How full a disk has to be before the card turns amber |
| `crit_percent` | int | `95` | And before it turns red. A value below the warning threshold is raised to it |
| `volumes` | enum | `physical` | One row per disk, one row per mounted volume, or the startup disk alone |
| `hide_system` | bool | `true` | Hide the system's own volumes in the per-volume view, and drop a disk that holds nothing else |
| `watch_path` | string | *(empty)* | The disk holding this path is always listed, and listed first |

`watch_path` matches on the **longest** mount point that is a prefix of it. `/`
is a prefix of every path on the machine, so a first-match rule would mean an
external drive could never be watched.

## Both languages

The manifest is English and `manifest.ru.json` translates its labels; the card
itself reads `UDECK_LANG` and answers in `en` or `ru`. A code uDeck may speak
later — `ja`, `pt-BR` — falls back to English rather than failing, and a
regional code is reduced to its base language because this plugin has no
regional variants to choose between.

The startup disk's name is a phrase, not a path: `/` on a card tells the
operator nothing about which disk they are looking at.

## Output contract

Exactly one JSON object on stdout, nothing else. Diagnostics — a setting that
would not parse, a `df` line that would not parse, `df` failing outright — go to
stderr and show up in the plugin's error log. The script never raises: an
unexpected failure still prints a valid `unknown` card carrying the exception,
and exits 0.

Losing `df` altogether is fatal and the card goes `unknown`. A single line of
its output that will not parse is not: it is counted, shown as an
`unreadable lines` row, and the rest of the card stands.

`ttl` is 120 s — four poll intervals. Past it the host greys the card, which is
exactly right for numbers that stopped being refreshed.

## Tests

```sh
python3 -m unittest discover -s examples/disk-space -p 'test_*.py'
```

115 tests, no network, no dependencies, and nothing that reads the real
machine's disks — every case runs against canned `df` output, including the
end-to-end tests, which put a fake `df` first on `PATH`. The suite therefore
says the same thing on a Mac with three disks and on a build runner with none.
It includes an independent validator for the card schema, which every card the
tests build is checked against.

## Known limits

- **Network volumes are absent**, for the reason above.
- **A container is a disk, and sometimes that is a lie.** A mounted disk image
  gets its own `diskN` and therefore its own row, which is correct in the sense
  that its free space is genuinely separate, and wrong in the sense that the
  space it occupies is on some other disk and gets counted twice.
- **The disk's name is its mount point's basename**, not the volume label.
  They are usually the same and `df` does not carry the label; reading it would
  mean another external call on every poll.
- **Purgeable space is invisible.** macOS reports space it could reclaim as
  available, so a disk can report tens of gigabytes free that only exist as
  long as something is willing to be deleted. `df` cannot tell the difference
  and neither can this card.
