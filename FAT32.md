# FAT32: past FAT16's 2 GB

**Built, and judged under QEMU on both hosts** (QUEUE.md item 17): this
machine mounts FAT16 and FAT32 alike, and the cutover's volume is FAT32.
This page is the design as it was written before the work, and is
background only: the cutover is CUTOVER.md, and what a volume can and
cannot hold is MIGRATION.md.

## Why, and how far it goes

FAT16 is defined by its cluster count: fewer than 65,525. With 32 KiB
clusters, the largest size every implementation agrees on, that is a 2 GiB
volume. Prod's data is 215 MB today, and each user may store up to 1 GiB
over their lifetime, so two users at the cap fill a FAT16 volume. A volume
for N users at the cap is N GiB, plus everything else.

FAT32 raises three limits, and leaves one where it is:

- **Clusters:** up to 2^28 − 11 (the top 4 bits of an entry are reserved).
- **A volume:** with 32 KiB clusters, larger than this machine can address.
  The real ceiling is our own sector numbers (below): 2 TiB.
- **A file:** still at most 4 GiB − 1. The directory entry's size field is
  32 bits in both formats. Caddy caps one upload at 110 MB
  (angry-gopher's `deploy/Caddyfile`), so files stay far below that, and
  `writeInto`'s existing `reach > 0xFFFF_FFFF` check stays exactly as it is.

What grows is the number and total size of files, not the size of any one
of them. So FAT32's work is about the volume: the FAT's size in memory
(§9), the free-cluster search (§8), and the sector-number ceiling (§10).

## What changes in `src/disk_fat.zig`

### 1. The cluster type: `u16` becomes `u32`

About thirty signatures and fields carry a cluster as `u16`, including:

- `Entry.first_cluster`
- `Volume.max_cluster`
- `Walk.cluster`
- every `dir_cluster` parameter
- `allocChain`, `freeChain`, `lastCluster`, `writeAt`, `writeRuns`,
  `setEntry`, `makeDirIn` and `makePath`
- the `Parent` and `removeTreeAt` frames

Introduce `pub const Cluster = u32` and change them all. **Do this as its own
commit, with no change of behaviour:** every FAT16 probe stays green, and the
diff is purely mechanical. That makes the later commits readable.

### 2. Which FAT it is, decided the way the spec decides

`mount` already decides FAT16 by cluster count (`clusters < 4085 or clusters
>= 65525` → `NotFat16`), not by the boot sector's type string. That is the
right rule (Microsoft's FAT specification, "FAT type determination"), and it
extends: 65,525 and up is FAT32. `Volume` gains `kind: enum { fat16, fat32 }`,
and every place below that differs switches on it. Volumes of both kinds stay
mountable, so an existing FAT16 volume keeps working.

### 3. The boot sector's FAT32 fields (BPB offsets)

| field | offset | FAT32 rule | what to do |
|---|---|---|---|
| `BPB_RootEntCnt` | 17 | must be 0 | 0 means FAT32; non-zero means FAT16 as today |
| `BPB_FATSz16` | 22 | must be 0 | use `BPB_FATSz32` instead |
| `BPB_FATSz32` | 36 | sectors per FAT | `sectors_per_fat` |
| `BPB_ExtFlags` | 40 | bit 7: mirroring off; bits 0–3: active FAT | **refuse if bit 7 is set** |
| `BPB_FSVer` | 42 | must be 0 | refuse otherwise |
| `BPB_RootClus` | 44 | first cluster of the root | check it is in `[2, max_cluster]` |
| `BPB_FSInfo` | 48 | sector of FSInfo, usually 1 | see §6 |
| `BPB_BkBootSec` | 50 | backup boot sector, usually 6 | read-only to us; never written |

Notes on the table:

- **`BPB_ExtFlags`:** a volume with mirroring off has only one live FAT.
  `fatSet` writes every copy, so it would be writing over a copy the volume
  says is stale. mkfs and Linux never set this bit, so refusing costs
  nothing.
- **The data region:** `root_sectors` is 0 on FAT32, so `data_start` is
  `reserved + num_fats * sectors_per_fat`.

"A boot sector is not trusted" applies to every new field just as it does
to the old ones.

### 4. FAT entries: four bytes, 28 bits

- **`fatGet`** reads four bytes at `cluster * 4` and masks with
  `0x0FFF_FFFF`.
- **`fatSet` keeps the top four bits of whatever is there.** The spec
  reserves them, and a tool may have set them. With the FAT cached, they come
  from the cache. Uncached, `fatSet` already reads each sector before writing
  it, so it keeps them for free.
- **Constants:**
  - end of chain: anything at or above `0x0FFF_FFF8`
  - written end: `0x0FFF_FFFF`
  - bad cluster: `0x0FFF_FFF7`
  - `chain_end` and the literal `0xFFFF` in `allocChain` become per-kind
    values.
- **An existing hole, worth closing in the same change.** `nextCluster`
  rejects values below 2 but returns anything below `chain_end` as the next
  cluster. That includes FAT16's bad-cluster mark `0xFFF7`, and any value
  above `max_cluster`, either of which sends a read outside the data region.
  It should return `BadChain` for `v > max_cluster`, which covers both kinds.

### 5. The root directory is a chain

On FAT16 the root is a fixed run of sectors before the data region. `Walk`
special-cases it (`root`, `left_in_root`), and `grow` cannot extend it, which
is where `DirectoryFull` comes from.

On FAT32 the root is an ordinary cluster chain starting at `BPB_RootClus`.

**Keep the API's convention that cluster 0 means "the root".** A `..` entry
in a directory directly under the root stores 0 on FAT32 too; the spec says
so, and `fsck.fat` checks it. So `Walk.start(0)` maps 0 to `root_cluster` on
FAT32 and walks it like any other chain, and `grow` extends it. `makeDirIn`'s
`..` keeps writing 0 for the root. Only the walk changes.

### 6. Directory entries: the cluster's high half

A FAT32 entry's first cluster is `DIR_FstClusHI` (bytes 20–21) shifted left
by 16, or'd with `DIR_FstClusLO` (bytes 26–27).

- **Readers** (the entry parser at `.first_cluster = le16(e[26..28])`)
  combine both halves on FAT32 only. On FAT16, bytes 20–21 belonged to
  OS/2's extended attributes and must not be read as a cluster.
- **Writers** write both halves on FAT32 and write HI = 0 on FAT16. That is
  every place that writes byte 26: entry creation, `setEntry`, and
  `makeDirIn`'s `.` and `..`.
- **The likeliest bug:** a file whose clusters happen to sit below 65,536
  works with HI left out, and only a large or late file breaks. So the tests
  below force cluster numbers past 65,535 on purpose.

### 7. FSInfo: the free count and the next-free hint

FAT32 keeps a free-cluster count and a "next free" hint in the FSInfo sector.
Each may also hold `0xFFFF_FFFF`, meaning "unknown". Both are hints, but
`fsck.fat` reports a count that is set and wrong.

1. **First, invalidate.** On the first write after mount, set both to
   `0xFFFF_FFFF`, in FSInfo and in its backup at `BPB_BkBootSec + 1`. After
   that, never touch them. This is legal, Linux recomputes, and it costs one
   sector write per mount.
2. **Later, maintain them**, if mount time on a large volume matters.
   Linux's mount scans the whole FAT when the count is unknown.

### 8. The free-cluster search

`allocChain` starts at cluster 2 every time. With the FAT cached that is a
memory scan, which was fine across FAT16's 65k entries. FAT32 can have
millions, and a nearly full volume would scan nearly all of them for every
small file.

Keep a `next_free` cursor in `Volume`:

- an allocation starts from the cursor;
- an allocation leaves the cursor just past what it took;
- `freeChain` moves the cursor back if it frees below it;
- a search wraps once before answering `Full`.

The FSInfo hint in §7 is this cursor, persisted.

### 9. The FAT held in memory

`cacheFat` holds one whole copy of the FAT. On FAT32 its size is 4 bytes per
cluster:

| volume | cluster | clusters | one FAT copy |
|---|---|---|---|
| 2 GiB | 32 KiB | 65,536 | 256 KiB |
| 100 GiB | 32 KiB | 3.3 M | 12.5 MiB |
| 1 TiB | 32 KiB | 33.5 M | 128 MiB |

**Recommendation: format with 32 KiB clusters, and size the volume so that
its FAT fits the memory set aside for it.**

- The kernel already reads `vol.fatBytes()` before allocating the cache
  (`probe/gopher.zig`). Make it refuse, with a clear message, a FAT larger
  than a configured budget, rather than failing an allocation.
- **Past the budget**, the shape is a cache of FAT *sectors* plus a free
  bitmap (1 bit per cluster: 4 MiB for 33.5 M clusters). That is a real
  piece of work, and not needed for the volumes in view.

Two smaller things:

- **Boot time.** `cacheFat` compares the second copy one sector at a time.
  At 12.5 MiB that is 25,600 reads, so it should read the second copy with
  `readSectors` in large runs, as it does the first.
- **Larger clusters** cut the FAT, but cost space per small file, and chat
  writes many small files.

### 10. Sector numbers are 32 bits

`start_lba`, `fat_start`, `data_start` and `clusterSector`'s result are all
`u32` sectors. With 512-byte sectors that is 2 TiB. `virtio.Block.read`
already takes a `u64` LBA, and DigitalOcean volumes go to 16 TiB.

**Recommendation: refuse at mount a volume that extends past sector 2^32,
with a message saying why.** Widen to `u64` only when a volume that large is
wanted, since the FAT-memory limit in §9 bites first.

### 11. Names

The module is still called `disk_fat.zig`, and its error is `NotFat16`. Renaming
it (to fat.zig, with `NotFat`) touches every importer. Do it in a separate,
mechanical commit, or not at all.

## What stays

- **Long names:** VFAT's long-name entries, their reverse order, the
  checksum, the 8.3 alias generation, and `aliasTaken`. These are identical
  on FAT32.
- **Entry fields:** directory entry layout apart from the high-half cluster
  bytes; the dates and their UTC convention (`Dos`); the attribute bits.
- **Data paths:** `writeRuns`, `readAt`, `layout`, `remove`, `removeTree` and
  path walking. They are cluster arithmetic over `fatGet`/`fatSet` and
  `clusterSector`, and only their types change.
- **Rules:**
  - every FAT copy is written on every change;
  - where copies disagree at mount, the first is the FAT, and the others
    are written from it (a machine stopped between two copies' writes);
  - nothing here allocates;
  - a failed allocation leaves nothing behind.
- **`Io.Dir`** above it, and the application above that: not one call site
  moves.

## Moving the data

There is no in-place FAT16→FAT32 conversion, and none is worth writing. The
move is done on Linux:

1. Create a new volume and `mkfs.vfat -F 32 -s 64` it (32 KiB clusters).
2. Loop-mount the old and new volumes with `tz=UTC`, and `cp -a` across.
3. Compare the trees, names, bytes and modification times, which the
   judges' tree comparison already does.

Because the kernel mounts both kinds, the old volume keeps serving until the
new one is attached.

## Judged against Linux

The FAT16 work earned its trust from two judges that have never seen our code:

- `fsck.vfat -n` for the structure;
- the Linux VFAT driver, which reads what we wrote, and writes what we then
  read.

FAT32 gets the same judges, plus cases FAT16 cannot have.

**Every FAT probe runs on both kinds.** `probe/run.sh` builds its images with
`mkfs.vfat -F 16 … 32768`. Add a FAT32 image to each FAT probe: `vfat`,
`append`, `replace` and `restore`.

- **A FAT32 image is cheap.** FAT32 needs at least 65,525 clusters, so with
  512-byte clusters (`-F 32 -s 1`) a 40 MiB image is enough.
- **The same judges:**
  - fsck finds no error;
  - Linux reads every name and byte we wrote;
  - we read what Linux wrote;
  - the replace probe's forced fragmentation, on the other kind.

**FAT32's own cases**, each a probe judged the same way:

- **Cluster numbers past 65,535.** On the 512-byte-cluster image, write
  files totalling more than 32 MiB, so later files start above cluster
  65,535. Then Linux reads them back byte for byte. This is the test for the
  high half in §6.
- **A root directory that outgrows one cluster:** a few hundred entries in
  the root, which FAT16 answers with `DirectoryFull`. fsck must pass, and
  Linux must list them all.
- **Reserved bits preserved.** Poke the top 4 bits into some FAT entries
  with a few lines of Python. Write through those chains, then check the
  bits survive and fsck accepts the volume.
- **FSInfo.** After our writes, the free count is either `0xFFFFFFFF` or
  correct. `fsck.vfat -n` says which; it must not report a wrong one.
- **Refusals.** Mirroring disabled (`ExtFlags` bit 7), `FSVer` ≠ 0, a
  `RootClus` out of range, and a volume past sector 2^32 (a sparse image).
  Each is refused at mount with its own error, like `realunset`'s "refused
  as it must".
- **Scale:** a sparse image of tens of GiB, filled the way chat fills it:
  - many users' worth of uploads up to Caddy's 110 MB, and many small files
    between them;
  - then deletes, and more writes into the gaps.

  It is timed like `ladder`, and it reports the FAT cache's size and the
  free-cluster search's cost with the cursor in place, at each step of the
  fill.

**Then the chat judge.** `probe/run.sh gopher` against Linux, serving from a
FAT32 volume, with every gate the same. This is what says the port does not
care which FAT is under it.

**Host unit tests**, for the pure parts:

- the BPB → layout computation;
- the high/low cluster encoding;
- 28-bit entry get/set with reserved bits kept.

`mount` takes a `*virtio.Block`, so these want the layout arithmetic pulled
out into a function over a 512-byte array. That is a small refactor that
also makes the "a boot sector is not trusted" checks testable.

## Order of work

Each step is a commit, and each keeps every FAT16 probe green.

1. `Cluster = u32` everywhere: mechanical, no behaviour change. Close the
   `nextCluster` hole (§4) at the same time.
2. FAT32 mount and read: §2, §3, the read half of §4, §5's walk, §6's
   reader. Judge: the read probes on Linux-made FAT32 images.
3. FAT32 writes: the rest of §4, §5's `grow`, §6's writers, §7 (invalidate).
   Judge: fsck, Linux, and the FAT32-only probes.
4. The free-cluster cursor (§8), then the FAT cache budget and run reads
   (§9). Judge: the scale ladder.
5. The data move (above), on the droplet.
