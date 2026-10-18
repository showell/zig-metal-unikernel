# The Store: one seam for the application's data

*The unified interface: webbox's `store.zig` (zig-webbox `src/`) is the
seam production runs, and the contract below is what every host
implementation keeps. Essay:
[where the metal stack stands](https://github.com/showell/essay-repl-server/blob/master/notes/where-the-metal-stack-stands.md), "The
Store". The census of what the application called, at angry-gopher
`f5d360e`: `git show 63afeb0:STORE-CENSUS.md`.*

## Where it lives

| | what it is | where |
|---|---|---|
| **the seam** | the eleven operations below | zig-webbox `src/store.zig` |
| **on Linux** | that file over `std.Io` | as written |
| **on metal** | that file, built from `../zig-webbox`, over this repo's `io.zig` and `disk_fat.zig` | `Io = metal.io` |
| **the model** | the oracle: plain, in memory | `src/store_model.zig` |
| **the judge** | all three, the same seeded operations, the same answers | `src/store_judge.zig`, `zig build store-judge`: all eleven operations, 200 seeds; no power cuts or full volumes yet |

zig-metal-unikernel's own `store.zig`, `store_fat.zig` and `store_linux.zig` are
where this contract was first written and proven against `disk_fat.zig`
(`store_sim`). They stay until the judge covers what they cover, power cuts
included; then the model is what remains of them.

## The operations

From the census: the six every host needs, `readAt` (Steve, 2026-10-07),
and the four the application already calls.

| operation | does | answers |
|---|---|---|
| `read` | a file, whole | its bytes; `FileNotFound`, `IsDir` |
| `readAt` | part of a file, from an offset | the bytes read, fewer at the end, none past it |
| `stat` | a file's or a folder's size and kind | `Stat`; `FileNotFound` |
| `has` | whether a name is there | true or false; an error is not "no" (see below) |
| `list` | what a folder holds | its entries, in the disk's order; a folder not there holds nothing |
| `write` | a file, whole, made or overwritten, its folders made | |
| `append` | bytes on a file's end, making it if absent | the file's new size |
| `replace` | a file, whole, made or overwritten, through a temporary and a rename | |
| `remove` | one file; not there is not an error | `IsDir` for a folder |
| `makeDir` | a folder and every one above it | |
| `removeTree` | a folder and everything under it | refuses a last name FAT cannot hold |

`resolve` (the name as the disk spells it, case folded) is the store's own
and stays inside it.

## What a power cut leaves

At any point in the operation, then the next boot's mount:

| operation | after a cut |
|---|---|
| `write` | old, new, or gone (on this machine: old or new) |
| `append` | old or new |
| **`replace`** | **wholly old or wholly new** |
| `remove` | there or gone |
| `makeDir` | some prefix of the folders made *(not yet judged)* |
| `removeTree` | some of the tree gone, the rest whole; never a file half removed *(not yet judged)* |

And when the volume is full (`NoSpaceLeft`): a replaced or appended file is
old; a written one is old or gone (on this machine: old).

**And when a write fails** (an error, not a cut), the disk may still have
taken it, so an error is not an undo: what is left is one of the outcomes
above. On this machine a `replace` whose rename fails keeps the old file:
FAT's rename reads its refused write back, and where the disk says the new
name did not land it undoes its own unlink (metal-vmm 145), so the
temporary is whole and removed after. Where the disk cannot say, or the
undo fails too, the temporary's chain is a counted leak, never the old
file.

**On this machine a `write` over a file is as safe as a `replace`**
(`fat16.writeFileIn`'s `overwrite`): the new bytes go into a chain of their
own and one sector write moves the entry onto it, so it needs room for both
copies, as `replace` does. The contract above stays the weaker one, since
angry-gopher's `write` on Linux empties the file and then fills it.

`replace` is the one to use where losing the old file would matter; `write`
is the cheap one. That is the whole difference. **Today `store_sim` holds
each of the first four rows, against zig-metal-unikernel's own FAT store**; the
judge of production's store holds none of them yet (no cuts, no full
volume), and that is its next step.

## The rules, on every host

FAT's, so a laptop refuses what the droplet would (Steve, 2026-10-02):

- **A name FAT can hold** (`BadName` otherwise): 1 to 96 bytes (`fat16`'s
  `max_name`), printable ASCII, none of `" * / : < > ? \ |`, not `.` or
  `..`, not ending in a dot or a space.
- **Case does not tell two names apart; it is kept for display.**
- **A path at most 256 bytes** (`io_volumes.zig`'s `max_path`) **and 16 parts deep**
  from its root's own name, so a file sits in at most 15 folders
  (`fat16`'s `max_path_depth`). `tools/check_limits.py`, in `gates.sh`,
  fails if angry-gopher's copies of these three move apart from metal's.
- **An error is not an empty file** (`readOrEmpty` answers "" only for a
  file that is not there), **and not "no"** (`has`, open question 3).

## Open questions

1. **The model's name rule is 80 bytes; the seam's is 96.** zig-metal-unikernel's
   `store.zig` chose 80, angry-gopher's 96 (FAT's own limit as `fat16` keeps
   it). The model should keep the seam's 96. Until it does, the judge's
   names stay under 80.
2. **`WriteOptions.private`** (owner-only permissions on Linux) has no
   meaning on FAT. It stays an option the metal host ignores, as now.
3. **`has` answered "no" for any error.** Fixed on angry-gopher's branch
   `has-errors`, with v20: "no" only for a path not found, through a file,
   or with a name too long; any other error is the caller's, and each caller
   says what it means (chat retirement keeps its references, legacy cookies
   are refused, a secret is never written over).
4. **`has` and `stat` against `list`**: the census suggests both could be
   one `list` of the parent. They cost a folder walk either way. With
   folders held in memory (v19) that walk is cheap, so the eleven can stay
   eleven and say what the caller means.
