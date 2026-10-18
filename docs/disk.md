# The disk: our own FAT, judged by Linux

How `src/disk_fat.zig` (FAT16 and FAT32 alike) came to be ours, and what each
part is judged by. FAT32 itself is [`FAT32.md`](../FAT32.md); the caches above
the filesystem are `src/page_cache.zig` and `src/io_volumes.zig`'s `SiteCache`.

## Why we wrote our own

Checked first, and the ecosystem is thinner than expected. The nearest thing is
[**zfat**](https://github.com/ZigEmbeddedGroup/zfat) — *bindings* to ChaN's
FatFs, a C library, not a native Zig implementation.
[**zig-osdev/disk-image-step**](https://github.com/zig-osdev/disk-image-step)
does FAT12/16/32 but at *build* time, to make images, not to read them at
runtime. `pluto`'s `<pluto>/mkfat32.zig` is likewise an image writer. The mature
runtime implementations — [fat_io_lib](https://github.com/ultraembedded/fat_io_lib),
gristle, SEGGER emFile — are all C.

So: our own, and crib tests from wherever they exist. The reasons:

- The application asks for whole-file operations, no seeks and no partial
  writes, which is a small fraction of what FatFs does.
- A C dependency inside a freestanding kernel is a real cost, and FatFs brings
  a large configuration surface with it.
- There is a FAT16 next door in `roc-apps/floor`, in Roc, green against
  the same fixtures — an **oracle**, which a third-party library would not
  give us.

The three things that once would have sent us back to zfat — FAT32, long
names, and a rewrite that survives a stop (`fat16.rename`) — are all built
here now. `disk-image-step` is worth remembering regardless: making fixtures
without mtools or loop mounts is a real convenience.

**Sector 0 is not the filesystem.** The first fixtures were Cobblestone's
images, GPT disks with a protective MBR and one "EFI System" partition at LBA
2048, which is why its `Fat16` cites a `Gpt` chapter — and why a reader that
mounts sector 0 finds a boot sector of zeros and concludes, correctly and
uselessly, that the volume is not FAT16. `src/gpt.zig` finds the partition.

## A file has a date, and chat's "recent" is built out of it

`/chat/recent` sorts every conversation and document by file modification
time and prints each one as RFC 3339. With no dates on the files the page
lists 1970, in the wrong order.

FAT has exactly one timestamp: two 16-bit words per directory entry, the year
counted from 1980 and the seconds counted in **twos**. So `src/disk_fat.zig`
writes them — at creation, and again on every write that moves a file's size,
which is where every append and every replace lands. The filesystem has no
clock and must not invent one, so the host hands it the machine's: `io.zig`
points `Volume.clock` at the wall clock, and it answers null until the RTC
has been read, so a probe kernel with no clock writes entries with no date
rather than a plausible wrong one.

**UTC, with no time zone anywhere.** DOS dates are local time by convention
and the Linux VFAT driver applies the mount's zone to them; nothing here has a
zone, and the application renders Eastern from a Unix time. So the driver is
asked with `tz=UTC`, and then it agrees:

```
     append | the Linux VFAT driver reads all 600 lines and the late append, byte for byte
     append | and dates the files it read within 0s of the kernel's own clock
```

That gate earns its keep. Stamping nothing puts 1980 on the files
(`-1474109717s from the kernel's clock`), and writing the two words in the
wrong order puts 2023 on them (`-99616450s`) — and the second of those passes
every host test of the packing, because the packing is right and the layout
is not. Each judge sees what the other cannot.

The calendar is `src/civil.zig`, because two things need the same dates to be
the same instants: the CMOS chip and every directory entry. Its round trip is
checked for every day from 1980 to 2110.

## Long names, and the judge

The application stores `auth/<id>/api-key` and `_session_secret` and
`upload-bytes` and `last-seen`. Every one of those is refused by 8.3, and two
are two directories deep — so a volume that cannot hold them cannot hold the
data we already have.

So `src/disk_fat.zig` has VFAT long names, subdirectory writes, directory growth
and `mkdir`. **The verdict is `fsck.vfat`'s**, not ours: dosfstools has been
reading VFAT for decades and knows every way a long-name run can be wrong —
the checksum, the reverse ordering, the sequence numbers, orphaned entries,
`.` and `..`. `probe/run.sh` writes a volume with our code and hands it over.

```
PASS vfat |   auth/damian: . .. api-key _session_secret
     vfat | fsck.vfat finds no error in what we wrote
```

The checksum is the classic place to get this wrong, so it is written out
where it is used:

```zig
sum = (((sum & 1) << 7) | ((sum & 0xFE) >> 1)) +% short[i]
```

**Passing fsck is not being right.** A listing once came back `API-KEY`,
because `api-key` *fits* in 8.3 and so no long name was written — and 8.3 is
uppercase. Fitting is not enough; the name has to survive the round trip.
`needsLongName` asks whether a name reads back as itself, which makes every
name with a lowercase letter a long one. Cobblestone's own `Fat16` carries a
paragraph about having had the same bug.

## The backup story, both ways

Structure passing `fsck` is not the same as the data being reachable, so the
check does not stop there. It loop-mounts the volume with **the Linux
kernel's own VFAT driver** and compares what Linux sees with what we wrote:

```
./auth/damian/_session_secret      sixteen bytes!!!
./auth/damian/api-key              3-notarealkey
./users/damian/last-seen           1758038400
./users/damian/upload-bytes        4096
./blog-comments                    none yet
```

Every name exact — lowercase preserved, hyphens, the leading underscore — and
every byte. So `cp -r` off a mount gets the data out.

Then the other half, which is the one that matters when something has gone
wrong: **Linux writes and we read**. The check has the kernel create a
directory and a long-named file, unmounts, and boots the machine again:

```
zig-metal-unikernel restore probe
  restored/written-by-linux.txt: 46 bytes
  contents: linux wrote this, with a name 8.3 cannot hold
  auth/damian/_session_secret still reads: sixteen bytes!!!
```

A volume written on Linux is read here, and our own files survive Linux
writing to the volume, which a one-way check would not notice.

The mount needs root, so it is **skipped rather than failed** where there is
none — a check that cannot run must not look like one that passed.

## Two bugs only a replace, and only a big directory, could show

Removing an entry freed its chain before tombstoning it, and the chain walk
reuses the machine's one scratch sector — so a FAT sector was written over the
directory. And a long name's parts were located by `lba += 1`, which past a
subdirectory's cluster edge is someone else's data. Our own reader agreed with
both; `fsck.vfat` and Linux did not. `probe/replace.zig` forces both shapes
and its judge checks, from the raw image, that it did.

## Read a run at a time, with the FAT in memory

A soak of 5,251 chat requests passed every correctness check while the
machine's own time to answer rose from 10 ms to 160 ms as the conversation
grew. Two costs grew with the disk, not with the request:

- **No FAT in memory.** Every FAT lookup was a block read, and the
  free-cluster search started at cluster 2 on every allocation. A chat request
  replaces four tiny files (`last-seen`, `last-conv`, `lastauthor`, the
  session cursor), so each walked past every cluster the growing transcript
  held, one device round trip apiece.
- **One sector per request.** A 200 KB file was four hundred round trips
  through the emulator. And chat's `appendMessage` reads the whole transcript
  on every send, to count the messages and number the next one — cheap out of
  Linux's page cache, expensive here.

So `Volume.cacheFat` holds one copy of the FAT in memory, written through to
every copy on each change. **Where the copies disagree, the first is the
FAT:** every change writes the first copy and then the others, so a machine
stopped between the two leaves them a sector apart, the first the newer, and
Linux's vfat reads only the first too. At mount, each sector of another copy
that differs is rewritten from the first, and the count is reported to the
caller (`src/disk_fat.zig`, `cacheFat`). And `readAt` reads a file as **runs** of
consecutive clusters: whole sectors go straight into the caller's buffer as
one request per run, capped at 64 KB, and only a sector the read starts or
ends inside goes through the scratch sector.

**Judged three ways:**

- `replace` and `replace_cached` are one probe built twice, run from one
  formatted image, and must leave **byte-identical** volumes: the cache may
  change nothing that reaches the disk. (mkfs's own timestamp on the volume
  label differs between two formats a few seconds apart, so both start from
  one image.) Writing only the first FAT copy is caught by fsck and by the
  comparison.
- `append` sweeps fifteen offsets against eleven lengths over a file whose
  chain breaks at every cluster and one that is a single run longer than a
  request may carry, and checks its own files have those shapes first. Its
  volume uses 512-byte clusters, so its FAT is too big for one request — the
  only path that splits a read, which a mutation showed nothing else reached.
- Every HTTP request's log line says how many disk requests it made and how
  long they took, so a slow answer can be split into the device's share and
  ours.
