# The Store: one seam for the application's data

webbox's `store.zig` (zig-webbox `src/`) is the seam production runs, and
the contract below is what every host implementation keeps.

## Where it lives

| | what it is | where |
|---|---|---|
| **the seam** | the operations below | zig-webbox `src/store.zig` |
| **on Linux** | that file over `std.Io` | as written |
| **on metal** | that file, built from `../zig-webbox`, over this repo's `io.zig` and `disk_fat.zig` | `Io = metal.io` |
| **the model** | the oracle: plain, in memory | `src/store_model.zig` |
| **the judge** | all three, the same seeded operations, the same answers and the same tree after each | `src/store_judge.zig`, `zig build store-judge`: the eleven operations below, 200 seeds; no power cuts or full volumes yet |

This repo's own `store.zig`, `store_fat.zig` and `store_linux.zig` are where
the contract was first written and proven against `disk_fat.zig`
(`store_sim`). They stay until the judge covers what they cover, power cuts
included; then the model is what remains of them.

## The operations

| operation | does | answers |
|---|---|---|
| `read` | a file, whole | its bytes; `FileNotFound`, `IsDir` |
| `readAt` | part of a file, from an offset | the bytes read, fewer at the end, none past it |
| `stat` | a file's or a folder's size and kind | `Stat`; `FileNotFound` |
| `has` | whether a name is there | true or false; "no" only for a path not found, through a file, or with a name too long, and any other error is the caller's |
| `list` | what a folder holds | its entries, in the disk's order; a folder not there holds nothing |
| `write` | a file, whole, made or overwritten, its folders made | |
| `append` | bytes on a file's end, making it if absent | the file's new size |
| `replace` | a file, whole, made or overwritten, through a temporary and a rename | |
| `remove` | one file; not there is not an error | `IsDir` for a folder |
| `makeDir` | a folder and every one above it | |
| `removeTree` | a folder and everything under it | refuses a last name FAT cannot hold |

The seam also has `createNew` (a file that must not already be there, in
any case; `PathAlreadyExists` otherwise), which the judge does not drive.
`resolve` (the name as the disk spells it, case folded) is the store's own.

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
name did not land it undoes its own unlink, so the temporary is whole and
removed after. Where the disk cannot say, or the undo fails too, the
temporary's chain is a counted leak, never the old file.

**On this machine a `write` over a file is as safe as a `replace`**
(`disk_fat`'s `writeFileIn`): the new bytes go into a chain of their own and
one sector write moves the entry onto it, so it needs room for both copies,
as `replace` does. The contract stays the weaker one, since `write` on
Linux empties the file and then fills it.

`replace` is the one to use where losing the old file would matter; `write`
is the cheap one. **`store_sim` holds each of the first four rows, against
this repo's own FAT store**; the judge of production's store holds none of
them yet (no cuts, no full volume), and that is its next step.

## The rules, on every host

FAT's, so a laptop refuses what the droplet would:

- **A name FAT can hold** (`BadName` otherwise): 1 to 96 bytes (`max_name`,
  `src/disk_fat_dirent.zig`), printable ASCII, none of `" * / : < > ? \ |`,
  not `.` or `..`, not ending in a dot or a space.
- **Case does not tell two names apart; it is kept for display.**
- **A path at most 256 bytes** (`io_volumes.zig`'s `max_path`) **and 16 parts
  deep** from its root's own name, so a file sits in at most 15 folders
  (`disk_fat`'s `max_path_depth`). `tools/check_limits.py`, in tier 3, fails
  if zig-webbox's copies of these three move apart from this repo's.
- **An error is not an empty file** (`readOrEmpty` answers "" only for a
  file that is not there), **and not "no"** (`has`, above).

## Open questions

1. **The model's limits are narrower than the seam's:** `src/store.zig`'s
   `max_part` is 80 and `max_parts` 8, where the seam allows 96-byte names
   16 parts deep. Until the model takes the seam's, the judge's paths stay
   within the model's.
2. **`WriteOptions.private`** (owner-only permissions on Linux) has no
   meaning on FAT; the metal host ignores it.
