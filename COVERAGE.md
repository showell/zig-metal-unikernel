# Coverage properties

`always` and `sometimes` properties of a whole run, from
[zig-coverage-sdk](https://github.com/showell/zig-coverage-sdk). Its README
covers the API, the catalog, and where it differs from Antithesis. This file
covers what zig-metal-unikernel does with it. Started 2026-10-05.

**The SDK is a path dependency** (`build.zig.zon`) on a sibling checkout,
`../zig-coverage-sdk`. Its scanner reads every file in `src/` that imports
the SDK (`build.zig` `catalogFiles`, but those `not_cataloged` names with why:
tests, benches, the module root), so their properties are in the catalog even
in code a program never calls, and one never reached shows as a MISS; every
module that compiles one imports `"coverage"` and `"coverage_catalog"`.

## Decisions

- **A FAIL fails every tier.** A FAIL is a broken `always`, or an
  `unreachable` that was reached. **A MISS** (a property the run never got
  to) **fails only the long tier, and only for a property on its floor**
  (`coverage/`). Antithesis treats the two alike; we don't, on purpose
  (the SDK's README).
- **Three tiers, one set of properties.** `zig build test` runs eight
  plain and eight rough TCP seeds and eight FAT seeds; `zig build
  properties` 100 of each kind of TCP seed (each also run as a crowd), 20
  FAT seeds and the FAT regression seeds (`build.zig`'s `-Dseeds`,
  `-Dfat-seeds` defaults), in 20 minutes in Debug and 5 with
  `-Dsweep-optimize=ReleaseSafe`; `./long.sh` its `SEEDS` TCP seeds
  (`CROWD_SEEDS` of them crowded) and `FAT_SEEDS` FAT seeds, and the real
  kernel's lossy sweep, in about ten. Each reads the same
  properties with a bigger budget.
- **Debug for test code** (Steve, 2026-10-05): it builds in a fraction of
  the time. A sweep is nearly all running, about three times slower in
  Debug, so `long.sh` builds its with `-Dsweep-optimize=ReleaseSafe`.
  Shipping kernels are ReleaseSafe, as they always were.
- **QEMU stays mostly on the happy path.** The judge checks that metal
  answers as Linux does, on a clean network. **The budget for covering
  every scenario goes to metal-vmm**, where every frame, disk request and
  clock tick is ours to choose and a run repeats exactly. On Linux the
  same work is done by `tcp_sim.zig`.
- **Nothing deployed writes the lines.** `-Dcoverage` is off by default:
  the declarations alone would fill the log ring `/admin/host` shows. The
  counters are still kept, at the cost of one add per site reached.

## Running it

**On Linux, against the TCP and FAT simulators** (`src/properties.zig`):

    zig build properties                 # 100 TCP seeds, plain and rough; 20 FAT
    zig build properties -Dseeds=5000 -Dfat-seeds=300 -Dsweep-optimize=ReleaseSafe
    zig build properties -Dsdk-jsonl=out/sdk.jsonl

A seed whose oracle fails is a false `always` with its seed in the details,
and the sweep goes on. Only a FAIL fails the step. (zig's build runner prints
"failed command" for any test that writes to stderr, so read the summary
line instead.)

**On metal:**

    zig build gopher -Dcoverage
    COVERAGE_OUTPUT_DIR=out probe/run.sh gopher uploads
    ../zig-coverage-sdk/tools/report.py out/sdk.jsonl

The kernel writes each line to the serial port behind `coverage: `: the port
only, not the log ring. The judge appends every boot's lines to
`$COVERAGE_OUTPUT_DIR/sdk.jsonl`. `tools/coverage_jsonl.sh` does the same for
any serial log, such as a droplet's.

**The long tier, for bug hunting and before a deploy:**

    ./long.sh              # about 10 minutes
    SEEDS=50000 ./long.sh
    ./long.sh sim | metal  # one half

- **The simulators** (ReleaseSafe): `SEEDS` TCP seeds, plain and rough
  (`CROWD_SEEDS` of them also crowded), and `FAT_SEEDS` FAT seeds (the
  defaults are at the top of `long.sh`, each with the measurement that
  chose it), against `coverage/floor-sim.txt` (`zig build properties
  -Dfloor=...`).
- **The real kernel**, gopher.elf built `-Dcoverage`, on metal-vmm's
  PC-shaped machine (`TRANSPORT=pci`: halting between frames and woken by
  interrupts, as on a droplet), over a 5 ms wire. For each of three routes
  the wire eats the guest's 1st frame, then its 2nd, through every frame the
  route sends, one deterministic run each, and **every run must still serve
  the page an unhurt run serves.** The runs' properties are judged against
  `coverage/floor-metal.txt` by the SDK's `tools/report.py --floor`.

A floor line naming no property fails too: a floor goes stale loudly.

**The seed explorer** (zig-coverage-sdk's `explore.zig`) runs fat_sim,
store_sim and tcp_sim from a recorded tape instead of a seed (`runWith`), so
it can return to a run and steer it. Two tools, neither a gate:

    zig build explore      # the explorer against blind seeds on one simulator (~15 min)
    tools/soak.sh          # OVERNIGHT, detached: explorer and blind columns on all three, 7 hours, log in ~/soak-logs/

The soak prints, round by round, what only some columns reached and every
failure with its recipe (simulator, column, explorer seed); stop it (its
PID) before a morning's gates.

## What the runs have said

There are 18 properties in `tcp.zig` (retransmission, probing, window
updates, resets, RTO bounds), and a few in `tcp_sim.zig` that confirm its
scenarios actually happened. There has been no FAIL anywhere.

**On day one, 500 plain seeds never reached four of the table's paths:**
- an exact reset closing a connection;
- an inexact in-window reset drawing a challenge ACK;
- giving up on a silent peer;
- a stuck half-open connection giving way to a new SYN.

Each had a unit test in `tcp_test.zig`, but none was ever run under loss
and reordering. The simulator's client reset only when it gave up itself,
and nothing ever competed for the table's two slots.

**So `tcp_sim.zig` has rough seeds** (`Rough`, `runRoughSeed`). A rough
seed is a plain seed whose peer, each by its own chance:
- resets mid-exchange, either exactly or off by up to 2000 (and so is
  challenged), then answers as a closed port;
- vanishes part-way through the answer;
- or floods the table with SYNs from addresses that never finish.

A second random generator, derived from the seed, makes those choices. So a
plain seed runs exactly as it did before, and its regression seeds still
reproduce. The give-up oracle now counts only the client's own connection:
under a flood, the table is right to give up on the spoofed ones.

**After that:** 5,000 seeds, each run plain and rough, took about a minute.
Every oracle held and every property was reached. In the first 500 rough
runs, the table alone gave up on a client that had left 45 times, and all 60
clients that stayed through a flood got their whole answer.
`zig build test` runs rough seeds 1–8 alongside the plain ones.

One judge gate on metal (`uploads`, under QEMU) reached 3 of the 18
properties, as expected on a clean network.

**The first lossy sweep of the real kernel** (2026-10-05): `/` in 32 frames,
`/steve-resume.pdf` in 57, `/login/full` in 11. Each frame was lost in turn,
100 runs, and every one served the same page. It reached 6 of the 18: the
table's recovery from its own losses (a lost SYN-ACK, the timer going back,
three duplicate ACKs resending at once, the RTO bounds). The rest need the
PEER to misbehave (reset, flood, stop reading, lose what it sends), which
metal-vmm's peer cannot yet do: its QUEUE.md item 7. Until then the
simulator's floor holds them.

## Next

- The last three of tcp.zig's eighteen on the real kernel: a peer sending
  past the window, a segment from behind (both wait on metal-vmm's QUEUE.md
  item 39), and a reopened window announced again (a large upload, the
  box's). The metal floor holds the other fifteen.
- Properties in FAT (`disk_fat.zig`), the page cache, and restart.
- An explorer: metal-vmm choosing faults, scored by which properties a run
  reaches. That's the long-term aim, and it isn't urgent.

## The floor, module by module

*(metal-vmm QUEUE items 76, 78 and 80: every refusal named with a
`reachable`, every invariant with an `always`, and each one reached by a
simulator or a host test, so a report says which any run has met. "Reached
by" names what reaches it in `zig build properties`; "under metal-vmm" means
only a real device reaches it, so it is off `floor-sim.txt` and listed
under "For the box" below.)*

| module | properties | reached | by what | errors it answers |
|---|---|---|---|---|
| `durable` | 4 | 4 | `durable_sim` | none: `step` and `settle` decide, and a failed synchronize is the caller's status byte |
| `gpt` | 8 | 8 | `floor_sim` (GPT built field by field, one field wrong) | `ReadFailed`, `NotGpt`, `NoPartition` |
| `page_cache` | 16 (one `unreachable`: room is always found for a file within the budget) | 15 | `page_sim`; `floor_sim` for every slot taken, a write past a copy's end, and no memory to grow one | none: it answers a copy or nothing, and refuses by not keeping |
| `log_ring` | 9 (2 limits on the ring, the 3 redactions, an empty quoted value, and how a read starts) | 9 | `pure_sim`; `floor_sim` for an empty quoted value | none: it keeps what fits and takes secrets out |
| `kept_log` | 5 (3 ways a slot is read, no boot before, and never writing over the boot before) | 5 | `pure_sim` | none: a header that fails its check reads as no log |
| `fat16` | 84 (11 of them `unreachable`: guards behind other checks) | 61 of the 73 others in `properties`; the 12 missed are listed below | `fat_sim`; `floor_sim` for damaged volumes (a boot sector field, a first cluster or size on the disk, a link in a chain, a loop) and buffers or paths handed in | see "Errors under the Store" |
| `proto` | 12 (11 refusals in `parseIpv4` and `parseUdp`, and a packet lies within its frame) | 12 | `floor_sim`: a UDP datagram built field by field, one field wrong, the header's checksum made right again; `tcp_sim` too | none: a frame it cannot use is a silent null, by design |
| `arp` | 6 | 6 | `floor_sim`: an ARP request built field by field, one field wrong | none: a silent null |
| `request_heap` | 4 (the memory it keeps missing, the pages running out, a block that cannot grow in place, a reset) | 4 | `pure_sim`; `floor_sim` for a growth only the last block can make | none: the allocator answers null and the caller decides |
| `stream` | 7 (a read finding the peer gone or idle; a write, or draining a spill, finding the connection gone or idle; a spill too full) | 0 here | under metal-vmm (below): `stream.zig` imports `io.zig`, the driver and interrupts, so no simulator can drive it. The seam that would let one is under Proposed in QUEUE.md | `WriteFailed`, and null for a read |
| `store` (`store_model`, `store_fat`, `store_linux`) | 16 in `store_sim` | 16 | `store_sim`: the model, the FAT store on a disk in memory (FAT16, and FAT32 one seed in four) and the strict Linux store in a temporary directory, given the same operations from a pool of paths that differ in case, nest, and break the rules; a cut on the FAT side one write in 4 to 20, plain or torn; one seed in four on a 2 MiB FAT16 volume with files up to 1.5 MB, so FAT runs out of room and the file must be as it was (a write may leave it gone) while the model and Linux are made to match (item 83). 1000 seeds | the Store's own (`store.zig`): `NotFound`, `IsDirectory`, `BadName`, `TooBig`, `NoSpace`, `Damaged`, `Io` |
| `pvh` | 4 (3 refusals of the loader's header, and the region chosen within the RAM) | 4 | `floor_sim`: a start info built in memory, one field wrong | `NoStartInfo`, `NotPvh`, `NoMemoryMap` |
| `restart` | 6 in `restart.zig` (3 ways CMOS holds no record, 3 clocks that say no time), and `pure_sim`'s 7 | 13 | `pure_sim`; `floor_sim` for a count of zero and an unknown clock | none: no record is null |
| `pages` | 5 (nothing, more than the heap, an alignment past it, no run free, an address not its own) | 5 | `floor_sim`: a heap over memory a test owns. A free of an address not its own panics, by design; resize meets the refusal | none: null to the allocator's caller, and a panic for a foreign free |
| `rtc` | 10 (6 of decoding, 4 of the chip) | 6 | `floor_sim` for the decoding (registers built field by field, BCD or binary, 12 or 24 hours); the chip's 4 are for the box | `NoChip`, `NeverSettled`, `Stuck`, `NoEdge`, `BadBcd`, `OutOfRange` |
| `pit` | 6 (3 of settling samples, 3 of the timer) | 3 | `floor_sim` for settling; the timer's 3 are for the box | `NoTimer`, `Implausible` |
| `admin_reset` | 4 (2 of parsing the line, 2 of the boot disk) | 2 | `floor_sim` for parsing; the disk's 2 go through `io.zig`, met by `admin_reset.zig`'s own host tests, which `properties` does not run | an `Outcome`: `failed`, `no_admin` and the rest |
| `ready` | 1 (a head std cannot parse is served, for the handler to refuse), and `ready_sim`'s 7 | 8 | `ready_sim` | none: `.ready`, `.waiting`, `.abandoned` |
| `scsi` | 6 (no disk, no capacity twice, sizes, MODE SENSE twice) | 0 here | under metal-vmm (below) | `NoDisk`, `UnexpectedSizes`, `NoCapacity`, and a SCSI status |
| `pci` | 3 (a BAR past the sixth, an I/O BAR, a 64-bit BAR in the last slot) | 0 here | for the box: no knob makes any of them | none: null for a BAR it will not map |
| `rng` | 1 (a virtio-rng that will not come up is left alone) | 0 here | for the box: no knob | none: RDRAND may still answer |
| `civil` | 0 | | nothing to name: pure calendar arithmetic with no refusal; `rtc` and `restart` check the ranges it is handed | none |
| `wallclock` | 0 | | nothing to name: one call that brings `pit`, `rtc` and `tsc` up, whose refusals are theirs | none of its own |
| `dhcp` | 0 | | not named here: its refusals are the box's (B18, lies in the peer's DHCP replies) | `NoOffer`, `NoAck` |
| `net`, `interrupts`, `boot`, `port`, `tsc`, `serial`, `serial_gate`, `screen`, `stack`, `reset`, `restarting`, `kernel_partition` | 0 | | nothing to name: drivers and the boot path with no refusal of their own (`net`'s `poll` answers null for no frame, which is not one); everything they do is reached only under a VMM | none |
| `metal`, `netcore` | 0 | | nothing to name: each is the list of files one build compiles | none |
| `tcp`, `tcp_check` | 23, and `tcp_check`'s rules | 23 | `tcp_sim` (named before item 76: COVERAGE.md above, "What the runs have said"); `tcp_check` is the invariants, run by every simulator and, under B15, by a `-Dcoverage` kernel | none: `tcp` refuses a segment by dropping it |
| the simulators and tests (`tcp_sim`, `fat_sim`, `page_sim`, `pure_sim`, `ready_sim`, `durable_sim`, `floor_sim`, `store_sim`, `properties`, `test_disk`, `tcp_test`, `disk_fat_test`, `disk_fat_faults_test`, `io_test`, `store_test`) | their own | | they are what reaches the rows above; a simulator's own properties are on the floor beside the module it drives | none |
| `store_model`, `store_fat`, `store_linux` | | | in the `store` row above | |
| `virtio` (`Block.flush`, the rings, negotiation) | 7 | 0 here | under metal-vmm (below) | a SCSI status, as a virtio-blk status byte |
| `io` (`durable`) | 1 | 0 here | under metal-vmm | none: a failed flush is logged, counted, and the response goes out |

**What `fat16` leaves unreached in `properties`, and why:**

- *a file of 4 GiB or more is refused*: `writeFileIn` takes the bytes whole,
  and no host test holds 4 GiB. The write at an offset past 4 GiB, the other
  way there, is reached.
- *a write finds a file's chain ends before its size* (writing, at its
  start; and past its first run): `writeInto` walks the chain with
  `chainEnd` first and links what is missing, so `writeRuns` only meets a
  short chain if the disk answers its second read of the FAT differently.
  No metal-vmm knob does that on purpose; **a knob that answers one read
  with other bytes** (as `Block.Fault.garbage` does in host tests) would.
- *a tree with more entries than a volume holds is refused as broken*: it
  needs a directory written by something other than this driver (one whose
  entries come back after removal). Not built yet: the debt ledger has it.
- Four that were missed in `properties` before item 76 as well: *no 8.3
  alias is left*, *a directory reaches FAT's most entries*, *a directory
  deeper than the check walks*, *a tree too deep to remove*. `disk_fat_test.zig`
  drives those limits; `properties` does not run it.
- Two met only at the long tier's 300 FAT seeds, as before: *a run of
  sectors fails to read* and *a FAT32 entry's first cluster is past 65535*
  (and *a run of sectors fails to write*, met at neither).

**B15** (item 78): a gopher.elf built `-Dcoverage` checks `tcp_check`'s
rules after every `handle` and `transmit` (`stream.checkTable`, as the
simulators do, as one `always`: "tcp: the table's invariants hold"), and the
volumes after every request ("fat: after a request, a volume has no damage
beyond what a stop leaves"). Every build checks at boot ("fat: at boot,
..."), since `diskCheck` already walks the volume there. "Damage" is
`fat16.Problem.damage`: broken, crossed, short and bad `.`/`..`; leaked
clusters, a long chain, FAT copies apart and a stale FSInfo are what a stop
may leave. A production build compiles no per-turn or per-request check
(`coverage_checks` is comptime). Built here both ways against angry-gopher
`f5d360e`; not run (no KVM).

## Errors under the Store

Each error a module answers, and the named refusals that answer it, read
from the source (a property followed by its `return`). Phase B's Store
errors are built from these.

**`disk_fat.zig`** (and the files it is split into, metal-vmm QUEUE 173: `disk_fat_fat`, `_chain`, `_dir`, `_file`, `_remove`, `_check.zig`)

- `BadBootSector`: fat: a mount refuses FAT32 with FAT16's fields set; fat: a mount refuses FATs whose total size overflows; fat: a mount refuses a FAT of no sectors; fat: a mount refuses a FAT too short for its clusters; fat: a mount refuses a FAT16 root of no entries; fat: a mount refuses a cluster size no volume has; fat: a mount refuses a sector without the boot signature; fat: a mount refuses a volume with no data region; fat: a mount refuses no reserved sectors, or a count of FATs it does not keep; fat: a mount refuses reserved sectors and FATs whose sum overflows
- `BadChain`: fat: a chain leads outside the data area; fat: a chain that loops is refused; fat: a directory's first cluster is outside the data; fat: a file's chain ends before its size, reading a file whole *(a guard)*; fat: a file's chain ends before its size, reading at an offset, at its start; fat: a file's chain ends before its size, reading at an offset, past its first run; fat: a file's chain points at a reserved cluster, reading at an offset, at its start *(a guard)*; fat: a file's chain points at a reserved cluster, reading at an offset, past its first run *(a guard)*; fat: a file's first cluster is outside the data; fat: a file's first cluster is outside the data, at its chain's end; fat: a file's first cluster is outside the data, when its layout is asked; fat: a file's layout counts more clusters than the volume holds: a loop; fat: a file's layout finds a reserved cluster *(a guard)*; fat: a tree too deep to remove is refused; fat: a write finds a file's chain ends before its size, writing, at its start; fat: a write finds a file's chain ends before its size, writing, past its first run; fat: a write finds a file's chain points at a reserved cluster, writing, at its start *(a guard)*; fat: a write finds a file's chain points at a reserved cluster, writing, past its first run *(a guard)*; fat: a write finds a file's first cluster outside the data *(a guard)*; fat: an overwrite past a file's end is refused
- `BadName`: fat: a directory deeper than the check walks is refused; fat: a directory run sized for another name *(a guard)*; fat: a directory to be made is a file's name; fat: a name needing more long-name parts than FAT allows *(a guard)*; fat: a path with no name in it is refused; fat: a rename across directories is refused; fat: a rename of a directory is refused; fat: a write's name is empty or too long; fat: an overwrite of a directory is refused; fat: no 8.3 alias is left for a name
- `BadRoot`: fat: a mount refuses a FAT32 root outside the data
- `DirectoryFull`: fat: a FAT16 root directory is full; fat: a directory reaches FAT's most entries; fat: a tree with more entries than a volume holds is refused as broken
- `FatVersion`: fat: a mount refuses a FAT32 version it does not know
- `Full`: fat: a volume full part-way through an allocation gives back what it took
- `IsDirectory`: fat: a rename onto a directory is refused; fat: a write onto a directory is refused
- `NotFat16`: fat: a mount refuses a volume too small for FAT16; fat: a mount refuses sectors that are not 512 bytes; fat: a path whose parent is a file is refused
- `NotFound`: fat: a directory read as a file is refused, reading a file whole; fat: a directory read as a file is refused, reading at an offset; fat: a path through a file names nothing; fat: a remove of a file that is not there is refused; fat: a rename of a file that is not there is refused; fat: an entry never located is written back *(a guard)*
- `NotMirrored`: fat: a mount refuses a FAT32 volume that is not mirrored
- `ReadFailed`: fat: a mount cannot read the boot sector; fat: a run of sectors fails to read; fat: a sector read fails
- `TooBig`: fat: a FAT cache buffer too small for the FAT is refused; fat: a check given too little room to mark clusters is refused; fat: a file larger than the room to read it into is refused; fat: a file of 4 GiB or more is refused; fat: a write of more sectors than one request *(a guard)*; fat: a write reaching past 4 GiB is refused
- `TooManyClusters`: fat: a mount refuses a FAT32 volume with more clusters than its numbers
- `VolumeTooLarge`: fat: a mount refuses a volume past 32-bit sectors
- `WriteFailed`: fat: a run of sectors fails to write; fat: a sector write fails

**`gpt.zig`**

- `NoPartition`: gpt: no partition but the kernel's, so no data partition
- `NotGpt`: gpt: a table with no entries, or entries of a size this reader refuses; gpt: no EFI PART signature, so not GPT
- `ReadFailed`: gpt: a sector of entries cannot be read; gpt: the header cannot be read


`page_cache`, `log_ring`, `kept_log` and `durable` answer no errors: each
refuses by not keeping, by taking out, or by a status byte the caller reads.

## For the box

Properties that only a real device reaches. Each one's knob, for a
metal-vmm run in `long.sh`; once a run reaches it, it goes on
`floor-metal.txt`. A refusal with no knob says so: that is a proposal for one.

| property | module | knob |
|---|---|---|
| virtio: a flush fails, is counted, and the disk stays unflushed | `virtio_blk.zig` | `VOLUME=<copy> VOLUME_CACHE=1 VOLUME_SYNC_FAIL=1`, and a chat post |
| (no property) The Store's `replace` flushes before it renames | `store_fat.zig` | `VOLUME=<copy> VOLUME_CACHE=1 VOLUME_CUT_AT_EXIT=1` around a `replace`: in memory a flush does nothing, so only a write cache shows that the rename cannot reach the media before the data. Needs a kernel that calls the Store, which none does yet |
| stream: a read finds the peer closed or done, so nothing more is coming | `stream.zig` | `PEER_RESET_AT=<before the request ends>` (unverified) |
| stream: a read waits idle_ns for a byte, and gives up | `stream.zig` | `PEER_DRIP_US=11000000` with a request of several segments (`PEER_MSS`), each later than `idle_ns` (10 s) (unverified) |
| stream: a write finds the connection gone | `stream.zig` | `PEER_RESET_AT=<while the answer goes out>` (unverified) |
| stream: a write finds the connection gone, with a spill | `stream.zig` | the same, on a large answer (unverified) |
| stream: a write waits idle_ns with nothing taken, and gives up | `stream.zig` | `PEER_SHUT_AFTER=1000 PEER_SHUT_FOR_US=11000000`, or `PEER_VANISH_AFTER=1000` (unverified) |
| stream: a spill too full to keep more is drained first | `stream.zig` | a large answer (a picture) and `PEER_SHUT_AFTER` small (unverified) |
| stream: draining a spill finds the connection gone; and waits idle_ns and gives up | `stream.zig` | the two above, together (unverified) |
| tcp: the table's invariants hold | `stream.zig` (B15) | any run of a `-Dcoverage` gopher.elf; every rough-peer run in `long.sh` |
| fat: after a request, a volume has no damage beyond what a stop leaves | `probe/gopher.zig` (B15) | any run of a `-Dcoverage` gopher.elf that serves a request; with `VOLUME_CUT_AFTER` or `DISK_CUT_AFTER` and a remount, it judges what a cut left |
| scsi: a controller with no disk on it | `scsi.zig` | `VOLUME=<copy> VOLUME_GONE_AT=1`: INQUIRY answers BAD_TARGET (unverified) |
| scsi: a disk that will not say how big it is | `scsi.zig` | `VOLUME_GONE_AT=<READ CAPACITY's command number>`, about 2 or 3 after a UNIT ATTENTION (unverified) |
| scsi: a disk that does not answer MODE SENSE is taken to cache | `scsi.zig` | `VOLUME_GONE_AT=<MODE SENSE's command number>`, one after READ CAPACITY (unverified) |
| scsi: a MODE SENSE answer without the caching page is taken to cache | `scsi.zig` | `VOLUME=<copy> VOLUME_MODE_PAGES=none` (metal-vmm item 82) |
| scsi: a controller whose CDB or sense size is not the default | `scsi.zig` | **no knob**: a proposal, metal-vmm's virtio-scsi config with other sizes |
| scsi: a disk whose sectors are not 512 bytes, or too many to count | `scsi.zig` | `VOLUME=<copy> VOLUME_SECTOR=4096` (metal-vmm item 82) |
| virtio: an mmio or a pci queue smaller than this driver needs, or none | `virtio.zig` | **no knob**: a proposal, a device whose `queue_num_max` is small |
| virtio: a device without VIRTIO_F_VERSION_1, or without a feature this driver needs, is refused | `virtio.zig` | **no knob**: a proposal, a device that offers fewer features |
| virtio: a device that will not keep FEATURES_OK; that fails at DRIVER_OK | `virtio.zig` | **no knob**: a proposal, a device that clears or fails a status bit |
| rtc: no chip answers | `rtc.zig` | `RTC_ABSENT=1` (metal-vmm item 82) |
| rtc: the chip says it is updating for half a second | `rtc.zig` | `RTC_STUCK=1` (metal-vmm item 82) |
| rtc: two readings never agreed; the seconds never changed | `rtc.zig` | **no knob**: a proposal, an RTC whose registers change between two reads, or whose seconds stand still |
| pit: the count never moves, so no timer | `pit.zig` | `PIT_FROZEN=1` (metal-vmm item 82) |
| pit: it wrapped; no round settled | `pit.zig` | **no knob**: a proposal, a PIT that counts too fast or unevenly |
| pci: a BAR past the sixth; an I/O BAR; a 64-bit BAR in the last slot | `pci.zig` | **no knob**: a proposal, metal-vmm's PCI devices with such BARs |
| rng: a virtio-rng device that will not come up is left alone | `rng.zig` | **no knob**: a proposal, an entropy device that refuses negotiation |
| admin reset: the boot disk has no admin to reset; a step on the boot disk failed | `admin_reset.zig` | a boot disk with `data/admin-reset` and no admin, and `DISK_REFUSE` during the reset; `admin_reset.zig`'s own host tests meet both |
| io: a flush failed, and the response goes out anyway | `io.zig` | the same, for the volume. **No knob fails a flush of the boot disk**: it is virtio-blk and writes through (virtio 1.2 §5.2.5.1), so nothing is sent; a knob would need metal-vmm's `DISK_CACHE` to offer FLUSH and fail it (a proposal) |
