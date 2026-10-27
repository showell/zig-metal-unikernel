# FAT32, and what a volume can hold

This machine mounts FAT16 and FAT32 alike (`src/disk_fat.zig` and the files
split from it), deciding which by cluster count, as Microsoft's FAT
specification says: 65,525 clusters and up is FAT32. Production's data
volume is FAT32 with 32 KiB clusters (`droplet/new_volume.py --fat 32`).
`docs/disk.md` says why the FAT is our own and how it is judged.

## The limits

- **A file:** at most 4 GiB − 1 on both kinds (the size field is 32 bits);
  a longer write is refused before anything is written.
- **A volume:** sector numbers are 32 bits, so a volume that runs past
  sector 2^32 (2 TiB at 512 bytes) is refused at mount.
- **The FAT is held whole in memory,** and one volume's may take at most
  32 MiB (`fat_budget_bytes`, `probe/volumes.zig`): about 256 GiB of volume
  at 32 KiB clusters. A larger FAT is refused at boot, saying so. Format a
  larger volume with larger clusters, at a cost in space per small file.
- **A name:** up to `max_name`, 96 bytes (`src/disk_fat_dirent.zig`);
  angry-gopher's longest is 96. A longer name is refused on write, and on
  read is found only by its 8.3 alias. A character past ASCII reads as `?`.
- **A directory:** at most 65,536 entries (2 MiB), past which `fsck.fat`
  calls it broken; a write that needs more fails as a full disk. A name
  that is not upper-case 8.3 takes one entry plus one per 13 characters.
  FAT16's root is a fixed 512 entries; FAT32's grows like any directory.
- **Paths:** `io.zig` opens paths up to 256 bytes, and `removeTree` stops at
  16 levels.

**What a FAT volume does not keep,** which matters when a Linux tree is put
on one (`droplet/check_volume_tree.py` finds each of these, and
`droplet/build_volume.py` refuses a tree it still finds anything in):
names are compared without case, so `<dir>/Plan.md` and `<dir>/plan.md` are one file;
no symlinks, hard links or special files; no owners or permissions; only
the modification time, in 2-second steps, from 1980 to 2107. **Times are
UTC throughout:** FAT stores local time, this machine reads it as UTC, so
`build_volume.py` runs mtools with `TZ=UTC` and a Linux mount that should
agree says `tz=UTC`.

## How FAT32 differs from FAT16

### 1. Clusters

A cluster is a `Cluster` (`u32`); a FAT32 entry is 28 bits, the top four
reserved.

### 2. The boot sector

The FAT32 fields are checked like every other ("a boot sector is not
trusted"). A volume with mirroring off (`BPB_ExtFlags` bit 7), a
`BPB_FSVer` other than 0, or a `BPB_RootClus` out of range is refused at
mount, each with its own error.

### 3. FAT entries

`fatSet` keeps the four reserved bits of whatever entry it overwrites. A
link outside the data region, FAT16's bad-cluster mark included, is a
broken chain (`BadChain`).

### 4. The root

FAT32's root is an ordinary chain from `BPB_RootClus`, and grows. Cluster
0 still means the root everywhere in the API, and a `..` entry under the
root stores 0, as the spec says.

### 5. Directory entries

A FAT32 entry's first cluster is `DIR_FstClusHI` (bytes 20–21) shifted
left by 16, or'd with `DIR_FstClusLO` (bytes 26–27). On FAT16 bytes 20–21
are not a cluster, and are written 0. A file below cluster 65,536 works
with the high half left out, so the tests force clusters past it.

### 6. Every copy of the FAT

Every change writes every copy. Copies found apart at mount are weighed,
and the cleaner wins; a mount whose copies cannot be weighed refuses writes
until a weighing succeeds (`src/disk_fat_fat.zig`).

### 7. FSInfo

On the first write after mount, the free count and the next-free hint are
set to `0xFFFF_FFFF`, unknown, in FSInfo and its backup; they are never
touched after. Linux recomputes them.

### 8. The free-cluster search

An allocation starts at a cursor (`alloc_hint`), 2 at every mount, below
which every cluster is in use, so a small write on a nearly full FAT32
volume reads a few FAT sectors, not all of them.

### 9. The FAT in memory

One copy is 4 bytes a cluster on FAT32: 256 KiB for 2 GiB, 12.5 MiB for
100 GiB, at 32 KiB clusters. The kernel reads `vol.fatBytes()` before
holding it, and refuses past the budget (above).

### 10. Sector numbers

`start_lba`, `fat_start`, `data_start` and `clusterSector`'s result are
`u32` sectors, though `virtio_blk` takes a `u64` LBA; widening them waits
for a volume past 2 TiB, which the FAT budget stops first.

## Judged against Linux

`fsck.vfat -n` judges the structure, and Linux's VFAT driver reads what we
wrote and writes what we then read. `FAT=32 probe/run.sh` formats the FAT
probes' volumes as FAT32; `probe/run.sh gopher` judges the server on FAT32
by default (`FAT=16` for the other). FAT32's own cases (clusters past
65,535, a root that outgrows a cluster, reserved bits kept, FSInfo, the
refusals, the cursor) are host tests in `src/disk_fat_test_fat32.zig`.
