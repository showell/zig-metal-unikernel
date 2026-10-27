# The disk: our own FAT, judged by Linux

Why `src/disk_fat.zig` (FAT16 and FAT32 alike) is ours, and what each part is
judged by. FAT32 itself is [`FAT32.md`](../FAT32.md); the caches above the
filesystem are `src/page_cache.zig` and `src/io_volumes.zig`'s `SiteCache`.

## Why our own

There is no native Zig FAT for runtime use: [**zfat**](https://github.com/ZigEmbeddedGroup/zfat)
binds ChaN's FatFs (C), [**zig-osdev/disk-image-step**](https://github.com/zig-osdev/disk-image-step)
writes images at build time, and the mature runtime libraries
([fat_io_lib](https://github.com/ultraembedded/fat_io_lib), gristle, SEGGER
emFile) are C. And:

- The application asks for whole-file operations, no seeks and no partial
  writes, which is a small fraction of what FatFs does.
- A C dependency inside a freestanding kernel is a real cost, and FatFs brings
  a large configuration surface with it.
- There is a FAT16 next door in `roc-apps/floor`, in Roc, green against
  the same fixtures — an **oracle**, which a third-party library would not
  give us.

**Sector 0 is not the filesystem.** A served disk is GPT, LBA 0 a protective
MBR; `src/gpt.zig` finds the data partition.

## A file has a date, and chat's "recent" is built out of it

`/chat/recent` sorts every conversation and document by file modification
time. With no dates on the files the page lists 1970, in the wrong order.

FAT has one timestamp: two 16-bit words per directory entry, the year counted
from 1980 and the seconds counted in **twos**. `src/disk_fat.zig` writes them
at creation and on every write that moves a file's size. The filesystem has
no clock and must not invent one: `io.zig` points `Volume.clock` at the wall
clock, which answers null until the RTC has been read, so a probe kernel with
no clock writes entries with no date rather than a plausible wrong one.

**UTC, with no time zone anywhere.** DOS dates are local time by convention
and the Linux VFAT driver applies the mount's zone to them; nothing here has a
zone, and the application renders Eastern from a Unix time. So the driver is
asked with `tz=UTC`, and then it agrees:

```
     append | the Linux VFAT driver reads all 600 lines and the late append, byte for byte
     append | and dates the files it read within 0s of the kernel's own clock
```

That gate catches what host tests cannot: the two words written in the wrong
order pass every test of the packing, because the packing is right and the
layout is not.

The calendar is `src/civil.zig`, because the CMOS chip and every directory
entry need the same dates to be the same instants. Its round trip is checked
for every day from 1980 to 2110.

## Long names, and the judge

The application stores `auth/<id>/api-key`, `_session_secret`,
`upload-bytes` and `last-seen`, none of which 8.3 holds, so `src/disk_fat.zig`
has VFAT long names, subdirectory writes, directory growth and `mkdir`.
**The verdict is `fsck.vfat`'s**, not ours: `probe/run.sh` writes a volume
with our code and hands it over.

```
PASS vfat |   auth/damian: . .. api-key _session_secret
     vfat | fsck.vfat finds no error in what we wrote
```

**Passing fsck is not being right.** `api-key` *fits* in 8.3, and 8.3 is
uppercase, so it would read back `API-KEY`. `needsLongName`
(`src/disk_fat_dirent.zig`) asks whether a name reads back as itself, which
makes every name with a lowercase letter a long one.

## The backup story, both ways

The check then loop-mounts the volume with **the Linux kernel's own VFAT
driver** and compares what Linux sees with what we wrote, every name and
every byte, so `cp -r` off a mount gets the data out. Then the other half:
**Linux writes and we read**. The check has Linux create a directory and a
long-named file, unmounts, and boots the `restore` probe, which reads them
and checks our own files survived.

The mount needs root, so it is **skipped rather than failed** where there is
none — a check that cannot run must not look like one that passed.

`probe/replace.zig` forces a remove in a directory past one cluster, with long
names across the cluster's edge, and its judge checks from the raw image that
it did: our own reader agrees with mistakes there that `fsck.vfat` and Linux
do not.

## Read a run at a time, with the FAT in memory

**The FAT is held in memory** (`Volume.cacheFat`, `src/disk_fat_fat.zig`),
written through to every copy on each change, first copy first. Where the
copies differ at mount, each is checked against the directories and the
cleaner one is the FAT; a tie holds the first and writes neither, and copies
that cannot be weighed leave the volume refusing writes (`cacheFatChecked`).

**A file is read and written as runs** of consecutive clusters (`readAt`,
`writeRuns` in `src/disk_fat_file.zig`): whole sectors go straight between
the caller's buffer and the disk, one request per run, at most the disk's
`most_sectors`; only a sector the transfer starts or ends inside goes through
the scratch sector.

**Judged three ways:**

- `replace` and `replace_cached` are one probe built twice, run from one
  formatted image, and must leave **byte-identical** volumes: the cache may
  change nothing that reaches the disk. (Both start from one image because
  mkfs stamps the volume label with its time.)
- `append` sweeps fifteen offsets against eleven lengths over a file whose
  chain breaks at every cluster and one that is a single run longer than a
  request may carry. Its volume uses 512-byte clusters, so its FAT is too big
  for one request: the only path that splits a read.
- Every request's log line says how many disk requests it made and how long
  they took, so a slow answer can be split into the device's share and ours.
