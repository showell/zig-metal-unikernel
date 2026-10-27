# Review: the Store, as an adversary

The application's Store, now zig-webbox's `src/store.zig`, the one way the
application reaches its files. Findings 3 (a file written over a directory's
name, now `IsDirectory` in `src/disk_fat_file.zig`) and 5 (`has` now fails
on anything but absence) are fixed; these are left.

### 1. A miss costs a full directory listing, and on metal two (medium)

**Where:** `sibling`, reached through `retry` and `resolve` by every call
whose exact path is missing.

**The problem:** a miss is not rare: every file that does not exist yet (a
topic with no reactions, a conversation with no pins, a transcript before
its first message) is one, and each lists the whole folder, a listing per
missing level. On metal the listing is pure waste: the FAT lookup already
folds case, so a miss there is a true miss, and the Store then walks the
folder again off the disk.

**Failure:** pages that ask for something not there yet slow down as
folders grow, on metal twice over. Nothing breaks.

**Fix shape:** on a host whose filesystem folds case (metal), skip
`sibling`. On Linux, a per-folder name index, or accept the listing.

### 2. Two writers can make two names that differ only in case, on Linux only (medium-low)

**Where:** `forWrite` → `resolve`, then the create, with nothing held
between them.

**The problem:** with neither existing, two requests at once write
`Plan.md` and `plan.md` in one folder; each `resolve` finds no other case,
so Linux holds both, and each case reads its own file from then on. On metal
the second write replaces the first.

**Failure:** the hosts disagree about what was written; in chat, two topics
that should be one. **How likely:** low: two people creating the same topic
within milliseconds, in different case.

**Fix shape:** one process-wide mutex around resolve-and-create.

### 4. `..` in the middle of a path passes the Store, and the hosts then differ (medium-low)

**Where:** `forWrite` checks only the last name (`fatName`); `forMakeDir`
checks only the names past the part that exists, and `..` always exists.

**The problem:** `write("data/users/../../x/f")` passes on Linux and writes
outside the data root. On metal, `io.zig` refuses any path with `.` or `..`
(`placeOf`), so a judge run on metal alone would not see the mistake. Only
a caller bug reaches it.

**Fix shape:** refuse any component that is `.` or `..` in every call's
path, so the Store refuses what metal's io refuses.
